# proxmox-usb-hotplug

A small systemd daemon for Proxmox VE that hot-attaches and hot-detaches USB devices to running VMs based on Proxmox's native USB resource mappings. Devices appear in the guest seconds after you plug them in, and disappear when you unplug them — no reboot, no GUI clicks, no per-device udev rules.

## Why

Proxmox can pass USB devices through to a VM, but you have to either bind the device in the VM config before boot or add it manually through the GUI. There's no built-in hot-attach for devices plugged in *after* the VM is running. This daemon closes that gap by watching `lsusb` against the mappings in `/etc/pve/mapping/usb.cfg` and calling `qm set` / `qm set -delete` as devices appear and disappear.

## How it works

1. You define USB mappings in the Proxmox GUI the normal way: **Datacenter → Resource Mappings → USB → Add**.
2. You follow a naming convention so the daemon knows where each device should go:
   - `vm{ID}-name` — always goes to VM `{ID}` when it's running (e.g. `vm110-keyboard` → VM 110).
   - `shared-name` — follows the VM that currently has the configured GPU mapping (useful for keyboard/mouse/headset that should follow your gaming/desktop VM wherever it's booted).
   - `disabled-name` — never auto-assigned (handy for staging).
   - Mappings that don't match these prefixes are ignored.
3. `usb-mapping-daemon.sh` polls every `INTERVAL` seconds. When a mapped device shows up in `lsusb`, the daemon finds the first free `usbN:` slot on the target VM and runs `qm set VMID -usbN mapping=NAME,usb3=1`. When the device is unplugged, it runs `qm set VMID -delete usbN`.

An `flock`-guarded critical section prevents two simultaneous plug events from racing into the same `usbN` slot.

## PCI passthrough exclusivity

As of v0.2.0, the daemon also enforces exclusive ownership of **PCI resource mappings** (GPUs, NICs, capture cards — anything using `hostpci` passthrough). When a running VM has a `hostpci` mapping in its live config, the daemon strips that mapping from every *other* VM's live config so two VMs can never be simultaneously configured to claim the same device.

Key properties:

- Only touches live `/etc/pve/qemu-server/*.conf` files. **Profile configs are never modified**, so OS-specific `hostpci` flags (`x-vga`, `romfile`, `pcie`, `rombar`, etc.) declared in a Linux VM's profile and a Windows VM's profile remain intact — each VM reloads its own flavor when `start.sh` is next used.
- Runs on daemon start and whenever the set of running VMs changes.
- Doesn't try to hot-swap PCI passthrough between running VMs (not supported by qemu/vfio — hostpci is a boot-time binding).
- If no VM is running with a given mapping, other VMs' configs are left alone — first VM to start next wins.

Disable by setting `ENFORCE_PCI_EXCLUSIVITY=0` in `/etc/usb-hotplug/config`.

## Requirements

- Proxmox VE 8.x or newer (uses the built-in `/etc/pve/mapping/usb.cfg` — introduced with resource mappings).
- Root on the Proxmox host.
- Bash, `flock`, `lsusb` (all standard).

## Install

```bash
git clone https://github.com/codemonkeying/proxmox-usb-hotplug.git
cd proxmox-usb-hotplug
sudo ./install.sh
```

The installer copies the two scripts to `/usr/local/bin/`, installs the systemd unit, creates `/etc/usb-hotplug/config`, and starts the service.

If you want `shared-*` devices to follow a VM around, you need an **anchor PCI mapping**. This is nothing more than any existing Proxmox PCI resource mapping that you designate as the reference — the daemon will route `shared-*` USB devices to whichever running VM currently has that PCI mapping attached.

It's typically a GPU (hence the variable name), but it's just a string match — a sound card, capture card, or any other PCI mapping works the same way.

1. Create the mapping once in **Datacenter → Resource Mappings → PCI → Add**. Pick a name you'll remember — `host1_gpu`, `rtx4090`, `gpu1`, whatever. The name is *yours to choose*; it isn't derived from the hardware.
2. Put that same string in `GPU_MAPPING` in `/etc/usb-hotplug/config`:

   ```bash
   GPU_MAPPING="host1_gpu"    # must match exactly what you named it in the GUI
   ```
3. Restart: `systemctl restart usb-hotplug.service`.

Leave `GPU_MAPPING=""` (the default) if you don't need `shared-*` routing — `vm{ID}-*` mappings will still work.

## Usage

```bash
# Show everything the daemon knows about right now
usb-mapping-daemon.sh --test

# Current assignments
usb-mapping-daemon.sh --status

# Tail the log
journalctl -u usb-hotplug.service -f

# Exclude a VM from all hotplug management (e.g. a router VM)
usb-mapping-helper.sh protect 100
usb-mapping-helper.sh list-protected
```

Example naming scheme for a two-VM home lab where VM 110 is a Linux desktop with the GPU and VM 111 is a Windows VM without one:

| Mapping name | Target |
|---|---|
| `vm110-dock-audio` | only VM 110 |
| `vm111-game-controller` | only VM 111 |
| `shared-keyboard` | whichever of the two currently has the GPU |
| `shared-mouse` | same |
| `disabled-usb-drive` | never attached (opt-in later by renaming) |

## Protected VMs

Some VMs should never be touched by this daemon — a router VM that hard-binds a specific NIC, for example. Add its ID to `/etc/usb-hotplug-protected-vms.conf` (one VMID per line) or use `usb-mapping-helper.sh protect VMID`.

## Files installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/usb-mapping-daemon.sh` | the polling daemon |
| `/usr/local/bin/usb-mapping-helper.sh` | mapping lib + CLI (`list-mappings`, `protect`, etc.) |
| `/etc/systemd/system/usb-hotplug.service` | systemd unit |
| `/etc/usb-hotplug/config` | daemon config (GPU_MAPPING, INTERVAL) |
| `/etc/usb-hotplug-protected-vms.conf` | one VMID per line; excluded from management |
| `/var/log/usb-hotplug.log` | daemon log (also goes to journald) |
| `/var/run/usb-hotplug.state` | currently-assigned mappings |
| `/var/run/usb-hotplug.lock` | flock file for critical sections |
| `/var/run/usb-hotplug-auto-vm.state` | optional integration hook (see below) |

## Uninstall

```bash
sudo systemctl disable --now usb-hotplug.service
sudo rm /etc/systemd/system/usb-hotplug.service
sudo rm /usr/local/bin/usb-mapping-daemon.sh /usr/local/bin/usb-mapping-helper.sh
sudo rm -rf /etc/usb-hotplug /etc/usb-hotplug-protected-vms.conf
sudo systemctl daemon-reload
```

## Integration hook

`/var/run/usb-hotplug-auto-vm.state` can be written by another process (e.g. a VM-start script) to record a VMID that should be actively managed. The daemon reads this file via `vm_in_auto_mode()` when deciding whether to attach certain devices. Leave the file absent if you only want mapping-based routing.

## License

MIT — see [LICENSE](LICENSE).
