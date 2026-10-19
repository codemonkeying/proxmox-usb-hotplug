#!/bin/bash
# usb-mapping-daemon.sh - USB hotplug daemon using Proxmox device mappings

# Defaults — override in /etc/usb-hotplug/config
INTERVAL=2
GPU_MAPPING=""
ENFORCE_PCI_EXCLUSIVITY=1
LOG_FILE="/var/log/usb-hotplug.log"
STATE_FILE="/var/run/usb-hotplug.state"
AUTO_VM_FILE="/var/run/usb-hotplug-auto-vm.state"
LOCK_FILE="/var/run/proxmox-vm-conf.lock"
GPU_MISS_THRESHOLD=2  # require N consecutive empty GPU-VM polls before treating as a real transition (debounces mid-run qm-start/stop transients)
MAX_USB_SLOTS=14  # PVE allows usb0..usb13 ($MAX_USB_DEVICES in PVE/QemuServer/USB.pm)
BOOT_GRACE_SECONDS=180  # at daemon start, suppress cleanup_stale_shared_mappings for this long so pve-guests has time to start VM 110 before we strip its conf (2026-06-04 reboot incident)

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "${SCRIPT_DIR}/usb-mapping-helper.sh" 2>/dev/null || source "/usr/local/bin/usb-mapping-helper.sh"

CONFIG_FILE="${USB_HOTPLUG_CONFIG:-/etc/usb-hotplug/config}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

# Pool config — plug-anywhere auto-slot-assignment for multiple identical USB
# devices (same VID:PID, no unique iSerial). See pools.conf.example in the repo
# and the "USB pools" section in README.md.
POOLS_CONF="${POOLS_CONF:-/etc/usb-hotplug/pools.conf}"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# log_once KEY MSG — log MSG only the first time KEY is seen this daemon run
# (stops a persistent condition from spamming the log every 2s poll).
declare -A LOG_ONCE_SEEN=()
log_once() {
    [[ -n "${LOG_ONCE_SEEN[$1]:-}" ]] && return 0
    LOG_ONCE_SEEN[$1]=1
    log "$2"
}

# POOL_OWNED["vmid:slot"]=pool_name — slots the pool attached (or adopted)
# during this daemon run. Lets a pool detach its own slot when the device goes
# away, without ever touching a manually-configured host= slot.
declare -A POOL_OWNED=()

with_lock() {
    # Subshell so fd 200 closes on return, releasing the flock. Without the
    # subshell, fd 200 persists in the caller's shell and the lock is held
    # forever — any later with_lock from a child subshell deadlocks.
    (
        exec 200>"$LOCK_FILE"
        flock -x 200
        "$@"
    )
}

vm_running() {
    local vmid=$1
    qm status "$vmid" 2>/dev/null | grep -q "status: running"
}

# qm_config_safe — read a VM's config with a timeout AND sanity-check the
# output. Returns the config text on stdout and 0 on success; empty stdout
# and nonzero exit on timeout, error, or partial output. Use whenever the
# daemon needs to TRUST the contents (dedup, slot scans, mapping presence).
#
# A bare `qm config` can return EMPTY or partial output when pmxcfs is
# mid-rebuild after a corosync membership change — the conf file is served
# locally but the cluster-sync layer may not have merged peer state yet.
# This was the 2026-06-05 16:12 root cause: daemon's pre-add dedup check
# at 16:12:41 (22s after corosync restart by Job 3) read VM 110's conf as
# (apparently) missing the usb3/usb6 shared-Btooth6 entries that were
# actually there, then added shared-Btooth6 again at usb7. Operator saw
# three slots all pointing to the same physical bluetooth dongle.
#
# Sanity gate: every valid VM conf has a `name:` field. If absent, the
# read returned partial/stale data — fail closed, caller skips this iter.
qm_config_safe() {
    local vmid=$1
    local out
    out=$(timeout 10 qm config "$vmid" 2>/dev/null) || return 1
    [[ -z "$out" ]] && return 1
    grep -q "^name:" <<<"$out" || return 1
    printf '%s\n' "$out"
}

# v2 (2026-06-08 night) — pmxcfs LIMBO gate.
# Returns 0 if pmxcfs appears healthy, 1 if in LIMBO (read-only or .version
# EIO/EAGAIN). Cheap to call — two stat-class operations. Use as the FIRST
# check at the top of every main-loop iteration so we don't issue any writes
# while pmxcfs is mid-resync (the underlying cause of Failure Mode B's
# write-success-but-read-stale state, per pve-cluster source + research).
pmxcfs_limbo_check() {
    local mount_opts
    mount_opts=$(findmnt -n -o OPTIONS /etc/pve 2>/dev/null)
    # ro indicates pmxcfs is in read-only / no-quorum state.
    [[ "$mount_opts" == *"ro,"* || "$mount_opts" == *",ro"* ]] && return 1
    # .version stat will EIO/EAGAIN during CPG mid-resync.
    stat /etc/pve/.version >/dev/null 2>&1 || return 1
    return 0
}

# v2 — read the JSON `vmlist` counter from /etc/pve/.version. Increments by
# multiple ticks for every qm/pvesh write that touches a VM conf. Use as a
# barrier: capture before a write, expect a higher value after; if unchanged
# the write either didn't propagate locally or was clobbered by a concurrent
# write. Returns empty string on read failure.
get_vmlist_seq() {
    local v
    v=$(grep -o '"vmlist":[[:space:]]*[0-9]\+' /etc/pve/.version 2>/dev/null | grep -o '[0-9]\+$')
    echo "${v:-}"
}

# v2 — pvesh batch helpers. Accumulate add/delete ops during the main loop;
# at end of iteration, issue ONE pvesh set per VM (multiple --usbN flags +
# comma-delimited --delete). This converts the "dock-unplug storm" pattern
# (4-5 strips in 2s) from 4-5 separate qm set calls into 1 atomic pvesh
# request = 1 CPG broadcast = 1 file write. Reduces race surface; doesn't
# eliminate it (QMP device_add still iterated serially per slot inside PVE).
declare -a BATCH_VM=()
declare -a BATCH_FLAG=()
declare -a BATCH_VAL=()

