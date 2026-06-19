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

## Multi-node cluster behaviour

In a Proxmox cluster, `/etc/pve/mapping/usb.cfg` is shared across every node and each mapping carries a `node=` field declaring which host the physical device is attached to. The daemon respects this:

- A mapping with `node=otherhost` is **skipped** entirely on the local host — no add attempt, no log spam.
- The lsusb presence check alone is not authoritative because multiple distinct mappings can share a vendor:product ID (e.g. several Logitech receivers / mice / keyboards all report `046d:c52b`). Without the node filter, a mapping pinned to a remote node would appear "satisfied locally" because some other Logitech device with the same VID:PID is plugged into this host.
- On the GPU VM, `cleanup_stale_shared_mappings` also strips foreign-node `shared-*` entries that may have been left in the live config from a previous session — so when a remote host hosting a shared device goes offline, its `shared-*` mappings stop polluting the GPU VM's `usbN:` slots.

A mapping with no `node=` field at all is treated as "any host" (unusual, but safe).

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

## USB pools (multiple identical devices)

Standard mappings break down when you have **two or more physically identical** USB devices — same VID:PID, no unique iSerial. The classic example is a pair of identical game-controller wireless dongles (SteelSeries Stratus Duo, Xbox 360 wireless, etc.), but the same problem applies to multiple identical USB WiFi adapters, audio interfaces, security keys, or webcams. PVE's USB passthrough only distinguishes such devices by physical USB path — but pinning a `path=` in the mapping locks you to one specific port on one specific dock, which defeats the point of plug-anywhere.

**A pool** fixes this by dynamically assigning whichever matching devices are currently plugged in to a fixed range of consecutive `usbN:` slots on a target VM, sorted by USB path (lowest path → first slot). Plug into any port on any dock — the pool picks it up.

Define pools in `/etc/usb-hotplug/pools.conf` (one per non-comment line, whitespace-separated):

```
# <pool_name>  <vid:pid>  <target_vmid>  <first_slot>  <max_slots>  [usb3]
steelseries  1038:1430  110  4  2  usb3
alfa-router  148f:3070  200  6  1
```

- `pool_name` — free-form, logs only
- `vid:pid` — the USB VID:PID of the device class
- `target_vmid` — the VM the devices should attach to (must be on this node; cross-node entries are silently skipped). May also be the literal `shared` (or `gpu`) → resolves to the current GPU VM (the same VM that receives `shared-*` mappings), so the pool follows whichever GPU VM is running instead of being pinned to a fixed id. Useful for devices shared between mutually-exclusive desktop VMs (e.g. a Linux VM and a Windows VM that take turns on the same GPU + peripherals).
- `first_slot` — lowest `usbN` index the pool owns (e.g. `4` → starts at `usb4`)
- `max_slots` — maximum number of devices to attach concurrently; extras beyond this are ignored
- `usb3` — optional 6th field; pass `usb3` or `1` to force `usb3=1` on attach

A copy of the example file ships as `pools.conf.example` — copy it to `/etc/usb-hotplug/pools.conf` and edit. Pools fire every poll alongside the standard mapping logic.

**Safety**: pool-owned slots are recognised by their `host=<bus-port>` value (the format the pool itself writes). Slots in the pool range that contain a different format (`mapping=...`, `host=<vid:pid>`, etc.) are **left alone** — the pool never clobbers manually-configured slots. Pick a `first_slot` that doesn't overlap with any of your `vmN-` / `shared-` mappings to avoid contention.

**Slot identity caveat**: pool members are interchangeable to PVE. Slot `first_slot` always holds whichever pool device has the lowest current USB path. If you unplug one device and plug it into a different port, the pool may re-assign slots on the next poll. For most use cases (controllers, wifi adapters) this is fine; for cases where the OS inside the VM needs a stable per-device identity (e.g. a USB audio device with persistent ALSA bindings), use traditional `path=`-locked mappings instead.

## Protected VMs

Some VMs should never be touched by this daemon — a router VM that hard-binds a specific NIC, for example. Add its ID to `/etc/usb-hotplug-protected-vms.conf` (one VMID per line) or use `usb-mapping-helper.sh protect VMID`.

## Files installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/usb-mapping-daemon.sh` | the polling daemon |
| `/usr/local/bin/usb-mapping-helper.sh` | mapping lib + CLI (`list-mappings`, `protect`, etc.) |
| `/etc/systemd/system/usb-hotplug.service` | systemd unit |
| `/etc/usb-hotplug/config` | daemon config (GPU_MAPPING, INTERVAL) |
| `/etc/usb-hotplug/pools.conf` | optional USB pool definitions (see "USB pools") |
| `/etc/usb-hotplug-protected-vms.conf` | one VMID per line; excluded from management |
| `/var/log/usb-hotplug.log` | daemon log (also goes to journald) |
| `/var/run/usb-hotplug.state` | currently-assigned mappings |
| `/var/run/usb-hotplug.lock` | flock file for critical sections |
| `/var/run/usb-hotplug-auto-vm.state` | optional integration hook (see below) |

## event-relay (host → guest signal translation layer)

Some host-side signals can't be passed through to a VM at all: the laptop **lid switch** is an ACPI `EV_SW` event (QEMU's `input-linux` only forwards keys/pointer), and ACPI/sysfs state isn't a USB or PCI device. `event-relay` bridges that gap — it watches declared host signals and relays state changes into the target VM via the guest agent, so the guest can react (e.g. a lid-close makes the active desktop VM drop its built-in panel from the layout).

It's a separate service from the USB daemon (so a fault in one can't disturb the other) but reuses the same `shared`/`gpu` target idea: a slot can target a fixed `vmid`, or `shared`/`gpu` to follow whichever VM currently holds the GPU mapping.

**Slots** live in `/etc/usb-hotplug/event-relays.conf` (one per non-comment line):

```
# <name>  <source>  <target>  <handler>
lid  acpi-lid  shared  lid
```

- `source` — `acpi-lid` (`/proc/acpi/button/lid/LID/state`) or `sysfs:<path>:<open-value>`
- `target` — `<vmid>` | `shared` | `gpu` (shared/gpu resolve to the current GPU VM)
- `handler` — token passed to the guest dispatcher

On a state **change** (never on startup) the daemon runs, fire-and-forget so a slow guest command can never wedge the agent:

```
qm guest exec <vmid> --synchronous 0 -- /usr/local/bin/vm-event-handler <handler> <state>
```

**The framework is host-agnostic and ships idle** — no active slots by default. Each host enables only the slots that make sense for it (the lid slot is laptop-only). The **guest** must have `/usr/local/bin/vm-event-handler`; reference handlers are in [`guest-handlers/`](guest-handlers/). The Linux handler auto-detects the built-in panel at runtime (NVIDIA `ConnectorType: Panel`, or `eDP*` on Wayland) and toggles it — never pinned to a connector name, so it adapts as external displays change, and does nothing if no built-in panel is connected.

Handles the **relay class** only (switch/ACPI/sysfs state). Keypress devices (e.g. ThinkPad Fn keys, which *are* `EV_KEY`) belong in the VM's `input-linux` args at start, not here.

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
