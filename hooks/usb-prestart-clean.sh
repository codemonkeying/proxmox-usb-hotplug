#!/bin/bash
# usb-prestart-clean.sh — PVE hookscript
#
# pre-start phase: scrub any "usbN: mapping=vm{vmid}-*" line whose underlying
# VID:PID is not present in lsusb on this host. Prevents PVE from refusing to
# start the VM when a USB device referenced in config is absent (e.g. unplugged
# between backups). VM start always wins; the daemon will re-attach the device
# later via hot-add when/if it returns.
#
# Defensive — never fails the VM start. Set this on a VM with:
#   qm set <vmid> --hookscript bu2tb:snippets/usb-prestart-clean.sh

set +e

VMID="$1"
PHASE="$2"

LOG_TAG="usb-prestart-clean[${VMID}]"
log() { logger -t "$LOG_TAG" -- "$*"; echo "$LOG_TAG: $*" >&2; }

# Only act on pre-start. Silently ok on every other phase.
[ "$PHASE" = "pre-start" ] || exit 0

CONFIG="/etc/pve/qemu-server/${VMID}.conf"
MAPPING_FILE="/etc/pve/mapping/usb.cfg"

[ -r "$CONFIG" ]       || { log "no config $CONFIG, nothing to do"; exit 0; }
[ -r "$MAPPING_FILE" ] || { log "no mapping file $MAPPING_FILE, nothing to do"; exit 0; }

# Build a map of mapping-name -> "VID:PID" by parsing usb.cfg.
declare -A mapping_id
declare current_mapping=""
while IFS= read -r line; do
    if [[ "$line" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        current_mapping="$line"
    elif [[ "$line" =~ ^[[:space:]]+map[[:space:]] ]]; then
        if [[ -n "$current_mapping" && "$line" =~ id=([^,[:space:]]+) ]]; then
            mapping_id["$current_mapping"]="${BASH_REMATCH[1]}"
        fi
    fi
done < "$MAPPING_FILE"

# Snapshot current USB devices on this host.
current_ids=$(lsusb 2>/dev/null | awk '{print $6}')

# Walk every usbN: mapping=... line in this VM's config. Any mapping
# (vm{N}-*, shared-*, or other) gets the same treatment: if the underlying
# VID:PID is not currently in lsusb, strip the line so PVE doesn't refuse
# to start the VM. The daemon will hot-add the mapping back when/if the
# device returns.
removed=0
while IFS= read -r line; do
    slot=$(echo "$line"    | sed -n 's/^usb\([0-9]\+\):.*/\1/p')
    mapping=$(echo "$line" | sed -n 's/.*mapping=\([A-Za-z0-9_-]\+\).*/\1/p')

    [ -z "$slot" ]    && continue
    [ -z "$mapping" ] && continue

    id="${mapping_id[$mapping]}"
    if [ -z "$id" ]; then
        log "mapping $mapping has no id= in $MAPPING_FILE; skipping (won't strip — operator may be migrating mappings)"
        continue
    fi

    if echo "$current_ids" | grep -q "^${id}$"; then
        # Device present — leave it; PVE will attach at start.
        continue
    fi

    log "device ${id} for ${mapping} not present; stripping usb${slot} so VM can start"
    qm set "$VMID" --delete "usb${slot}" >/dev/null 2>&1 \
        && removed=$((removed + 1)) \
        || log "qm set --delete usb${slot} failed (continuing — VM start will fail loudly if this matters)"
done < <(grep -E "^usb[0-9]+:.*mapping=" "$CONFIG")

if [ "$removed" -gt 0 ]; then
    log "stripped $removed missing-device usbN line(s) before start"
fi

# Always succeed — never block a VM start. If we couldn't clean up,
# the VM start will fail with PVE's normal error and the operator sees it.
exit 0
