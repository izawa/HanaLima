# HanaLima

A native macOS app for creating and running [Lima](https://lima-vm.io/) virtual machines entirely from a GUI: pick CPUs, memory, disk and network interfaces, then start, stop and use your VMs, and build virtual NAT, host-only and bridged networks without root.

**Website: [izawa.github.io/HanaLima](https://izawa.github.io/HanaLima/)** · [日本語版 README](README.ja.md)

> [!IMPORTANT]
> **HanaLima is an unofficial, independent project.** It is not affiliated with, endorsed by, or supported by the Lima project or the Cloud Native Computing Foundation (CNCF). "Lima" is used only to describe what this app works with. Please report HanaLima problems here, not to the Lima project.

> [!WARNING]
> HanaLima is in early development. There are no signed or notarized releases yet; build it from source. The UI is currently in Japanese.

## Features

- **VM list and lifecycle**: create from Lima templates, start, stop, restart and delete, with live status from `limactl watch` and image download progress.
- **Console**: a terminal (`limactl shell`) inside the app that waits until the VM is actually ready.
- **Settings editor**: CPUs, memory, disk size, NICs, shared folders and port forwards through a form, or the full `lima.yaml` with Lima's validation. Only the fields you change are written back.
- **Additional disks**: create, resize, delete and attach (`limactl disk`).
- **Virtual networks without root**: NAT and host-only networks with your own subnet and DHCP reservations (fixed IPs), and **bridged** networks to a host interface (e.g. `en0`), served by a small helper (`hanalima-netd`) on macOS 26 vmnet. No `sudo` and no socket_vmnet needed.
- **socket_vmnet setup** (optional, the classic way): installs the official release and the Lima sudoers file with a single administrator prompt.
- **Menu bar item**: every VM with its state, start/stop, and quick access to the console. HanaLima keeps running in the menu bar when the window is closed.
- **Start at login**: per-VM switch using `limactl autostart`.

## Requirements

- macOS 26 or later (developed on macOS 27 with Apple Silicon; Intel Macs are untested)
- [Lima](https://lima-vm.io/) 2.2 or later, from Homebrew
- To build: Xcode 26 or later, including the Metal Toolchain (required by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm))

## Quick Start

1. Install Lima and the additional guest agents:

   ```bash
   brew install lima lima-additional-guestagents
   ```

2. Install the Metal Toolchain for Xcode, if you haven't already:

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

3. Clone and build. The script builds `build/HanaLima.app` and signs it ad hoc for your Mac:

   ```bash
   git clone https://github.com/izawa/HanaLima.git
   cd HanaLima
   scripts/build-app.sh release
   ```

4. Launch it:

   ```bash
   open build/HanaLima.app
   ```

5. Click **＋ 新規仮想マシン** (New VM) at the bottom of the sidebar, pick a template (for example `default` or `alpine`), and create it. The first start downloads the OS image.

To use a fixed IP or a bridged network, open **ネットワーク** (Networks) in the sidebar, create a network with **＋**, then add a NIC for it in the VM's **設定 → ネットワーク** (Settings → Network) tab.

## How it works

HanaLima does not link Lima's Go code. It drives the `limactl` CLI, Lima's public interface, and reads its JSON output (`limactl list --format json`, `limactl watch --json`). Changes to `lima.yaml` go through `limactl edit`, so Lima validates them.

Virtual networks are provided by `hanalima-netd`, a helper bundled in the app. Each network is registered as a per-user LaunchAgent with socket activation. A VM attaches with Lima's `networks: - socket: <path>` (the socket_vmnet protocol), and the helper relays its frames to a vmnet network (NAT/host-only) or a bridged vmnet interface. The helper needs no root, only the `com.apple.security.virtualization` entitlement, which `scripts/build-app.sh` applies. Networks keep working when the app is not running, including for VMs started with plain `limactl start`.

| Path | Purpose |
|---|---|
| `Sources/LimaKit` | `limactl` wrapper (no UI dependencies) |
| `Sources/NetworkKit` | Virtual network definitions, LaunchAgent management, DHCP helpers |
| `Sources/hanalima-netd` | Network helper (Lima socket ⇄ vmnet relay) |
| `Sources/HanaLima` | SwiftUI app |
| `Prototypes/` | Experiments from the networking investigation, including a reproduction of a macOS vmnet bug |
| `docs/` | Design notes and investigation logs (in Japanese) |

Files HanaLima creates:

- `~/Library/Application Support/HanaLima/` — `networks.json`, the installed helper, network sockets
- `~/Library/LaunchAgents/org.izawa.HanaLima.net.<name>.plist` — one per virtual network
- `~/Library/Logs/HanaLima/` — helper logs

Lima's own files (`~/.lima`, and `~/Library/LaunchAgents/io.lima-vm.autostart.<name>.plist` for start at login) are managed by `limactl`.

## Known issues

- macOS 27.0.1's vmnet has bugs that HanaLima works around. In particular, reusing a vmnet network after its interface stopped can take over a bridged interface's `bridge100` and remove the Mac's own IPv4 address (reported to Apple as FB25122122). HanaLima never reuses networks, but other virtualization tools running at the same time might. If your Mac loses its IPv4 address, renew DHCP in System Settings (or run `sudo ipconfig set en0 DHCP`) or restart. Details: [docs/02-networking-investigation.md](docs/02-networking-investigation.md).
- Snapshots, VM screen thumbnails and provisioning script editing are not implemented yet.
- Bridging to Wi-Fi interfaces is untested.

## Uninstalling

Delete the HanaLima networks in the app first (this unregisters their LaunchAgents), then remove the app and its data:

```bash
rm -rf ~/Library/Application\ Support/HanaLima ~/Library/Logs/HanaLima
```

If a network's LaunchAgent is still registered, unload it with `launchctl bootout gui/$(id -u)/org.izawa.HanaLima.net.<name>` and delete its plist from `~/Library/LaunchAgents`. Your Lima VMs in `~/.lima` are not touched.

## Development

```bash
scripts/build-app.sh                                  # debug build of build/HanaLima.app
swift test --skip EndToEnd --skip DaemonTermination   # unit tests (no VMs, a few seconds)
HANALIMA_E2E=1 swift test --filter <Suite>            # end-to-end tests with real VMs
```

End-to-end tests create VMs named `hanalima-e2e-*` and temporary networks, and remove them afterwards. Run `scripts/build-app.sh` first for the network tests (they need the entitlement-signed helper). `BridgeEndToEndTests` puts a host interface into a bridge, so it only runs when you name the interface: `HANALIMA_E2E_BRIDGE=en0`.

If the build fails because `metal` cannot be found after a restart, run `swift package clean` and build again.

Design decisions and their reasons are in [docs/04-design.md](docs/04-design.md).

## Contributing

Issues and pull requests are welcome, in English or Japanese. For larger changes, please open an issue first to discuss the approach.

## License

HanaLima is released under the [MIT License](LICENSE).

It uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and [Yams](https://github.com/jpsim/Yams) (MIT). Lima (Apache License 2.0) is not included; HanaLima runs the `limactl` installed on your Mac.

## Author

Yukimitsu IZAWA — [izawa@izawa.org](mailto:izawa@izawa.org)
