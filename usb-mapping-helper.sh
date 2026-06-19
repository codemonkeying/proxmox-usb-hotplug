#!/bin/bash
# usb-mapping-helper.sh - USB detection using Proxmox device mappings

MAPPING_CONFIG="/etc/pve/mapping/usb.cfg"
PROTECTED_VMS_CONFIG="/etc/usb-hotplug-protected-vms.conf"

# safe_append_conf — append a config line to a PVE conf file, ensuring the
# destination file ends with a newline FIRST. Without this guard, a profile
# file that's missing a trailing newline (vim with `endofline` off, git diff
# artifact, hand-edit, etc.) causes the appended line to be glued onto the
# previous line. Caught 2026-06-08 night: 110_auto.conf had no trailing
# newline; helper appended "usb0: ..." onto the end of "vmgenid: <guid>" →
# QEMU saw "vmgenid,guid=<guid>usb0: mapping=..." and bailed with exit 1.
# Use this anywhere a `>> "$file"` append would be unsafe.
safe_append_conf() {
    local line=$1
    local file=$2
    if [[ -s "$file" ]]; then
        local last
        last=$(tail -c1 "$file" | od -An -tx1 | tr -d ' \n')
        if [[ "$last" != "0a" ]]; then
            printf '\n' >> "$file"
        fi
    fi
    printf '%s\n' "$line" >> "$file"
}

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
    # Returns 0 (true) if the mapping is already attached to the VM,
    # 1 (false) if not, 0 (true / FAIL-CLOSED) if the conf can't be read
    # reliably. The fail-closed branch matters because the caller pattern is
    #   if ! mapping_already_assigned ... ; then add ; fi
    # — a false-negative on partial conf read would cause duplicate adds.
    # That's the 2026-06-05 16:12 VM 110 triple-Btooth6 incident shape.
    local vmid=$1
    local mapping=$2
    local config="/etc/pve/qemu-server/${vmid}.conf"
    if [[ ! -f "$config" ]]; then
        return 0
    fi
    if ! timeout 5 grep -q "^name:" "$config" 2>/dev/null; then
        # Conf read timed out, file empty, or no name field — pmxcfs is
        # serving partial data. Fail closed: pretend it's already there so
        # we don't add a duplicate.
        return 0
    fi
    grep -qE "^usb[0-9]+:[[:space:]]*mapping=${mapping}([,[:space:]]|$)" "$config" 2>/dev/null
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
        safe_append_conf "usb${slot}: mapping=${mapping},usb3=1" "$config"
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
            safe_append_conf "usb${slot}: mapping=${mapping},usb3=1" "$config_file"
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

# ---------------------------------------------------------------------------
# PCI mappings — conditional attachment for hostpci passthrough
# ---------------------------------------------------------------------------
# Mirrors the USB pattern: shared-* mappings get attached to whichever VM
# start.sh is launching IF the device is present on this node. vm${VMID}-*
# mappings only attach to that specific VMID. Mappings tagged with a different
# node= are ignored.
#
# Use case: PCI devices that are optional/portable (e.g. TBT3 dock USB
# controller) — present on the laptop most of the time but the VM should still
# start if the device is missing. This is in contrast to baked-in statics like
# hostpci0 (GPU) that the VM hard-depends on.

PCI_MAPPING_CONFIG="/etc/pve/mapping/pci.cfg"

