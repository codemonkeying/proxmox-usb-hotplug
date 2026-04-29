#!/bin/bash
# usb-mapping-helper.sh - USB detection using Proxmox device mappings

MAPPING_CONFIG="/etc/pve/mapping/usb.cfg"
PROTECTED_VMS_CONFIG="/etc/usb-hotplug-protected-vms.conf"

# Parse /etc/pve/mapping/usb.cfg into "mapping|device_id|description|node" lines.
# Format in source file:
#   mapping-name
#       map id=vendor:product,node=nodename
# The node field is emitted as the 4th pipe-delimited column. When a mapping
# has multiple `map` lines on different nodes, only the last one parsed wins
# (current installs use one node per mapping).
get_usb_mappings() {
    [[ -f "$MAPPING_CONFIG" ]] || return 1

    local mapping=""
    local device=""
    local node=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            if [[ -n "$mapping" && -n "$device" ]]; then
                echo "${mapping}|${device}|${mapping}|${node}"
            fi
            mapping="$line"
            device=""
            node=""
        elif [[ "$line" =~ ^[[:space:]]+map[[:space:]] ]]; then
            if [[ "$line" =~ id=([^,[:space:]]+) ]]; then
                device="${BASH_REMATCH[1]}"
            fi
            if [[ "$line" =~ node=([^,[:space:]]+) ]]; then
                node="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$MAPPING_CONFIG"

    if [[ -n "$mapping" && -n "$device" ]]; then
        echo "${mapping}|${device}|${mapping}|${node}"
    fi
}

is_vm_protected() {
    local vmid=$1
    if [[ -f "$PROTECTED_VMS_CONFIG" ]]; then
        grep -q "^${vmid}$" "$PROTECTED_VMS_CONFIG"
        return $?
    fi
    return 1
}

get_available_mappings_for_vm() {
    local vmid=$1
    local current_devices=$(lsusb | awk '{print $6}')
    local hostname=$(hostname)

    get_usb_mappings | while IFS='|' read -r mapping device_id description node; do
        # Skip mappings registered to a different node. Multiple distinct
        # mappings can share a vendor:product (e.g. several Logitech receivers
        # at 046d:c52b), so a local lsusb hit isn't enough to prove THIS
        # mapping belongs here — the node= field is authoritative.
        if [[ -n "$node" && "$node" != "$hostname" ]]; then
            continue
        fi
        if echo "$current_devices" | grep -q "^${device_id}$"; then
            if [[ "$mapping" =~ ^vm${vmid}- ]] || [[ "$mapping" =~ ^shared- ]]; then
                echo "${mapping}|${device_id}|${description}"
            fi
        fi
    done
}

mapping_already_assigned() {
    local vmid=$1
    local mapping=$2
    local config="/etc/pve/qemu-server/${vmid}.conf"
    grep -q "mapping=${mapping}" "$config" 2>/dev/null
}

add_mapping_to_vm() {
    local vmid=$1
    local mapping=$2
    local description=$3
    local config="/etc/pve/qemu-server/${vmid}.conf"

    is_vm_protected "$vmid" && return 1
    mapping_already_assigned "$vmid" "$mapping" && return 0

    local slot
    for i in {0..14}; do
        if ! grep -q "^usb${i}:" "$config"; then
            slot=$i
            break
        fi
    done

    if [[ -n "$slot" ]]; then
        echo "usb${slot}: mapping=${mapping},usb3=1" >> "$config"
        echo "Added USB mapping: $description ($mapping) as usb${slot}"
        return 0
    else
        echo "No available USB slots for: $description ($mapping)"
        return 1
    fi
}

remove_mapping_from_vm() {
    local vmid=$1
    local mapping=$2
    local config="/etc/pve/qemu-server/${vmid}.conf"

    is_vm_protected "$vmid" && return 1

    local slot=$(grep "mapping=${mapping}" "$config" | sed -n 's/^usb\([0-9]\+\):.*/\1/p')

    if [[ -n "$slot" ]]; then
        echo "Removing USB mapping $mapping from VM $vmid (usb${slot})"
        qm set "$vmid" -delete usb${slot}
        return 0
    fi
    return 1
}

