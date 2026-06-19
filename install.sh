#!/bin/bash
# install.sh - Install the USB hotplug daemon on a Proxmox VE host

set -e

echo "Installing USB Mapping Hotplug System for Proxmox VE"
echo "===================================================="

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

if ! command -v qm &> /dev/null; then
    echo "qm command not found. This installer must be run on a Proxmox VE host."
    exit 1
fi

required_files=("usb-mapping-daemon.sh" "usb-mapping-helper.sh" "usb-hotplug.service")
for file in "${required_files[@]}"; do
    if [[ ! -f "$file" ]]; then
        echo "Required file not found: $file"
        exit 1
    fi
done

echo "Installing scripts to /usr/local/bin/..."
install -m 0755 usb-mapping-daemon.sh /usr/local/bin/usb-mapping-daemon.sh
install -m 0755 usb-mapping-helper.sh /usr/local/bin/usb-mapping-helper.sh

echo "Installing systemd service..."
install -m 0644 usb-hotplug.service /etc/systemd/system/usb-hotplug.service
systemctl daemon-reload

echo "Setting up config directory..."
mkdir -p /etc/usb-hotplug
if [[ ! -f /etc/usb-hotplug/config ]]; then
    install -m 0644 config/config.example /etc/usb-hotplug/config
    echo "  Wrote default /etc/usb-hotplug/config — edit to set GPU_MAPPING"
fi

touch /etc/usb-hotplug-protected-vms.conf

if [[ ! -f /etc/pve/mapping/usb.cfg ]]; then
    echo ""
    echo "No USB device mappings found in Proxmox."
    echo "Create mappings in the web UI: Datacenter -> Resource Mappings -> USB -> Add"
    echo "Use naming convention: vm{ID}-device (e.g. vm110-keyboard) or shared-device"
fi

systemctl enable usb-hotplug.service
systemctl start usb-hotplug.service

sleep 2
if systemctl is-active --quiet usb-hotplug.service; then
    echo ""
    echo "Installation complete. Service is running."
else
    echo ""
    echo "Service failed to start. Checking status..."
    systemctl status usb-hotplug.service --no-pager
    exit 1
fi

# --- event-relay (host->guest signal translation layer) ---------------------
# Generic on every host; idle until you define slots in event-relays.conf.
echo ""
echo "Installing event-relay (host->guest signal translation layer)..."
if [[ -f event-relay-daemon.sh && -f event-relay.service ]]; then
    install -m 0755 event-relay-daemon.sh /usr/local/bin/event-relay-daemon.sh
    install -m 0644 event-relay.service /etc/systemd/system/event-relay.service
    if [[ ! -f /etc/usb-hotplug/event-relays.conf ]]; then
        install -m 0644 event-relays.conf.example /etc/usb-hotplug/event-relays.conf
        echo "  Wrote default /etc/usb-hotplug/event-relays.conf (no active slots)"
    fi
    systemctl daemon-reload
    systemctl enable event-relay.service >/dev/null 2>&1
    systemctl restart event-relay.service
    if systemctl is-active --quiet event-relay.service; then
        echo "  event-relay active (idle until slots are defined; guest handlers go in guest-handlers/)"
    else
        echo "  WARNING: event-relay failed — check: systemctl status event-relay.service"
    fi
else
    echo "  (event-relay files not in this checkout — skipping)"
fi

cat <<'EOF'

Next steps:
  1. Set GPU_MAPPING in /etc/usb-hotplug/config if you use shared-* devices
  2. Create USB mappings in the Proxmox GUI (see README.md)
  3. Test: usb-mapping-daemon.sh --test
  4. Tail logs: journalctl -u usb-hotplug.service -f

Management:
  systemctl status usb-hotplug.service
  systemctl restart usb-hotplug.service
  usb-mapping-daemon.sh --status
  usb-mapping-helper.sh list-mappings
  usb-mapping-helper.sh protect VMID
EOF
