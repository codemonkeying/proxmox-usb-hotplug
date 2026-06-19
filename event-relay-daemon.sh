#!/bin/bash
# event-relay-daemon.sh — host->guest signal translation layer
# Part of the proxmox-usb-hotplug family. Relays host-side STATE signals
# (lid, ACPI, sysfs values) that QEMU cannot pass through, to a target VM,
# resolving "shared"/"gpu" to the current GPU VM via the same logic the
# usb-mapping-daemon uses — so a slot follows whichever desktop VM is up,
# exactly like shared-* USB mappings.
#
# This handles the RELAY class only (switch/ACPI/sysfs state that can't be
# evdev-forwarded). Keypress devices (e.g. ThinkPad Extra Buttons) belong in
# the VM's input-linux args at start, not here.
#
# Config: /etc/usb-hotplug/event-relays.conf — one slot per non-comment line:
#   <name>  <source>  <target>  <handler>
#     source:  acpi-lid                 -> /proc/acpi/button/lid/LID/state (open|closed)
#              sysfs:<path>:<open-value> -> poll file; state="open" if ==open-value else "closed"
#     target:  <vmid> | shared | gpu     (shared/gpu = current GPU VM)
#     handler: token passed to the guest dispatcher: vm-event-handler <handler> <state>
#
# On a state CHANGE (never on startup) it runs, unless DRY_RUN=1:
#   qm guest exec <vmid> -- /usr/local/bin/vm-event-handler <handler> <state>
#
# Env: EVENT_RELAY_DRY_RUN=1 (log only), EVENT_RELAY_INTERVAL (default 2s),
#      EVENT_RELAY_CONFIG, EVENT_RELAY_HANDLER (guest dispatcher path).

set -uo pipefail

CONFIG="${EVENT_RELAY_CONFIG:-/etc/usb-hotplug/event-relays.conf}"
USB_CONF="${EVENT_RELAY_USB_CONF:-/etc/usb-hotplug/config}"
INTERVAL="${EVENT_RELAY_INTERVAL:-2}"
DRY_RUN="${EVENT_RELAY_DRY_RUN:-0}"
GUEST_HANDLER="${EVENT_RELAY_HANDLER:-/usr/local/bin/vm-event-handler}"

log() { echo "[$(date '+%F %T')] $*"; }

# GPU_MAPPING — read (not source) from the usb-hotplug config to avoid var clashes.
GPU_MAPPING="$(grep -E '^GPU_MAPPING=' "$USB_CONF" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'"' ')"

# Mirror of usb-mapping-daemon.sh get_gpu_vm(): first running VM whose live
# config carries the GPU resource mapping. (Kept local for now so this service
# never has to touch the running USB daemon's code; fold into the shared helper
# later as cleanup.)
get_gpu_vm() {
    [[ -z "$GPU_MAPPING" ]] && return 1
    local vm
    for vm in $(qm list 2>/dev/null | awk 'NR>1 && $3=="running" {print $1}'); do
        if qm config "$vm" 2>/dev/null | grep -q "mapping=${GPU_MAPPING}"; then
            echo "$vm"; return 0
        fi
    done
    return 1
}

read_source_state() {
    local src="$1"
    case "$src" in
        acpi-lid)
            local s
            s="$(awk '{print $2}' /proc/acpi/button/lid/LID/state 2>/dev/null)"
            [[ "$s" == "open" || "$s" == "closed" ]] && echo "$s" || echo "unknown"
            ;;
        sysfs:*)
            # sysfs:<path>:<open-value>
            local rest="${src#sysfs:}" path openval v
            openval="${rest##*:}"; path="${rest%:*}"
            v="$(cat "$path" 2>/dev/null)"
            [[ -z "$v" ]] && { echo "unknown"; return; }
            [[ "$v" == "$openval" ]] && echo "open" || echo "closed"
            ;;
        *) echo "unknown" ;;
    esac
}

resolve_target() {
    case "$1" in
        shared|gpu) get_gpu_vm ;;
        [0-9]*)     echo "$1" ;;
        *)          return 1 ;;
    esac
}

relay() {
    local name="$1" target="$2" handler="$3" state="$4" vmid
    vmid="$(resolve_target "$target")" || { log "slot $name: target '$target' unresolved (no GPU VM running?); skip"; return; }
    [[ -z "$vmid" ]] && { log "slot $name: no running target for '$target'; skip"; return; }
    [[ "$(qm status "$vmid" 2>/dev/null | awk '{print $2}')" == "running" ]] || { log "slot $name: VM $vmid not running; skip"; return; }
    if [[ "$DRY_RUN" == "1" ]]; then
        log "DRY-RUN slot $name: state=$state -> would exec VM $vmid: vm-event-handler $handler $state"
        return
    fi
    log "slot $name: state=$state -> VM $vmid: vm-event-handler $handler $state"
    # Fire-and-forget (--synchronous 0): returns immediately with the guest pid,
    # so a slow/blocked handler can never wedge the agent or stall this loop.
    # The handler logs its own outcome to /var/log/vm-event-handler.log in-guest.
    qm guest exec "$vmid" --synchronous 0 -- "$GUEST_HANDLER" "$handler" "$state" >/dev/null 2>&1 \
        || log "slot $name: guest exec dispatch to VM $vmid FAILED (agent up?)"
}

declare -A LAST_STATE
log "event-relay starting (interval=${INTERVAL}s dry_run=${DRY_RUN} gpu_mapping=${GPU_MAPPING:-unset} config=$CONFIG)"
while :; do
    if [[ -f "$CONFIG" ]]; then
        while read -r name source target handler _rest; do
            [[ -z "${name:-}" || "$name" == \#* ]] && continue
            [[ -z "${source:-}" || -z "${target:-}" || -z "${handler:-}" ]] && continue
            state="$(read_source_state "$source")"
            [[ "$state" == "unknown" ]] && continue
            if [[ "${LAST_STATE[$name]:-}" != "$state" ]]; then
                if [[ -n "${LAST_STATE[$name]:-}" ]]; then
                    relay "$name" "$target" "$handler" "$state"
                else
                    log "slot $name: initial state=$state (target=$target) — no relay on startup"
                fi
                LAST_STATE[$name]="$state"
            fi
        done < "$CONFIG"
    fi
    sleep "$INTERVAL"
done