add_available_mappings_to_config() {
    local vmid=$1
    local config_file=$2

    if is_vm_protected "$vmid"; then
        echo "VM $vmid is protected from USB hotplug management"
        return 0
    fi

    echo "Detecting connected USB device mappings for VM $vmid..."

    local added_count=0

    get_available_mappings_for_vm "$vmid" | while IFS='|' read -r mapping device_id description; do
        local slot
        for i in {0..14}; do
            if ! grep -q "^usb${i}:" "$config_file"; then
                slot=$i
                break
            fi
        done

        if [[ -n "$slot" ]]; then
            echo "usb${slot}: mapping=${mapping},usb3=1" >> "$config_file"
            echo "Added USB mapping: $description ($mapping) as usb${slot}"
            ((added_count++))
        else
            echo "No available USB slots for: $description ($mapping)"
        fi
    done

    if [[ $added_count -gt 0 ]]; then
        echo "Added $added_count USB device mappings to config"
    else
        echo "No additional USB device mappings detected or all slots full"
    fi

    return $added_count
}

add_protected_vm() {
    local vmid=$1
    echo "$vmid" >> "$PROTECTED_VMS_CONFIG"
    echo "VM $vmid added to protected list"
}

remove_protected_vm() {
    local vmid=$1
    if [[ -f "$PROTECTED_VMS_CONFIG" ]]; then
        sed -i "/^${vmid}$/d" "$PROTECTED_VMS_CONFIG"
        echo "VM $vmid removed from protected list"
    fi
}

list_protected_vms() {
    echo "Protected VMs (excluded from USB hotplug management):"
    if [[ -f "$PROTECTED_VMS_CONFIG" ]]; then
        while read -r vmid; do
            [[ -n "$vmid" ]] && echo "  $vmid"
        done < "$PROTECTED_VMS_CONFIG"
    else
        echo "  (none)"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    case "${1:-}" in
        "list-mappings")
            echo "Available USB device mappings:"
            get_usb_mappings | while IFS='|' read -r mapping device_id description node; do
                echo "  $mapping: $device_id - $description (node=${node:-any})"
            done
            ;;
        "list-available")
            vmid="${2:-}"
            if [[ -z "$vmid" ]]; then
                echo "Usage: $0 list-available VMID"
                exit 1
            fi
            echo "Available USB mappings for VM $vmid:"
            get_available_mappings_for_vm "$vmid" | while IFS='|' read -r mapping device_id description; do
                echo "  $mapping: $device_id - $description"
            done
            ;;
        "add-mappings")
            vmid="${2:-}"
            config_file="${3:-}"
            if [[ -z "$vmid" ]] || [[ -z "$config_file" ]]; then
                echo "Usage: $0 add-mappings VMID CONFIG_FILE"
                exit 1
            fi
            add_available_mappings_to_config "$vmid" "$config_file"
            ;;
        "protect")
            vmid="${2:-}"
            if [[ -z "$vmid" ]]; then
                echo "Usage: $0 protect VMID"
                exit 1
            fi
            add_protected_vm "$vmid"
            ;;
        "unprotect")
            vmid="${2:-}"
            if [[ -z "$vmid" ]]; then
                echo "Usage: $0 unprotect VMID"
                exit 1
            fi
            remove_protected_vm "$vmid"
            ;;
        "list-protected")
            list_protected_vms
            ;;
        *)
            echo "USB Mapping Helper"
            echo ""
            echo "Usage:"
            echo "  $0 list-mappings              List all USB device mappings"
            echo "  $0 list-available VMID        List mappings available to VMID"
            echo "  $0 add-mappings VMID CONFIG   Add available mappings to CONFIG file"
            echo "  $0 protect VMID               Exclude VMID from hotplug management"
            echo "  $0 unprotect VMID             Remove VMID from protected list"
            echo "  $0 list-protected             List protected VMs"
            ;;
    esac
fi