# vm_has_xhci — true iff VM's running QEMU has a qemu-xhci controller.
# PVE adds qemu-xhci at VM start ONLY when the conf contains any usb device
# at that moment. If the VM was started with no usbN entries (e.g. daemon
# had just deleted one via phantom-check right before a qmeventd restart),
# QEMU has no xhci bus. Adding "usb3=1" devices later silently fails — the
# QMP device_add targets a non-existent bus, pvesh returns 0, runtime stays
# empty, phantom-check fires, re-add fails again. Vicious loop.
#
# Result is cached per-VM keyed on the pid file mtime (= VM start time).
# Invalidation on restart is automatic since the cache key changes.
declare -A XHCI_CACHE_KEY=()
declare -A XHCI_CACHE_VAL=()
vm_has_xhci() {
    local vmid=$1
    local pid_file="/run/qemu-server/${vmid}.pid"
    [[ -f "$pid_file" ]] || return 1
    local key
    key=$(stat -c %Y "$pid_file" 2>/dev/null)
    [[ -z "$key" ]] && return 1
    if [[ "${XHCI_CACHE_KEY[$vmid]}" == "$key" ]]; then
        [[ "${XHCI_CACHE_VAL[$vmid]}" == "1" ]] && return 0 || return 1
    fi
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [[ -z "$pid" || ! -r "/proc/$pid/cmdline" ]] && return 1
    local has=0
    # PVE/QEMU names the xHCI controller differently by version: older builds
    # emit "qemu-xhci", qemu 10.x (PVE 9.2) emits "nec-usb-xhci". Match both —
    # grepping only "qemu-xhci" silently false-negatives the whole fleet and
    # forces the UHCI fallback for high-speed radios (RT3070/RT5370/MT7921).
    if tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | grep -qE "(qemu|nec-usb)-xhci"; then
        has=1
    fi
    XHCI_CACHE_KEY[$vmid]="$key"
    XHCI_CACHE_VAL[$vmid]="$has"
    [[ "$has" == "1" ]]
}

# usb3_arg_for — return ",usb3=1" if VM has xhci, empty otherwise. Empty
# means the device attaches to the always-present piix3-uhci (USB 1.1, 12
# Mbps) which is fine for low-speed devices but cripples high-speed ones.
# Adding it anyway is still better than the alternative (silent re-add loop)
# because (a) UHCI attach actually succeeds at runtime so phantom-check is
# quiet, and (b) operator sees a "VM N has no xhci" warning to act on.
usb3_arg_for() {
    local vmid=$1
    if vm_has_xhci "$vmid"; then
        echo ",usb3=1"
    else
        # Rate-limited warning: once per (vmid, VM-start-epoch).
        local pid_file="/run/qemu-server/${vmid}.pid"
        local key warn_file
        key=$(stat -c %Y "$pid_file" 2>/dev/null)
        warn_file="/var/run/usb-hotplug-noxhci-warned.${vmid}.${key}"
        if [[ ! -f "$warn_file" ]]; then
            log "WARN: VM $vmid has no qemu-xhci controller (started with no USB devices in conf). Falling back to usb3=0 (UHCI = USB 1.1). High-speed devices like RT5370/MT7921u will not work at full speed. Restart VM with at least one usbN entry in conf to get xhci."
            touch "$warn_file" 2>/dev/null
        fi
        echo ""
    fi
}

batch_queue_add() {
    local vmid=$1 slot=$2 mapping=$3
    BATCH_VM+=("$vmid")
    BATCH_FLAG+=("--usb${slot}")
    BATCH_VAL+=("mapping=${mapping}$(usb3_arg_for "$vmid")")
}

batch_queue_delete() {
    local vmid=$1 slot=$2
    BATCH_VM+=("$vmid")
    BATCH_FLAG+=("--delete")
    BATCH_VAL+=("usb${slot}")
}

