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
    for i in {0..14}; do
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

    if with_lock qm set "$vmid" -usb${slot} "mapping=${mapping},usb3=1"; then
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
# specific. A pool dynamically assigns whichever devices are present to a
# fixed range of consecutive usbN slots on a target VM, sorted by USB path
# (lowest path = first slot).
#
# Config file format — /etc/usb-hotplug/pools.conf
#   <pool_name>  <vid:pid>  <target_vmid>  <first_slot>  <max_slots>  [usb3]
# One pool per non-comment line. Whitespace-separated. Pool name is free-form
# (used in logs only). max_slots is the upper bound on how many devices to
# attach simultaneously; extras are ignored. first_slot is the lowest usbN
# index the pool owns; the pool occupies [first_slot, first_slot+max_slots-1].
# Append "usb3" (or "1") as the optional 6th field to force usb3=1 on attach.
#
# Pool-owned slots are recognised by the daemon by their `host=<bus-port>`
# value (the format the pool itself writes). Slots in the pool range with a
# different format (mapping=..., host=<vid:pid>, etc.) are LEFT ALONE — the
# pool never clobbers a manually-configured slot.
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

    local pool_name vidpid vmid first_slot max_slots usb3_flag
    while read -r pool_name vidpid vmid first_slot max_slots usb3_flag _rest; do
        # Strip whole-line comments / blank lines (read loses the # split,
        # so check the first field).
        [[ -z "$pool_name" || "$pool_name" =~ ^# ]] && continue

        # Validate required fields.
        if [[ -z "$vidpid" || -z "$vmid" || -z "$first_slot" || -z "$max_slots" ]]; then
            log "pool: skipping incomplete entry: $pool_name"
            continue
        fi
        if ! [[ "$vidpid" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{4}$ ]]; then
            log "pool $pool_name: invalid vid:pid '$vidpid'"
            continue
        fi
        if ! [[ "$vmid" =~ ^[0-9]+$ && "$first_slot" =~ ^[0-9]+$ && "$max_slots" =~ ^[0-9]+$ ]]; then
            log "pool $pool_name: non-numeric vmid/first_slot/max_slots"
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

        # Discover currently-present devices and assign by sort order.
        local -a paths=()
        local p
        while IFS= read -r p; do
            paths+=("$p")
        done < <(find_pool_paths "$vidpid")

        local conf_snapshot
        conf_snapshot=$(qm config "$vmid" 2>/dev/null) || continue

        local i slot current_path current_conf desired
        for ((i=0; i<max_slots; i++)); do
            slot=$((first_slot + i))
            current_path="${paths[i]:-}"
            current_conf=$(echo "$conf_snapshot" | awk -v s="usb${slot}:" '$1==s {sub(/^[^:]+:[[:space:]]*/,""); print; exit}')

            if [[ -n "$current_path" ]]; then
                desired="host=${current_path}${usb3_arg}"
                if [[ "$current_conf" == "$desired" ]]; then
                    continue  # already correct
                fi

                if [[ -n "$current_conf" ]]; then
                    # Existing slot occupied — only overwrite if it's a pool-
                    # managed value (host=<bus-port>). Leave mappings + host=<vid:pid>
                    # entries alone.
                    if [[ "$current_conf" =~ ^host=[0-9]+-[0-9.]+($|,) ]]; then
                        log "pool $pool_name: VM $vmid usb${slot} path drift -> $current_path"
                        with_lock qm set "$vmid" "--usb${slot}" "$desired" 2>&1 | logger -t usb-hotplug-pool
                    else
                        log "pool $pool_name: VM $vmid usb${slot} occupied by non-pool entry (${current_conf}); skipping"
                    fi
                else
                    log "pool $pool_name: attach VM $vmid usb${slot} -> $current_path"
                    with_lock qm set "$vmid" "--usb${slot}" "$desired" 2>&1 | logger -t usb-hotplug-pool
                fi
            else
                # No device for this slot index — strip pool-owned ghosts only.
                if [[ -n "$current_conf" && "$current_conf" =~ ^host=[0-9]+-[0-9.]+($|,) ]]; then
                    log "pool $pool_name: detach VM $vmid usb${slot} (device gone)"
                    with_lock qm set "$vmid" "--delete" "usb${slot}" 2>&1 | logger -t usb-hotplug-pool
                fi
            fi
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

        get_usb_mappings | while IFS='|' read -r mapping device_id description node; do
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
                # Device present — can only attach to a running VM.
                if vm_running "$target_vm" && ! mapping_already_assigned "$target_vm" "$mapping"; then
                    add_mapping_to_running_vm "$target_vm" "$mapping" "$device_id" "$description"
                fi
            else
                # Device absent — strip ghost mapping regardless of VM state.
                if mapping_already_assigned "$target_vm" "$mapping"; then
                    if vm_running "$target_vm"; then
                        remove_mapping_from_running_vm "$target_vm" "$mapping"
                    else
                        remove_mapping_from_stopped_vm "$target_vm" "$mapping"
                    fi
                fi
            fi
        done

        # Pools (multi-device plug-anywhere) — runs after mapping logic so a
        # pool can't fight with a mapping that already grabbed the device on
        # this poll. Pools targeting cross-node VMs are silently skipped.
        process_pools

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