# Parse /etc/pve/mapping/pci.cfg into "mapping|id|description|node|iommugroup|path"
# lines. Same shape as get_usb_mappings, just with two extra fields for PCI.
get_pci_mappings() {
    [[ -f "$PCI_MAPPING_CONFIG" ]] || return 1

    local mapping="" id="" node="" iommugroup="" path="" description=""

    flush() {
        if [[ -n "$mapping" && -n "$id" && -n "$path" ]]; then
            echo "${mapping}|${id}|${description:-$mapping}|${node}|${iommugroup}|${path}"
        fi
        mapping=""; id=""; node=""; iommugroup=""; path=""; description=""
    }

    while IFS= read -r line; do
        if [[ "$line" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            flush
            mapping="$line"
        elif [[ "$line" =~ ^[[:space:]]+map[[:space:]] ]]; then
            [[ "$line" =~ id=([^,[:space:]]+) ]] && id="${BASH_REMATCH[1]}"
            [[ "$line" =~ node=([^,[:space:]]+) ]] && node="${BASH_REMATCH[1]}"
            [[ "$line" =~ iommugroup=([^,[:space:]]+) ]] && iommugroup="${BASH_REMATCH[1]}"
            [[ "$line" =~ path=([^,[:space:]]+) ]] && path="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]+description[[:space:]]+(.*)$ ]]; then
            description="${BASH_REMATCH[1]}"
        fi
    done < "$PCI_MAPPING_CONFIG"
    flush
}

# Filter PCI mappings to those applicable to $vmid on this host AND whose
# device is actually present (in lspci output). Returns "mapping|id|description|path"
# (path is needed because the helper writes `hostpci<N>: mapping=NAME` — but
# we may want path-based diagnostics).
get_available_pci_mappings_for_vm() {
    local vmid=$1
    local hostname=$(hostname)
    # lspci shows the device regardless of driver binding (xhci_hcd OR vfio-pci),
    # so this works even if a prior VM session left it on vfio-pci.
    # `lspci -n` output: "BDF CLASS: VID:PID (rev XX)" — column 3 is what we want.
    local current_pci=$(lspci -n | awk '{print $3}')

    get_pci_mappings | while IFS='|' read -r mapping id description node iommugroup path; do
        # Skip mappings registered to a different node.
        if [[ -n "$node" && "$node" != "$hostname" ]]; then
            continue
        fi
        # Device must actually be present. We match on VID:PID since lspci ids
        # are what we have; path could be checked too but it's more brittle.
        if ! echo "$current_pci" | grep -qx "$id"; then
            continue
        fi
        # Only shared-* and vm${vmid}-* mappings are eligible. Other mappings
        # (e.g. host1_gpu) are hardcoded in the profile config and must
        # not be double-added.
        if [[ "$mapping" =~ ^vm${vmid}- ]] || [[ "$mapping" =~ ^shared- ]]; then
            echo "${mapping}|${id}|${description}|${path}"
        fi
    done
}

# Add available PCI mappings to $config_file as `hostpci<N>: mapping=NAME,pcie=1`.
# Slot search starts at 0 and finds the first unused hostpciN (PVE supports 0..15).
# Skips a mapping if it's already present in the config.
add_available_pci_mappings_to_config() {
    local vmid=$1
    local config_file=$2

    if is_vm_protected "$vmid"; then
        echo "VM $vmid is protected from PCI auto-attach"
        return 0
    fi

    echo "Detecting available PCI device mappings for VM $vmid..."

    local added_count=0

    while IFS='|' read -r mapping id description path; do
        [[ -z "$mapping" ]] && continue

        # Skip if this mapping is already in the config (matches both
        # `hostpci<N>: mapping=NAME` and possible `hostpci<N>: mapping=NAME,...`).
        if grep -qE "^hostpci[0-9]+:[[:space:]]*mapping=${mapping}([,[:space:]]|\$)" "$config_file"; then
            echo "PCI mapping $mapping already in config — skipping"
            continue
        fi

        local slot=""
        for i in {0..15}; do
            if ! grep -qE "^hostpci${i}:" "$config_file"; then
                slot=$i
                break
            fi
        done

        if [[ -n "$slot" ]]; then
            safe_append_conf "hostpci${slot}: mapping=${mapping},pcie=1" "$config_file"
            echo "Added PCI mapping: $description ($mapping, $path) as hostpci${slot}"
            ((added_count++))
        else
            echo "No available hostpci slots (0-15 all in use) for: $description ($mapping)"
        fi
    done < <(get_available_pci_mappings_for_vm "$vmid")

    if [[ $added_count -gt 0 ]]; then
        echo "Added $added_count PCI device mapping(s) to config"
    else
        echo "No additional PCI device mappings available"
    fi

    return 0
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
        "list-pci-mappings")
            echo "Available PCI device mappings:"
            get_pci_mappings | while IFS='|' read -r mapping id description node iommugroup path; do
                echo "  $mapping: $id @ $path (iommugroup=${iommugroup}, node=${node:-any})"
                [[ -n "$description" && "$description" != "$mapping" ]] && echo "      $description"
            done
            ;;
        "list-available-pci")
            vmid="${2:-}"
            if [[ -z "$vmid" ]]; then
                echo "Usage: $0 list-available-pci VMID"
                exit 1
            fi
            echo "Available PCI mappings for VM $vmid on this node:"
            get_available_pci_mappings_for_vm "$vmid" | while IFS='|' read -r mapping id description path; do
                echo "  $mapping: $id @ $path"
                [[ -n "$description" && "$description" != "$mapping" ]] && echo "      $description"
            done
            ;;
        "add-pci-mappings")
            vmid="${2:-}"
            config_file="${3:-}"
            if [[ -z "$vmid" ]] || [[ -z "$config_file" ]]; then
                echo "Usage: $0 add-pci-mappings VMID CONFIG_FILE"
                exit 1
            fi
            add_available_pci_mappings_to_config "$vmid" "$config_file"
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
