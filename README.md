<p align="center">
  <img src="Resources/AppIcon/AppIcon-1024.png" width="160" alt="HanaLima icon: a plumeria with five petals">
</p>

# HanaLima

A native macOS app for creating and running [Lima](https://lima-vm.io/) virtual machines entirely from a GUI: pick CPUs, memory, disk and network interfaces, then start, stop and use your VMs, and build virtual NAT, host-only and bridged networks without root.

**Website: [izawa.github.io/HanaLima](https://izawa.github.io/HanaLima/)** · [日本語版 README](README.ja.md)

*Hana lima* is Hawaiian for "handmade" — *hana*, to make; *lima*, hand (and five). The icon is a plumeria, Hawaii's five-petaled flower, whose petals are VMs you build by hand around one network.

> [!IMPORTANT]
> **HanaLima is an unofficial, independent project.** It is not affiliated with, endorsed by, or supported by the Lima project or the Cloud Native Computing Foundation (CNCF). "Lima" is used only to describe what this app works with. Please report HanaLima problems here, not to the Lima project.

> [!WARNING]
> HanaLima is in early development. There are no signed or notarized releases yet; build it from source.

## Features

- **VM list and lifecycle**: create from Lima's templates — grouped by distribution with readable names such as “Ubuntu 24.04 LTS” — then start, stop, restart and delete, with live status from `limactl watch` and image download progress (percent, speed and time left).
- **Console**: a terminal (`limactl shell`) inside the app that waits until the VM is actually ready.
- **Settings editor**: CPUs, memory, disk size, NICs, shared folders and port forwards through a form, or the full `lima.yaml` with Lima's validation. Only the fields you change are written back. While a VM runs, its settings stay viewable (read-only), provisioning scripts included.
- **Keep the Mac's files out of reach**: Lima shares your home folder with every VM (read-only) by default, so a VM can read credentials such as `~/.ssh`. When creating a VM you can turn that off (`--mount-none`) — useful when the VM runs something you don't fully trust, such as an AI coding agent — and share just one work folder instead, writable or read-only, at the same path inside the VM. This hides files, not the network: through Lima's built-in user-mode network the VM can still reach the internet, your LAN and services listening on the Mac's `127.0.0.1` ([docs/06](docs/06-isolation-investigation.md), in Japanese).
- **Additional disks**: create, resize, delete and attach (`limactl disk`).
- **Disks on an external drive**: move a VM's disk (its largest file) to another drive to save space on your Mac, or choose that place when creating the VM. HanaLima checks the destination first (another volume, APFS, enough free space), keeps the disk sparse, refuses to start while the drive is away, and deletes the moved disk along with the VM. Move it back anytime.
- **Storage usage**: where Lima keeps VMs, disks and downloaded images, the space each actually uses, which VM uses each downloaded image, cleanup of the images no VM uses (or the whole cache with `limactl prune`), each VM's snapshots, and the snapshots and moved disks left behind by VMs deleted with `limactl` directly, ready to delete.
- **Virtual networks without root**: NAT and host-only networks with your own subnet and DHCP reservations (fixed IPs), and **bridged** networks to a host interface (e.g. `en0`), served by a small helper (`hanalima-netd`) on macOS 26 vmnet. No `sudo` and no socket_vmnet needed. After you change or delete a network, VMs using it are told what to do: a running VM shows a Restart button, and a NIC left pointing at a deleted network is offered for removal before the next start.
- **Lima's classic networks**: VMs that use `lima:shared`, `lima:host` or `lima:bridged` (socket_vmnet, installed by following Lima's instructions) keep working and can be edited as usual. HanaLima itself doesn't install socket_vmnet; its own networks need no root.
- **Menu bar item**: every VM with its state, start/stop, and quick access to the console. HanaLima keeps running in the menu bar when the window is closed.
- **Start at login**: per-VM switch using `limactl autostart`.
- **Snapshots**: save the state of a stopped VM and return to it at any time. VZ VMs, which Lima 2.2 can't snapshot, use HanaLima's own snapshots: APFS clones of the disk, instant and taking space only as the disk changes. QEMU VMs use Lima's. A snapshot can also become a new VM.
- **Copies**: copy a stopped VM in a moment (`limactl clone`, APFS clones). The copy gets a new name, host name, MAC addresses and SSH keys; a disk on an external drive is cloned on that drive. Each VM shows where it came from, its copies and a note.
- **Screen thumbnails** (VZ VMs with a display): a live view of the VM's screen on the overview.
- **Logs**: the host agent log and serial consoles, followed live, with search.
- **Provisioning**: edit the scripts and data files Lima applies on every boot.
- **English and Japanese UI**: follows your macOS language.

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

   Or install it into `/Applications` (quits a running HanaLima first) and launch it from there:

   ```bash
   scripts/make-app.sh --install --open
   ```

5. Click **＋ New VM** at the bottom of the sidebar, pick a template (for example `default` or `alpine`), and create it. The first start downloads the OS image.

To use a fixed IP or a bridged network, open **Networks** in the sidebar, create a network with **＋**, then choose **Add NIC** in the Network section of the VM's **Settings** tab.

### Language

HanaLima shows its UI in Japanese when Japanese is your preferred language, and in English otherwise. To use a different language for HanaLima only, choose it under System Settings → General → Language & Region → Applications, or launch it once with:

```bash
open build/HanaLima.app --args -AppleLanguages '(en)'
```

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

Lima's own files (`~/.lima`, the image cache in `~/Library/Caches/lima`, and `~/Library/LaunchAgents/io.lima-vm.autostart.<name>.plist` for start at login) are managed by `limactl`. **Storage → Usage** in the sidebar shows them.

## Known issues

- macOS 27.0.1's vmnet has bugs that HanaLima works around. In particular, reusing a vmnet network after its interface stopped can take over a bridged interface's `bridge100` and remove the Mac's own IPv4 address (reported to Apple as FB25122122). HanaLima never reuses networks, but other virtualization tools running at the same time might. If your Mac loses its IPv4 address, renew DHCP in System Settings (or run `sudo ipconfig set en0 DHCP`) or restart. Details: [docs/02-networking-investigation.md](docs/02-networking-investigation.md).
- Lima 2.2 limits two features: Lima's snapshots work only for QEMU VMs (HanaLima operates on them while the VM is stopped, because live snapshots fail silently with 9p shares; VZ VMs get HanaLima's own), and screenshots only for VZ VMs with a display whose window is open.
- Bridging to Wi-Fi works on our network (tested with a VM getting a LAN address over `en1`), but some access points refuse frames from more than one MAC address per client; if a VM on a Wi-Fi bridge gets no address, try a wired interface.

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

### Localization

The UI is available in English and Japanese. Source strings are Japanese; the English translations live in the String Catalog `Resources/Localizable.xcstrings` (Xcode can open it). Since the app is built with SwiftPM, strings are extracted by the Swift compiler through a script:

```bash
scripts/update-strings.sh    # extract strings from Sources/ and merge them into the catalog
scripts/check-strings.py     # list Japanese literals that won't be translated
```

Text passed to SwiftUI as a literal (`Text("…")`, `Button("…")`) is localized automatically. Strings built in code need `String(localized: "…")`. `LabeledContent(_:value:)` takes a plain String; use `LabeledContent("…") { Text("…") }` instead.

Design decisions and their reasons are in [docs/04-design.md](docs/04-design.md).

## Contributing

Issues and pull requests are welcome, in English or Japanese. For larger changes, please open an issue first to discuss the approach.

## License

HanaLima is released under the [MIT License](LICENSE).

It uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) (MIT) and [Yams](https://github.com/jpsim/Yams) (MIT). Lima (Apache License 2.0) is not included; HanaLima runs the `limactl` installed on your Mac.

## Author

Yukimitsu IZAWA — [izawa@izawa.org](mailto:izawa@izawa.org)
