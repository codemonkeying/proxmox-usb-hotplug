#!/bin/bash
# usb-mapping-daemon.sh - USB hotplug daemon using Proxmox device mappings

# Defaults — override in /etc/usb-hotplug/config
INTERVAL=2
GPU_MAPPING=""
LOG_FILE="/var/log/usb-hotplug.log"
STATE_FILE="/var/run/usb-hotplug.state"
AUTO_VM_FILE="/var/run/usb-hotplug-auto-vm.state"
LOCK_FILE="/var/run/usb-hotplug.lock"

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "${SCRIPT_DIR}/usb-mapping-helper.sh" 2>/dev/null || source "/usr/local/bin/usb-mapping-helper.sh"

CONFIG_FILE="${USB_HOTPLUG_CONFIG:-/etc/usb-hotplug/config}"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

with_lock() {
    exec 200>"$LOCK_FILE"
    flock -x 200
    "$@"
}

vm_running() {
    local vmid=$1
    qm status "$vmid" 2>/dev/null | grep -q "status: running"
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

    if qm config "$vmid" 2>/dev/null | grep -q "mapping=${mapping}"; then
        return 0
    fi

    local slot=""
    for i in {0..14}; do
        if ! qm config "$vmid" 2>/dev/null | grep -q "^usb${i}:"; then
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
        if qm config "$vmid" 2>/dev/null | grep -q "mapping=${mapping}"; then
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

    log "Removing USB mapping $mapping from VM $vmid"

    local slot=$(qm config "$vmid" | grep "mapping=${mapping}" | sed -n 's/^usb\([0-9]\+\):.*/\1/p')

    if [[ -n "$slot" ]]; then
        qm set "$vmid" -delete usb${slot}
        sed -i "/${mapping}:${vmid}/d" "$STATE_FILE"
        log "Removed mapping $mapping from VM $vmid (was usb${slot})"
    fi
}

monitor_usb_mappings() {
    log "USB Mapping Hotplug Daemon started (interval: ${INTERVAL}s)"
    log "Assignment rules:"
    log "  vm{ID}-*   devices -> VM {ID} when running"
    log "  shared-*   devices -> VM with GPU mapping (${GPU_MAPPING:-unset})"
    log "  disabled-* devices -> never auto-assigned"

    touch "$STATE_FILE"

    local last_gpu_vm=""
    local last_running_vms=""

    while true; do
        local running_vms=$(get_running_vms | tr '\n' ' ')
        local gpu_vm=$(get_gpu_vm)

        if [[ "$running_vms" != "$last_running_vms" ]]; then
            log "Running VMs: $running_vms"
            last_running_vms="$running_vms"
        fi

        if [[ "$gpu_vm" != "$last_gpu_vm" ]]; then
            if [[ -n "$gpu_vm" ]]; then
                log "GPU VM detected: VM $gpu_vm (gets shared-* devices)"
            else
                log "No GPU VM detected"
            fi
            last_gpu_vm="$gpu_vm"
        fi

        local current_devices=$(lsusb | awk '{print $6}')

        get_usb_mappings | while IFS='|' read -r mapping device_id description; do
            if [[ "$mapping" =~ ^disabled- ]]; then
                continue
            fi

            local target_vm=""

            if [[ "$mapping" =~ ^vm([0-9]+)- ]]; then
                target_vm="${BASH_REMATCH[1]}"
                vm_running "$target_vm" || continue
            elif [[ "$mapping" =~ ^shared- ]]; then
                target_vm="$gpu_vm"
                [[ -z "$target_vm" ]] && continue
            else
                continue
            fi

            if echo "$current_devices" | grep -q "^${device_id}$"; then
                if ! mapping_already_assigned "$target_vm" "$mapping"; then
                    add_mapping_to_running_vm "$target_vm" "$mapping" "$device_id" "$description"
                fi
            else
                if mapping_already_assigned "$target_vm" "$mapping"; then
                    remove_mapping_from_running_vm "$target_vm" "$mapping"
                fi
            fi
        done

        sleep "$INTERVAL"
    done
}

case "${1:-}" in
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