batch_flush() {
    [[ ${#BATCH_VM[@]} -eq 0 ]] && return 0

    # Group ops by VM. For each VM: one pvesh call with all flags.
    local -A vm_seen=()
    local i
    for ((i=0; i<${#BATCH_VM[@]}; i++)); do
        vm_seen[${BATCH_VM[$i]}]=1
    done

    local vmid
    for vmid in "${!vm_seen[@]}"; do
        local args=()
        local deletes_csv=""
        for ((i=0; i<${#BATCH_VM[@]}; i++)); do
            [[ "${BATCH_VM[$i]}" != "$vmid" ]] && continue
            if [[ "${BATCH_FLAG[$i]}" == "--delete" ]]; then
                # Coalesce all deletes into one comma-list for this VM.
                if [[ -z "$deletes_csv" ]]; then
                    deletes_csv="${BATCH_VAL[$i]}"
                else
                    deletes_csv="${deletes_csv},${BATCH_VAL[$i]}"
                fi
            else
                args+=("${BATCH_FLAG[$i]}" "${BATCH_VAL[$i]}")
            fi
        done
        [[ -n "$deletes_csv" ]] && args+=(--delete "$deletes_csv")

        local before after
        before=$(get_vmlist_seq)
        log "pvesh batch flush VM $vmid: ${args[*]}"
        if with_lock pvesh set "/nodes/$(hostname)/qemu/${vmid}/config" "${args[@]}" 2>&1 | tee -a "$LOG_FILE" >/dev/null ; then
            after=$(get_vmlist_seq)
            if [[ -n "$before" && -n "$after" && "$after" -le "$before" ]]; then
                log "pvesh batch flush VM $vmid: vmlist counter did not advance ($before -> $after) — write may not have propagated locally"
            fi
        else
            log "pvesh batch flush VM $vmid: FAILED — ops will retry next iteration"
        fi
    done

    BATCH_VM=()
    BATCH_FLAG=()
    BATCH_VAL=()
}

get_gpu_vm() {
    [[ -z "$GPU_MAPPING" ]] && return 1
    for vm in $(qm list | awk 'NR>1 && $3=="running" {print $1}'); do
        if qm config "$vm" | grep -q "mapping=${GPU_MAPPING}"; then
            echo "$vm"
            return 0
        fi
    done
    return 1
}

get_running_vms() {
    qm list | awk 'NR>1 && $3=="running" {print $1}'
}

vm_in_auto_mode() {
    local vmid=$1
    if [[ -f "$AUTO_VM_FILE" ]]; then
        grep -q "^${vmid}$" "$AUTO_VM_FILE" 2>/dev/null
        return $?
    fi
    return 1
}

add_mapping_to_running_vm() {
    local vmid=$1
    local mapping=$2
    local device_id=$3
    local description=$4

    vm_running "$vmid" || return 1

    # Read conf ONCE with safety check. If the read returns partial/empty,
    # defer — we won't risk adding a duplicate slot based on bad data.
    local conf
    conf=$(qm_config_safe "$vmid") || {
        log "add_mapping_to_running_vm: VM $vmid qm config read unreliable; deferring add of $mapping"
        return 1
    }

    # Anchored regex — exact mapping name match (avoids prefix collisions
    # like mapping=shared-bt vs mapping=shared-bt-2). Scans ALL usb slots,
    # so a stale entry from a prior boot at any slot prevents a duplicate.
    if grep -qE "^usb[0-9]+:[[:space:]]*mapping=${mapping}([,[:space:]]|$)" <<<"$conf"; then
        return 0
    fi

    local slot=""
    for i in $(seq 0 $((MAX_USB_SLOTS - 1))); do
        if ! grep -qE "^usb${i}:" <<<"$conf"; then
            slot=$i
            break
        fi
    done

    if [[ -z "$slot" ]]; then
        log "ERROR: No available USB slots for VM $vmid"
        return 1
    fi

    log "Adding USB mapping $mapping ($description) to VM $vmid as usb${slot}"

    if with_lock qm set "$vmid" -usb${slot} "mapping=${mapping}$(usb3_arg_for "$vmid")"; then
        # Re-read after set — verify the new line landed on the slot we asked for.
        local conf_after
        conf_after=$(qm_config_safe "$vmid") || {
            log "add_mapping_to_running_vm: post-set read failed for VM $vmid mapping $mapping; assuming success"
            echo "${mapping}:${vmid}" >> "$STATE_FILE"
            return 0
        }
        if grep -qE "^usb${slot}:[[:space:]]*mapping=${mapping}([,[:space:]]|$)" <<<"$conf_after"; then
            log "Successfully added mapping $mapping to VM $vmid"
            echo "${mapping}:${vmid}" >> "$STATE_FILE"
            return 0
        fi
    fi

    log "Failed to add mapping $mapping to VM $vmid"
    return 1
}

remove_mapping_from_running_vm() {
    local vmid=$1
    local mapping=$2
    local config="/etc/pve/qemu-server/${vmid}.conf"

    local slot=$(qm config "$vmid" --current 1 2>/dev/null | grep "mapping=${mapping}" | sed -n 's/^usb\([0-9]\+\):.*/\1/p')

    [[ -z "$slot" ]] && return 0

    log "Removing USB mapping $mapping from VM $vmid"
    qm set "$vmid" -delete usb${slot} 2>/dev/null

    # Did the line actually leave current config? When QEMU has no live
    # device for usb${slot} (phantom entry from a prior unplug), PVE moves
    # the delete to [PENDING] instead of applying it — which would loop
    # forever next iteration. Detect that and clean up directly so the
    # config matches reality and the next iteration is a no-op.
    if grep -qE "^usb${slot}:.*mapping=${mapping}" "$config"; then
        log "Hot-unplug deferred (no live device for usb${slot}); reverting pending and clearing line directly"
        qm set "$vmid" --revert usb${slot} 2>/dev/null
        sed -i "/^usb${slot}:.*mapping=${mapping}/d" "$config"
    fi

    sed -i "/${mapping}:${vmid}/d" "$STATE_FILE"
    log "Removed mapping $mapping from VM $vmid (was usb${slot})"
}

remove_mapping_from_stopped_vm() {
    # Strip a ghost usbN: mapping=NAME line directly from a stopped VM's conf.
    # Needed because remove_mapping_from_running_vm uses `qm set` which only
    # works on a running VM — a stopped VM with a ghost mapping would never
    # get cleaned, blocking the next start with "USB device mapping not found".
    local vmid=$1
    local mapping=$2
    local config="/etc/pve/qemu-server/${vmid}.conf"

    [[ -f "$config" ]] || return 0

    local slot
    slot=$(grep -E "^usb[0-9]+:[[:space:]]*mapping=${mapping}($|[,[:space:]])" "$config" \
           | sed -n 's/^usb\([0-9]\+\):.*/\1/p' | head -1)
    [[ -z "$slot" ]] && return 0

    log "Stripping ghost mapping $mapping (usb${slot}) from stopped VM $vmid"
    sed -i "/^usb${slot}:[[:space:]]*mapping=${mapping}/d" "$config"
    sed -i "/${mapping}:${vmid}/d" "$STATE_FILE" 2>/dev/null
}

prestrip_all_vms() {
    # One-shot strip pass: for every VM config, remove any usbN: mapping=NAME
    # line whose underlying USB device is not currently present on this host.
    # Designed to run as ExecStartPre, before pve-guests starts VMs at boot,
    # so VM 100 (router) and any other vm{ID}-* VM can boot even if some
    # passthrough devices are unplugged. Idempotent.
    log "Prestrip: scanning VM configs for ghost USB mappings"
    local hostname=$(hostname)
    local current_devices=$(lsusb | awk '{print $6}')

    declare -A mapping_device
    declare -A mapping_node
    while IFS='|' read -r m id _ n; do
        mapping_device["$m"]="$id"
        mapping_node["$m"]="$n"
    done < <(get_usb_mappings)

    local stripped=0
    for config in /etc/pve/qemu-server/*.conf; do
        [[ -f "$config" ]] || continue
        local vmid
        vmid=$(basename "$config" .conf)

        while IFS= read -r line; do
            local slot mapping
            slot=$(echo "$line" | sed -n 's/^usb\([0-9]\+\):.*/\1/p')
            mapping=$(echo "$line" | sed -n 's/.*mapping=\([a-zA-Z0-9_-]*\).*/\1/p')
            [[ -z "$slot" || -z "$mapping" ]] && continue

            local mn="${mapping_node[$mapping]}"
            if [[ -n "$mn" && "$mn" != "$hostname" ]]; then
                continue
            fi

            local device_id="${mapping_device[$mapping]}"
            [[ -z "$device_id" ]] && continue

            if echo "$current_devices" | grep -q "^${device_id}$"; then
                continue
            fi

            log "Prestrip: removing ghost usb${slot} (mapping=$mapping, id=$device_id) from VM $vmid"
            sed -i "/^usb${slot}:[[:space:]]*mapping=${mapping}/d" "$config"
            stripped=$((stripped + 1))
        done < <(grep -E "^usb[0-9]+:[[:space:]]*mapping=" "$config")
    done
    log "Prestrip: complete ($stripped line(s) removed)"
}

# Phantom-attach detection — runs every iteration, rate-limited internally.
# Why this exists: when `qm start` runs while pmxcfs is wedged (or shortly
# after pmxcfs recovery), QEMU may accept the conf's USB pass-through entries
# and silently fail the actual host-device bind. The conf says the slot is
# attached; QEMU's monitor disagrees; the device doesn't appear in the guest.
# Operator's manual fix: delete the slot, let daemon re-add. This automates
# that — query `info usb` per running VM, find usbN slots present in conf
# but absent from QEMU's runtime, delete them, daemon re-adds next iteration.
#
# Today's 2026-06-05 17:00 manifestation: VM 110 boot, kb passed through
# but mouse/bt/webcam were "fake attached" — in conf, not in QEMU. Operator
# delete + auto re-add fixed it.
PHANTOM_USB_INTERVAL="${PHANTOM_USB_INTERVAL:-10}"             # seconds between phantom-check scans
PHANTOM_USB_BOOT_GRACE="${PHANTOM_USB_BOOT_GRACE:-30}"         # per-VM grace after qm start (USB enum takes a few seconds)
PHANTOM_USB_DELETE_COOLDOWN="${PHANTOM_USB_DELETE_COOLDOWN:-60}" # per-(vmid,slot) cooldown between deletes (prevents thrash if re-add also fails)
PHANTOM_USB_MAX_RETRIES="${PHANTOM_USB_MAX_RETRIES:-5}"        # after N consecutive failed re-adds, stop deleting + log loud (prevents host-xhci poisoning from cycle storm)
PHANTOM_USB_LAST_CHECK_FILE="/var/run/usb-hotplug-phantom-last-check"
PHANTOM_USB_LAST_DELETE_DIR="/var/run/usb-hotplug-phantom-deletes"
PHANTOM_USB_RETRY_DIR="/var/run/usb-hotplug-phantom-retries"   # per-(vmid,slot) consecutive-failure counter

check_phantom_usb_attachments() {
    local now=$(date +%s)

    # Global rate limit
    local last_check=0
    [[ -f "$PHANTOM_USB_LAST_CHECK_FILE" ]] && last_check=$(cat "$PHANTOM_USB_LAST_CHECK_FILE" 2>/dev/null)
    [[ -z "$last_check" || ! "$last_check" =~ ^[0-9]+$ ]] && last_check=0
    if [[ $((now - last_check)) -lt "$PHANTOM_USB_INTERVAL" ]]; then
        return 0
    fi
    echo "$now" > "$PHANTOM_USB_LAST_CHECK_FILE"
    mkdir -p "$PHANTOM_USB_LAST_DELETE_DIR" 2>/dev/null
    mkdir -p "$PHANTOM_USB_RETRY_DIR" 2>/dev/null

    local vmid pid_file vm_start_ts conf monitor_output qmu_ids line slot
    for vmid in $(get_running_vms); do
        # Per-VM boot grace — QEMU's USB device enumeration takes 2-10s
        # after qm start; checking too early gives false positives.
        pid_file="/run/qemu-server/${vmid}.pid"
        [[ -f "$pid_file" ]] || continue
        vm_start_ts=$(stat -c %Y "$pid_file" 2>/dev/null)
        [[ -z "$vm_start_ts" || ! "$vm_start_ts" =~ ^[0-9]+$ ]] && continue
        if [[ $((now - vm_start_ts)) -lt "$PHANTOM_USB_BOOT_GRACE" ]]; then
            continue
        fi

        conf=$(qm_config_safe "$vmid") || continue

        # Snapshot QEMU's USB device list. If qm monitor returns no output
        # at all (no "Entering QEMU Monitor" banner), the QMP socket may be
        # wedged — skip this VM. The "info usb" output always includes the
        # tablet ID for normal VMs, so empty-ID output is a safe abort signal.
        monitor_output=$(timeout 5 bash -c "echo 'info usb' | qm monitor $vmid 2>/dev/null")
        if ! grep -q "Entering QEMU Monitor" <<<"$monitor_output"; then
            continue
        fi
        qmu_ids=$(grep -oE "ID: usb[0-9]+" <<<"$monitor_output" | awk '{print $2}' | sort -u)

        # For each usbN slot in conf with a mapping= or host= entry, check
        # QEMU has a matching ID. ID: usbN in qm monitor output corresponds
        # exactly to conf slot usbN (PVE sets QEMU device id = slot name).
        while IFS= read -r line; do
            slot=$(sed -n 's/^\(usb[0-9]\+\):.*/\1/p' <<<"$line")
            [[ -z "$slot" ]] && continue

            if grep -qx "$slot" <<<"$qmu_ids"; then
                # Attached, healthy. Reset retry counter for this slot.
                rm -f "${PHANTOM_USB_RETRY_DIR}/${vmid}.${slot}" 2>/dev/null
                continue
            fi

            # Phantom: in conf, not in QEMU. Check per-slot cooldown so we
            # don't loop if the re-add also fails (e.g. device truly absent).
            local cooldown_file="${PHANTOM_USB_LAST_DELETE_DIR}/${vmid}.${slot}"
            if [[ -f "$cooldown_file" ]]; then
                local last_delete since_delete
                last_delete=$(cat "$cooldown_file" 2>/dev/null)
                [[ -n "$last_delete" && "$last_delete" =~ ^[0-9]+$ ]] || last_delete=0
                since_delete=$((now - last_delete))
                if [[ "$since_delete" -lt "$PHANTOM_USB_DELETE_COOLDOWN" ]]; then
                    continue
                fi
            fi

            # Consecutive-failure backstop. Each phantom detection on a slot
            # whose re-add hasn't taken effect bumps the counter. After
            # PHANTOM_USB_MAX_RETRIES, stop deleting + log loud — repeated
            # cycle-enumerate on a stuck slot can poison the host xhci stack
            # (operator-confirmed standing rule). Counter is reset on the
            # next healthy attach (above).
            local retry_file="${PHANTOM_USB_RETRY_DIR}/${vmid}.${slot}"
            local retries=0
            [[ -f "$retry_file" ]] && retries=$(cat "$retry_file" 2>/dev/null)
            [[ -z "$retries" || ! "$retries" =~ ^[0-9]+$ ]] && retries=0
            if [[ "$retries" -ge "$PHANTOM_USB_MAX_RETRIES" ]]; then
                # Rate-limit the loud log to once per cooldown interval.
                local last_loud_file="${PHANTOM_USB_RETRY_DIR}/${vmid}.${slot}.loud"
                local last_loud=0
                [[ -f "$last_loud_file" ]] && last_loud=$(cat "$last_loud_file" 2>/dev/null)
                [[ -z "$last_loud" || ! "$last_loud" =~ ^[0-9]+$ ]] && last_loud=0
                if [[ $((now - last_loud)) -ge "$PHANTOM_USB_DELETE_COOLDOWN" ]]; then
                    log "Phantom USB STUCK: ${slot} on VM ${vmid} failed re-attach ${retries}+ times — refusing further delete/re-add (would poison host xhci). Likely cause: VM lacks qemu-xhci controller (was started with no USB devices in conf). Restart VM ${vmid} with usb${slot} in conf to fix."
                    echo "$now" > "$last_loud_file"
                fi
                continue
            fi

            log "Phantom USB: ${slot} on VM ${vmid} in conf but not in QEMU runtime; deleting (daemon will re-add) [retry=${retries}/${PHANTOM_USB_MAX_RETRIES}]"
            with_lock qm set "$vmid" --delete "$slot" 2>&1 | logger -t usb-hotplug-phantom
            echo "$now" > "$cooldown_file"
            echo "$((retries + 1))" > "$retry_file"
        done < <(grep -E "^usb[0-9]+:[[:space:]]*(mapping=|host=)" <<<"$conf")
    done
}

dedup_vm_mappings() {
    # Self-healing pass: scan running VMs for duplicate `mapping=X` entries
    # — multiple `usbN: mapping=X` lines referencing the SAME X. Delete all
    # but the lowest-numbered slot. Cleans up legacy duplicates from before
    # qm_config_safe + the tightened pre-add check were in place, and any
    # future ones if a partial-read race still slips past the safe reader.
    # Idempotent and cheap: when no duplicates exist (the steady state) it
    # does nothing past the conf read + parse.
    local vmid conf line slot mapping first_slot
    for vmid in $(get_running_vms); do
        conf=$(qm_config_safe "$vmid") || continue
        declare -A seen=()
        while IFS= read -r line; do
            slot=$(sed -n 's/^usb\([0-9]\+\):.*/\1/p' <<<"$line")
            mapping=$(sed -n 's/.*mapping=\([a-zA-Z0-9_-]*\).*/\1/p' <<<"$line")
            [[ -z "$slot" || -z "$mapping" ]] && continue
            if [[ -n "${seen[$mapping]:-}" ]]; then
                first_slot="${seen[$mapping]}"
                log "Dedup: removing duplicate usb${slot} mapping=${mapping} from VM ${vmid} (kept at usb${first_slot})"
                with_lock qm set "$vmid" --delete "usb${slot}" 2>&1 | logger -t usb-hotplug-dedup
            else
                seen[$mapping]=$slot
            fi
        done < <(grep -E "^usb[0-9]+:[[:space:]]*mapping=" <<<"$conf" | sort -t: -k1.4n)
        unset seen
    done
}

cleanup_pci_passthrough_conflicts() {
    [[ "${ENFORCE_PCI_EXCLUSIVITY}" != "1" ]] && return 0

    declare -A owner=()
    for vmid in $(get_running_vms); do
        while IFS= read -r line; do
            local mapping
            mapping=$(echo "$line" | sed -n 's/^hostpci[0-9]\+: mapping=\([a-zA-Z0-9_-]*\).*/\1/p')
            [[ -n "$mapping" ]] && owner["$mapping"]="$vmid"
        done < <(qm config "$vmid" 2>/dev/null | grep -E "^hostpci[0-9]+: mapping=")
    done

    for mapping in "${!owner[@]}"; do
        local owner_vmid="${owner[$mapping]}"
        for other_conf in /etc/pve/qemu-server/*.conf; do
            [[ -f "$other_conf" ]] || continue
            local other_vmid
            other_vmid=$(basename "$other_conf" .conf)
            [[ "$other_vmid" == "$owner_vmid" ]] && continue

            grep -qE "^hostpci[0-9]+: mapping=${mapping}($|[,[:space:]])" "$other_conf" || continue

            local slot
            slot=$(grep -E "^hostpci[0-9]+: mapping=${mapping}($|[,[:space:]])" "$other_conf" \
                   | sed -n 's/^hostpci\([0-9]\+\):.*/\1/p' | head -1)
            if [[ -n "$slot" ]]; then
                log "PCI exclusivity: removing $mapping (hostpci${slot}) from VM $other_vmid (owned by running VM $owner_vmid)"
                with_lock qm set "$other_vmid" -delete "hostpci${slot}" >/dev/null 2>&1
            fi
        done
    done
}

cleanup_stale_shared_mappings() {
    local current_gpu_vm="$1"
    local hostname=$(hostname)

    # Build a lookup of mapping name -> registered node from usb.cfg so we can
    # identify shared-* entries on the GPU VM whose physical device lives on
    # a different host. Process substitution keeps the array writes in this
    # shell (a piped while loop runs in a subshell and can't mutate the array).
    declare -A mapping_node
    while IFS='|' read -r m _ _ n; do
        mapping_node["$m"]="$n"
    done < <(get_usb_mappings)

    for vmid in $(qm list 2>/dev/null | awk 'NR>1 {print $1}'); do
        local is_gpu_vm=0
        [[ "$vmid" == "$current_gpu_vm" ]] && is_gpu_vm=1

        qm config "$vmid" 2>/dev/null | grep -E "^usb[0-9]+:.*mapping=shared-" | while IFS= read -r line; do
            local slot=$(echo "$line" | sed -n 's/^usb\([0-9]\+\):.*/\1/p')
            local mapping=$(echo "$line" | sed -n 's/.*mapping=\(shared-[a-zA-Z0-9_-]*\).*/\1/p')
            [[ -z "$slot" || -z "$mapping" ]] && continue

            if [[ "$is_gpu_vm" -eq 1 ]]; then
                # On the GPU VM, only scrub shared-* entries whose mapping
                # belongs to a different node. Same-node shared-* are managed
                # by the main loop's add/remove logic.
                local mn="${mapping_node[$mapping]}"
                if [[ -z "$mn" || "$mn" == "$hostname" ]]; then
                    continue
                fi
                log "Cleanup: removing foreign-node $mapping (node=$mn) from GPU VM $vmid"
            else
                log "Cleanup: removing stale $mapping from VM $vmid (current GPU VM: ${current_gpu_vm:-none})"
            fi
            with_lock qm set "$vmid" -delete "usb${slot}"
            sed -i "/${mapping}:${vmid}/d" "$STATE_FILE"
        done
    done
}

# ============================================================
# USB POOLS — plug-anywhere multi-device auto-assignment
# ============================================================
#
# Pools solve the "two identical USB devices, no unique serial" problem that
# standard PVE mappings can't: when you have N copies of the same VID:PID
# (game controllers, WiFi adapters, DACs, etc.), the only way to disambiguate
# them is by physical USB path — but pinning a path makes the device port-
# specific. A pool attaches whichever matching devices are present, each by
# its live bus-port (host=<port>), into the lowest FREE usbN slot — the same
# rule shared-* mappings use, so the two can never fight over a slot.
#
# Config file format — /etc/usb-hotplug/pools.conf
#   <pool_name>  <vid:pid>  <target_vmid>  <max_devices>  [usb3]
# Legacy lines with an extra first_slot field still parse:
#   <pool_name>  <vid:pid>  <target_vmid>  <first_slot>  <max_devices>  [usb3]
# (first_slot no longer reserves anything; see process_pools.)
#
# Slots are sticky: a device keeps its slot while plugged in; unplugging one
# device never moves another. Manually-configured host= slots for other
# devices are never touched.
#
# Pools fire on every poll alongside the mapping logic. Pool entries pointing
# at VMs not running on this host are silently skipped (qm status returns
# non-running for cross-node VMs), so the same pools.conf can be deployed
# fleet-wide if desired.

find_pool_paths() {
    # Print USB bus-port paths of devices matching VID:PID, lexicographically
    # sorted. Reads directly from /sys to avoid lsusb overhead and to get the
    # canonical bus-port format that qm host=... expects.
    local target="$1"
    local target_vid="${target%%:*}"
    local target_pid="${target##*:}"
    [[ -z "$target_vid" || -z "$target_pid" ]] && return 0
    target_vid="${target_vid,,}"
    target_pid="${target_pid,,}"

    local d v p
    for d in /sys/bus/usb/devices/*; do
        # Skip endpoint dirs (have ":") and root hubs (no idVendor file).
        [[ "$(basename "$d")" =~ : ]] && continue
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        v=$(cat "$d/idVendor" 2>/dev/null)
        p=$(cat "$d/idProduct" 2>/dev/null)
        if [[ "${v,,}" == "$target_vid" && "${p,,}" == "$target_pid" ]]; then
            basename "$d"
        fi
    done | sort
}

process_pools() {
    [[ ! -f "$POOLS_CONF" ]] && return 0

    # Two accepted line formats:
    #   new:    <name> <vid:pid> <target> <max_devices> [usb3]
    #   legacy: <name> <vid:pid> <target> <first_slot> <max_slots> [usb3]
    # Legacy first_slot no longer reserves slots; it is only used to recognise
    # pool slots written by an older daemon (detach-after-restart).
    local pool_name vidpid vmid f4 f5 f6 max_slots usb3_flag legacy_first
    while read -r pool_name vidpid vmid f4 f5 f6 _rest; do
        # Strip whole-line comments / blank lines (read loses the # split,
        # so check the first field).
        [[ -z "$pool_name" || "$pool_name" =~ ^# ]] && continue

        legacy_first=""
        if [[ "$f5" =~ ^[0-9]+$ ]]; then
            legacy_first=$f4; max_slots=$f5; usb3_flag=$f6
        else
            max_slots=$f4; usb3_flag=$f5
        fi

        # Validate required fields.
        if [[ -z "$vidpid" || -z "$vmid" || -z "$max_slots" ]]; then
            log_once "pool-bad-$pool_name" "pool: skipping incomplete entry: $pool_name"
            continue
        fi
        if ! [[ "$vidpid" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
            log_once "pool-bad-$pool_name" "pool $pool_name: invalid vid:pid '$vidpid'"
            continue
        fi
        # "shared" / "gpu" target → resolve to the current GPU VM (the same VM
        # that receives shared-* mappings), so ONE pool line follows whichever
        # GPU VM is running (e.g. 110 vs 111) instead of being pinned to a fixed
        # vmid. Resolved before the numeric check below so the rest is unchanged.
        if [[ "$vmid" == "shared" || "$vmid" == "gpu" ]]; then
            vmid=$(get_gpu_vm)
            if [[ -z "$vmid" ]]; then
                log_once "pool-nogpu-$pool_name" "pool $pool_name: 'shared' target but no running GPU VM; skipping"
                continue
            fi
        fi
        if ! [[ "$vmid" =~ ^[0-9]+$ && "$max_slots" =~ ^[0-9]+$ ]]; then
            log_once "pool-bad-$pool_name" "pool $pool_name: non-numeric vmid/max_devices"
            continue
        fi
        [[ "$max_slots" -lt 1 ]] && continue

        # Cross-node VMs are silently skipped — qm status returns non-running
        # for VMs not on this node.
        vm_running "$vmid" || continue

        local usb3_arg=""
        if [[ "$usb3_flag" == "usb3" || "$usb3_flag" == "1" ]]; then
            usb3_arg=",usb3=1"
        fi

        # Discover currently-present devices (sorted by bus-port path).
        local -a paths=()
        local p
        while IFS= read -r p; do
            paths+=("$p")
        done < <(find_pool_paths "$vidpid")

        local conf_snapshot
        conf_snapshot=$(qm_config_safe "$vmid") || continue

        # Dynamic, sticky slot assignment (2026-10-18). Pools no longer own a
        # fixed slot range: a fixed range let shared-* mappings (which take the
        # lowest free slot) land inside it, and the pool then refused to evict
        # them — leaving the 2nd identical device unattached forever.
        #   1. Adopt: any host=<port> slot whose port currently holds a device
        #      of this pool's VID:PID is ours. It stays exactly where it is.
        #   2. Attach: present devices not yet in any slot get the lowest free
        #      slot (same rule shared-* mappings use), up to max_devices.
        #   3. Detach: a host=<port> slot we own whose device is gone. "Ours" =
        #      attached by the pool during this daemon run (POOL_OWNED), or —
        #      after a daemon restart — inside the legacy first_slot range.
        #      Manually-configured host= slots for other devices are never touched.
        local line slot val port i
        local -A port_slot=()      # port -> slot, for this pool's present devices
        local -A present=()
        for p in "${paths[@]}"; do present[$p]=1; done
        local -a gone_slots=()
        while IFS= read -r line; do
            slot=$(sed -n 's/^usb\([0-9]\+\):.*/\1/p' <<<"$line")
            val=$(sed 's/^[^:]*:[[:space:]]*//' <<<"$line")
            [[ "$val" =~ ^host=([0-9]+-[0-9.]+)($|,) ]] || continue
            port="${BASH_REMATCH[1]}"
            if [[ -n "${present[$port]:-}" ]]; then
                port_slot[$port]=$slot
                POOL_OWNED["$vmid:$slot"]="$pool_name"
            elif [[ "${POOL_OWNED[$vmid:$slot]:-}" == "$pool_name" ]] || \
                 [[ "$legacy_first" =~ ^[0-9]+$ && "$slot" -ge "$legacy_first" && "$slot" -lt $((legacy_first + max_slots)) \
                    && ! -e "/sys/bus/usb/devices/$port" ]]; then
                # Ours and our device is no longer on that port (unplugged, or
                # something else is plugged there now) -> free the slot.
                gone_slots+=("$slot")
            fi
        done < <(grep -E '^usb[0-9]+:' <<<"$conf_snapshot")

        for slot in "${gone_slots[@]}"; do
            log "pool $pool_name: detach VM $vmid usb${slot} (device gone)"
            with_lock qm set "$vmid" "--delete" "usb${slot}" 2>&1 | logger -t usb-hotplug-pool
            unset "POOL_OWNED[$vmid:$slot]"
            conf_snapshot=$(grep -vE "^usb${slot}:" <<<"$conf_snapshot")
        done

        local attached=${#port_slot[@]} desired
        for p in "${paths[@]}"; do
            [[ -n "${port_slot[$p]:-}" ]] && continue
            if [[ "$attached" -ge "$max_slots" ]]; then
                log_once "pool-max-$pool_name-$p" "pool $pool_name: $p present but pool already has $max_slots device(s) attached (max_devices); not attaching"
                continue
            fi
            slot=""
            for ((i=0; i<MAX_USB_SLOTS; i++)); do
                grep -qE "^usb${i}:" <<<"$conf_snapshot" && continue
                slot=$i; break
            done
            if [[ -z "$slot" ]]; then
                log_once "pool-full-$pool_name-$p" "pool $pool_name: no free usb slot on VM $vmid for $p (all $MAX_USB_SLOTS in use)"
                continue
            fi
            desired="host=${p}${usb3_arg}"
            log "pool $pool_name: attach VM $vmid usb${slot} -> $p"
            with_lock qm set "$vmid" "--usb${slot}" "$desired" 2>&1 | logger -t usb-hotplug-pool
            POOL_OWNED["$vmid:$slot"]="$pool_name"
            conf_snapshot+=$'\n'"usb${slot}: ${desired}"
            attached=$((attached + 1))
        done
    done < "$POOLS_CONF"
}

monitor_usb_mappings() {
    log "USB Mapping Hotplug Daemon started (interval: ${INTERVAL}s)"
    log "Assignment rules:"
    log "  vm{ID}-*   devices -> VM {ID} when running"
    log "  shared-*   devices -> VM with GPU mapping (${GPU_MAPPING:-unset})"
    log "  disabled-* devices -> never auto-assigned"
    log "PCI exclusivity: ${ENFORCE_PCI_EXCLUSIVITY:-1} (strip hostpci mappings from non-owner VMs)"

    touch "$STATE_FILE"

    local last_gpu_vm="<unset>"
    local last_running_vms=""
    local gpu_miss_count=0
    local daemon_start_ts=$(date +%s)
    log "Boot grace: ${BOOT_GRACE_SECONDS}s suppressing cleanup until GPU VM appears (avoids stripping shared-* before pve-guests starts VM 110)"

    while true; do
        # v2 — LIMBO gate. If pmxcfs is mid-resync (cluster membership change
        # in progress, or partial CPG state), back off without any writes.
        # Avoids issuing pvesh/qm-set calls into the stale-read window.
        if ! pmxcfs_limbo_check; then
            log "pmxcfs LIMBO (mount RO or .version unreadable) — backing off ${INTERVAL}s"
            sleep "$INTERVAL"
            continue
        fi

        local running_vms=$(get_running_vms | tr '\n' ' ')
        local gpu_vm=$(get_gpu_vm)

        if [[ "$running_vms" != "$last_running_vms" ]]; then
            log "Running VMs: $running_vms"
            last_running_vms="$running_vms"
            cleanup_pci_passthrough_conflicts
            dedup_vm_mappings
        fi

        # Debounce GPU VM disappearance — two cases:
        # (A) Mid-run transient: was present, gpu_vm momentarily empty during
        #     qm start/stop. GPU_MISS_THRESHOLD consecutive empty polls = ~4s
        #     defer.
        # (B) Boot-time: daemon up before pve-guests finished. last_gpu_vm is
        #     "<unset>", gpu_vm empty. Without defer, cleanup_stale* runs on
        #     the not-yet-started VM's conf and STRIPS all shared-* entries
        #     (caused 2026-06-04 reboot incident). Use BOOT_GRACE_SECONDS
        #     elapsed since daemon-start so pve-guests has time (~3 min)
        #     to bring VM 110 up.
        local now=$(date +%s)
        local uptime=$((now - daemon_start_ts))
        local in_boot_grace=0
        [[ "$last_gpu_vm" == "<unset>" && $uptime -lt $BOOT_GRACE_SECONDS ]] && in_boot_grace=1

        local skip_cleanup=0
        if [[ -z "$gpu_vm" && -n "$last_gpu_vm" ]]; then
            if [[ $in_boot_grace -eq 1 ]]; then
                # Boot grace: suppress cleanup silently (don't spam the log every 2s).
                # Periodic heartbeat every 30s so operator knows we're alive.
                if [[ $((uptime % 30)) -lt $INTERVAL ]]; then
                    log "Boot grace: GPU VM not yet detected (${uptime}s/${BOOT_GRACE_SECONDS}s) — deferring cleanup"
                fi
                skip_cleanup=1
            else
                gpu_miss_count=$((gpu_miss_count + 1))
                if [[ $gpu_miss_count -lt $GPU_MISS_THRESHOLD ]]; then
                    if [[ "$last_gpu_vm" == "<unset>" ]]; then
                        log "GPU VM not detected after boot grace (miss $gpu_miss_count/$GPU_MISS_THRESHOLD) — deferring cleanup"
                    else
                        log "GPU VM ($last_gpu_vm) transiently missing (miss $gpu_miss_count/$GPU_MISS_THRESHOLD) — deferring cleanup"
                    fi
                    skip_cleanup=1
                fi
            fi
        else
            gpu_miss_count=0
        fi

        if [[ $skip_cleanup -eq 1 ]]; then
            sleep $INTERVAL
            continue
        fi

        if [[ "$gpu_vm" != "$last_gpu_vm" ]]; then
            if [[ "$last_gpu_vm" != "<unset>" ]]; then
                if [[ -n "$gpu_vm" ]]; then
                    log "GPU VM detected: VM $gpu_vm (gets shared-* devices)"
                else
                    log "No GPU VM detected"
                fi
            fi
            cleanup_stale_shared_mappings "$gpu_vm"
            last_gpu_vm="$gpu_vm"
        fi

        local current_devices=$(lsusb | awk '{print $6}')
        local hostname=$(hostname)

        # IMPORTANT: process substitution `< <(...)` keeps the while body in
        # the parent shell so batch_queue_add's appends to BATCH_VM/FLAG/VAL
        # persist into batch_flush below. The old `get_usb_mappings | while`
        # pipe put the loop in a subshell — batch_queue_add updates died with
        # it and batch_flush always saw an empty queue (no pvesh set ever
        # ran). Same pattern already used by prestrip_all_vms (line ~217)
        # and dedup_vm_mappings (~409).
        while IFS='|' read -r mapping device_id description node; do
            if [[ "$mapping" =~ ^disabled- ]]; then
                continue
            fi

            # Skip mappings registered to a different node. Multiple mappings
            # can share a vendor:product ID (Logitech 046d:c52b is reused
            # across receivers / mice / keyboards), so the lsusb presence
            # check below isn't sufficient to prove THIS mapping is local.
            # The node= field in /etc/pve/mapping/usb.cfg is authoritative.
            if [[ -n "$node" && "$node" != "$hostname" ]]; then
                continue
            fi

            local target_vm=""

            if [[ "$mapping" =~ ^vm([0-9]+)- ]]; then
                target_vm="${BASH_REMATCH[1]}"
                # Don't gate on vm_running. Ghost usbN lines on a STOPPED VM
                # block its next boot — daemon needs to strip them whether the
                # VM is running or not. Add-path still requires running (below).
            elif [[ "$mapping" =~ ^shared- ]]; then
                target_vm="$gpu_vm"
                [[ -z "$target_vm" ]] && continue
            else
                continue
            fi

            if echo "$current_devices" | grep -q "^${device_id}$"; then
                # Device present — can only attach to a running VM. Use batch
                # queue: each iteration accumulates adds/deletes and flushes
                # ONE pvesh call per VM at end. Avoids the dock-unplug-storm
                # pattern (4-5 individual qm sets in 2s) from racing inside
                # pmxcfs.
                if vm_running "$target_vm" && ! mapping_already_assigned "$target_vm" "$mapping"; then
                    # Find free slot considering both live conf AND already-queued ops.
                    local conf_path="/etc/pve/qemu-server/${target_vm}.conf"
                    local slot=""
                    for ((i=0; i<MAX_USB_SLOTS; i++)); do
                        if grep -q "^usb${i}:" "$conf_path"; then continue; fi
                        # Skip if already queued for this VM in this iteration.
                        local queued=0
                        local j
                        for ((j=0; j<${#BATCH_VM[@]}; j++)); do
                            if [[ "${BATCH_VM[$j]}" == "$target_vm" && "${BATCH_FLAG[$j]}" == "--usb${i}" ]]; then
                                queued=1; break
                            fi
                        done
                        [[ $queued -eq 0 ]] && { slot=$i; break; }
                    done
                    if [[ -n "$slot" ]]; then
                        log "Queue add: VM $target_vm mapping=$mapping at usb${slot} (id=$device_id)"
                        batch_queue_add "$target_vm" "$slot" "$mapping"
                        # Update state file optimistically (legacy convention).
                        echo "${mapping}:${target_vm}" >> "$STATE_FILE"
                    else
                        log "No free slot for $mapping on VM $target_vm (conf+batch both full)"
                    fi
                fi
            else
                # Device absent — strip ghost mapping regardless of VM state.
                # Running VM: queue for batch (pvesh handles --delete cleanly
                # whether running or stopped). Stopped VM: direct conf sed
                # because pvesh on stopped VMs can't unstage usbN entries
                # that QEMU never registered (legacy remove_mapping_from_stopped_vm
                # handles this via sed).
                if mapping_already_assigned "$target_vm" "$mapping"; then
                    if vm_running "$target_vm"; then
                        local conf_path="/etc/pve/qemu-server/${target_vm}.conf"
                        local slot
                        slot=$(grep -E "^usb[0-9]+:[[:space:]]*mapping=${mapping}([,[:space:]]|$)" "$conf_path" \
                               | sed -n 's/^usb\([0-9]\+\):.*/\1/p' | head -1)
                        if [[ -n "$slot" ]]; then
                            log "Queue delete: VM $target_vm usb${slot} (was $mapping)"
                            batch_queue_delete "$target_vm" "$slot"
                            sed -i "/${mapping}:${target_vm}/d" "$STATE_FILE" 2>/dev/null
                        fi
                    else
                        remove_mapping_from_stopped_vm "$target_vm" "$mapping"
                    fi
                fi
            fi
        done < <(get_usb_mappings)

        # v2 — flush the batched ops as one pvesh call per affected VM. This
        # is the dock-unplug-storm mitigation point.
        batch_flush

        # Pools (multi-device plug-anywhere) — runs after mapping logic so a
        # pool can't fight with a mapping that already grabbed the device on
        # this poll. Pools targeting cross-node VMs are silently skipped.
        # NOTE: pools still use the legacy qm-set path. Could be migrated to
        # batch later if pool churn proves to be a contention source.
        process_pools

        # Phantom USB detection — find conf slots that QEMU silently failed
        # to bind (the "fake added" state operator hit 2026-06-05 17:00 after
        # the boot-time pmxcfs wedge). Internally rate-limited; cheap when
        # nothing's wrong (one qm monitor call per running VM per 10s).
        check_phantom_usb_attachments

        sleep "$INTERVAL"
    done
}

case "${1:-}" in
    "--prestrip")
        prestrip_all_vms
        exit 0
        ;;
    "--help"|"-h")
        echo "Usage: $0 [options]"
        echo ""
        echo "Options:"
        echo "  --help, -h     Show this help message"
        echo "  --test, -t     Test configuration and show detected mappings"
        echo "  --status, -s   Show current status and state"
        echo ""
        echo "Uses Proxmox USB device mappings at /etc/pve/mapping/usb.cfg."
        echo ""
        echo "Naming convention:"
        echo "  vm{ID}-*   mappings go to VM {ID} when running"
        echo "  shared-*   mappings go to VM with GPU mapping (${GPU_MAPPING:-unset})"
        echo "  disabled-* mappings are never auto-assigned"
        echo ""
        echo "Config: $CONFIG_FILE"
        echo "Log:    $LOG_FILE"
        echo "State:  $STATE_FILE"
        exit 0
        ;;
    "--test"|"-t")
        echo "USB Mapping Hotplug Daemon - Test Mode"
        echo "======================================"
        echo ""
        echo "Available USB device mappings:"
        get_usb_mappings | while IFS='|' read -r mapping device_id description; do
            echo "  $mapping: $device_id - $description"
        done
        echo ""
        echo "Current USB devices:"
        lsusb | awk '{print "  " $6 " - " $0}'
        echo ""
        echo "Running VMs:"
        for vm in $(qm list | awk 'NR>1 {print $1}'); do
            if qm status "$vm" 2>/dev/null | grep -q "status: running"; then
                if [[ -n "$GPU_MAPPING" ]] && qm config "$vm" | grep -q "mapping=${GPU_MAPPING}"; then
                    echo "  VM $vm: running (GPU VM - receives shared-* devices)"
                else
                    echo "  VM $vm: running (receives vm${vm}-* devices)"
                fi
            fi
        done
        exit 0
        ;;
    "--status"|"-s")
        echo "USB Mapping Hotplug Daemon - Status"
        echo "==================================="
        echo ""
        if [[ -f "$STATE_FILE" ]]; then
            echo "Current USB mapping passthroughs:"
            cat "$STATE_FILE" | while IFS=':' read -r mapping vmid; do
                echo "  $mapping -> VM $vmid"
            done
        else
            echo "No active passthroughs"
        fi
        echo ""
        echo "Recent log entries:"
        tail -10 "$LOG_FILE" 2>/dev/null || echo "No log file found"
        exit 0
        ;;
esac

monitor_usb_mappings
