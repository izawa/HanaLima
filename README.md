<p align="center">
  <img src="Resources/AppIcon/AppIcon-1024.png" width="160" alt="HanaLima icon: a plumeria with five petals">
</p>

# HanaLima

A native macOS app for creating and running [Lima](https://lima-vm.io/) virtual machines entirely from a GUI: pick CPUs, memory, disk and network interfaces, then start, stop and use your VMs, and build virtual NAT, host-only and bridged networks without root. HanaLima's own Virtualization.framework driver adds isolated VMs, pause and hibernate, and a serial console, and you can sort VMs into groups and start or stop a whole group at once.

**Website: [izawa.github.io/HanaLima](https://izawa.github.io/HanaLima/)** · [日本語版 README](README.ja.md)

*Hana lima* is Hawaiian for "handmade" — *hana*, to make; *lima*, hand (and five). The icon is a plumeria, Hawaii's five-petaled flower, whose petals are VMs you build by hand around one network.

> [!IMPORTANT]
> **HanaLima is an unofficial, independent project.** It is not affiliated with, endorsed by, or supported by the Lima project or the Cloud Native Computing Foundation (CNCF). "Lima" is used only to describe what this app works with. Please report HanaLima problems here, not to the Lima project.

> [!WARNING]
> HanaLima is in early development. Builds signed with Developer ID and notarized by Apple are on the [Releases](https://github.com/izawa/HanaLima/releases/latest) page; you can also build it from source.

## Features

- **VM list and lifecycle**: create from Lima's templates — grouped by distribution with readable names such as “Ubuntu 24.04 LTS” — then start, stop, restart and delete, with live status from `limactl watch` and image download progress (percent, speed and time left).
- **Groups**: gather VMs into groups in the sidebar and fold them like folders. Make a group from the ＋ menu or a right-click (New Group), with Move to Group on a VM, or by dropping one ungrouped VM onto another. Drag to reorder: an insertion line shows where a VM will go, wherever it is dropped. **Start All, Stop All and Hibernate All** act on a whole group: one sheet shows the VMs and their order first, along with the ones left out and why, then they run one at a time. Starting follows the group's order and stopping and hibernating go in reverse, so a gateway VM placed first starts first and stops last. Only VMs on HanaLima's driver (below) can hibernate; the others are skipped. Lima has no notion of groups, so HanaLima keeps them in each VM's record: a VM renamed with `limactl rename` stays in its group, and a `limactl clone` copy lands right after its source ([docs/12](docs/12-vm-groups-design.md), in Japanese).
- **Console**: a terminal (`limactl shell`) inside the app that waits until the VM is actually ready.
- **Settings editor**: CPUs, memory, disk size, NICs, shared folders and port forwards through a form, or the full `lima.yaml` with Lima's validation. Only the fields you change are written back. While a VM runs, its settings stay viewable (read-only), provisioning scripts included. Ready-made provisioning examples can be added in one click: basic tools, your dotfiles and public key, Docker Engine, an XDP development toolchain, Japanese locale and time zone, no automatic updates, a swap file, development languages (Go, Node.js, uv, rustup), a one-shot full upgrade, console auto-login, and a gateway with an allow list (for the VM a guest-only network names as its router: NAT and DNS for the VMs behind it, letting through only the listed hosts) (tested on Ubuntu, Fedora and, where it applies, Alpine; the first four on Debian too; the gateway on Ubuntu and Alpine only).
- **Keep the Mac's files out of reach**: Lima shares your home folder with every VM (read-only) by default, so a VM can read credentials such as `~/.ssh`. When creating a VM you can turn that off (`--mount-none`) — useful when the VM runs something you don't fully trust, such as an AI coding agent — and share just one work folder instead, writable or read-only, at the same path inside the VM. This hides files, not the network: through Lima's built-in user-mode network the VM can still reach the internet, your LAN and services listening on the Mac's `127.0.0.1` ([docs/06](docs/06-isolation-investigation.md), in Japanese). To cut the network off too, use the isolation profile of HanaLima's own driver (below).
- **Additional disks**: create, resize, delete and attach (`limactl disk`).
- **Disks on an external drive**: move a VM's disk (its largest file) to another drive to save space on your Mac, or choose that place when creating the VM. HanaLima checks the destination first (another volume, APFS, enough free space), keeps the disk sparse, refuses to start while the drive is away, and deletes the moved disk along with the VM. Move it back anytime.
- **Storage usage**: where Lima keeps VMs, disks and downloaded images, the space each actually uses, which VM uses each downloaded image, cleanup of the images no VM uses (or the whole cache with `limactl prune`), each VM's snapshots, and the snapshots and moved disks left behind by VMs deleted with `limactl` directly, ready to delete.
- **Virtual networks without root**: NAT and host-only networks with your own subnet and DHCP reservations (fixed IPs), **bridged** networks to a host interface (e.g. `en0`), and **guest-only** networks: VMs only, with the Mac not on the segment at all (the helper switches frames between the VMs itself, with no vmnet, and its own DHCP names the helper as the DNS server, with the search domain `hanalima`, and hands out a default route only when the network names a “router”, a VM on that network, which then also comes second in the DNS list, for putting isolated VMs behind one VM that reaches the outside; the helper answers only for the VMs on that network (`lima-<name>`, bare or with `.hanalima`) and refuses everything else, so a VM that also has NIC 0 keeps resolving the internet through Lima's user-mode network. Ubuntu, with systemd-resolved, resolves per link; Alpine with NIC 0 keeps cloud-init's resolv.conf, which lists only the user-mode DNS, so query the helper directly there, while an isolated Alpine VM uses the helper as its resolver. For the isolated VMs below, this is how they talk to each other). All served by a small helper (`hanalima-netd`), the first three on macOS 26 vmnet. No `sudo` and no socket_vmnet needed. After you change or delete a network, VMs using it are told what to do: a running VM shows a Restart button, and a NIC left pointing at a deleted network is offered for removal before the next start. VMs whose helper is still an older build get the same restart mark when a network is saved or deleted.
- **Lima's classic networks**: VMs that use `lima:shared`, `lima:host` or `lima:bridged` (socket_vmnet, installed by following Lima's instructions) keep working and can be edited as usual. HanaLima itself doesn't install socket_vmnet; its own networks need no root.
- **Menu bar item**: every VM with its state, start/stop, and quick access to the console. Groups become submenus with their group-wide actions. HanaLima keeps running in the menu bar when the window is closed.
- **Start at login**: per-VM switch using `limactl autostart`.
- **Snapshots**: save the state of a stopped VM and return to it at any time. VZ VMs, which Lima can't snapshot (still the case in 2.3), use HanaLima's own snapshots: APFS clones of the disk, instant and taking space only as the disk changes. QEMU VMs use Lima's. On a VM running on HanaLima's driver, `limactl snapshot` (create, apply, delete, list) works on the same snapshots too, while the VM is stopped and with one-word tags. A snapshot can also become a new VM.
- **Create from an installer ISO**: Lima only boots cloud images, but HanaLima can start from a Linux installer ISO (arm64): it creates the VM with a blank disk, has HanaLima's driver (below) run the installer in its own window right into that disk (the installer is a separate process, so it carries on if you quit the app, which reconnects when reopened), and after a one-line fix-up in the installed OS hands the VM to Lima, which configures it like any other (user, SSH key, guest agent, shared folders, provisioning). Tested with Ubuntu Server 26.04; the install must end with cloud-init installed (the fix-up takes care of it on Ubuntu, Debian, Fedora and Alpine). Creates VZ (Lima) VMs; not for QEMU.
- **Rescue boot**: when Lima (SSH) can no longer reach a VM, say after a bad sshd change, HanaLima's driver (below) boots it with a screen and keyboard. Log in on the screen console, repair it, and hand it back with “Start with Lima”. The NIC is Lima's own user-mode network, so the internet and name resolution work (you can reinstall packages). The VM keeps running if you quit the app, which reconnects when reopened. VZ Linux guests only. Lima locks the user’s password, so do this **before SSH breaks**, as insurance:
  1. In the Settings tab, under Provisioning, “Add from Examples…” → “Log In Automatically on the Consoles (Screen and Serial)”, then save.
  2. Start the VM once as usual (provisioning runs at Lima’s boot, which is when the auto-login lands in the guest).
  3. From then on, with the VM stopped, press the first-aid kit (Rescue Boot) in the toolbar and a logged-in shell appears on the screen.
- **HanaLima's own VM driver** (the default for new VMs): besides Lima's `vz` and `qemu`, a VM can run on `hanalima`, a [Lima external driver](docs/09-external-driver-investigation.md) (in Japanese) that HanaLima ships. Only the virtual machine itself runs in the driver's process; images, cloud-init, SSH, port forwarding and `limactl` stay Lima's. `vz` and QEMU remain a choice, and switching an existing VZ VM either way is one step in the Settings tab (the disk and EFI store are shared).
  - **A two-way serial console**: the Console tab gets a “Serial” mode next to the shell, for reading and typing, a second way into a VM whose sshd is broken, besides the rescue boot (steps below).
  - **A screen window that can be closed and reopened** (“Open Screen” on the overview), and thumbnails without `limactl screenshot`. The screen can't take a paste from the Mac's clipboard (a Virtualization.framework limit; use the Console tab).
  - **SSH over vsock**, with no network in between: built into guests with systemd 256 or later (Ubuntu 24.10+, Fedora 41+); on Alpine and older systemd, one boot with NIC 0 on lets HanaLima's boot script install a socat relay.
  - **Isolation profile**: turn off “NIC 0: Lima's user-mode NAT” and the VM loses its route through Lima to the internet, your LAN and the Mac's `127.0.0.1`; it reaches only what the NICs you add lead to (a HanaLima host-only or guest-only network). SSH, the guest agent and port forwarding work over vsock. “Create as an isolated VM” in the create sheet sets all of this with one switch, and “Boot with NIC 0 only the first time” removes NIC 0 at the first stop. Under isolation the driver turns off hostResolver and containerd (in memory only), marks eth0 optional and uses the guest-only network's DNS; the Settings and Overview tabs say so. apt/dnf can't get out, so provisioning is skipped.
  - **Pause and hibernate** ([docs/11](docs/11-pause-resume-investigation.md), in Japanese): stop a running VM and carry on later from where it was. Pause stops only the CPUs and keeps the memory, so it resumes at once. Hibernate saves the memory into the VM's folder and powers off, so the Mac gets the memory back and the driver's process ends; the next start resumes where the VM was, also after a Mac restart and from start at login. Either way the guest doesn't reboot, and Lima's time sync corrects its clock. Resuming from hibernation runs Lima's per-boot work (provisioning included) again. If the VM's settings or disks changed after it hibernated, it refuses to resume rather than pair the old memory with a changed disk, and asks whether to discard the saved state. A copy made with `limactl clone` while hibernated, and a VM renamed with `limactl rename` while hibernated, discard the saved state and boot afresh. The first hibernation on a Mac needs its screen unlocked (the key for the saved state is made then). Lima's `vz` has no way to pause, so `vz` VMs can't do either. Verified end to end on Alpine and Ubuntu LTS.
  - **Works as with Lima**: Rosetta (if the Mac has none, the VM boots without it and the driver's log says what to run; never installed for you), `lima:` networks (socket_vmnet shared/host/bridged, and user-v2 as NIC 0), and `limactl snapshot` (create, apply, delete, list; the same APFS-clone snapshots as the app; stopped VMs only, one-word tags).
  - **From the terminal's `limactl` too**: at every launch HanaLima places the driver where Lima looks for drivers (`/opt/homebrew/lib/lima/` with Homebrew). No `LIMA_DRIVERS_PATH`, no sudo. The driver exits on its own once no VM runs and the Lima process that started it is gone.
  - A Mac without HanaLima can't start these VMs (switch them to VZ first before moving them). Verified end to end on Alpine, Ubuntu LTS, Fedora and Debian.
  - To log in from the serial console:
    1. Add the “Log In Automatically on the Consoles (Screen and Serial)” example in the Settings tab, as for the rescue boot, and start the VM once — the images put no login on the serial port (`hvc0`), so without it the serial stays silent.
    2. Choose HanaLima's driver for the VM (at creation, or in the Settings tab while it is stopped).
    3. Start the VM and open the Console tab → “Serial”: a logged-in shell, with no SSH involved.
- **Copies**: copy a stopped VM in a moment (`limactl clone`, APFS clones). The copy gets a new name, host name, MAC addresses and SSH keys; a disk on an external drive is cloned on that drive. Each VM shows where it came from, its copies and a note.
- **Screen thumbnails** (VZ VMs with a display, and VMs on HanaLima's driver, through the driver): a live view of the VM's screen on the overview.
- **Logs**: the host agent log and serial consoles, followed live, with search.
- **Provisioning**: edit the scripts and data files Lima applies on every boot. **Run now** runs an entry or an example in the running VM without saving and shows the output. **Run only once** turns a script into a one-shot: it leaves a stamp on success and later starts skip it (a failure retries at the next start; “Run Again” resets it).
- **Ansible from your Mac**: pick a playbook for a VM and run it from the Settings tab; the output streams into a sheet. HanaLima writes an inventory that sends ssh through Lima's `ssh.config` (group `[hanalima]`, host `lima-<name>`) and runs your `ansible-playbook` (`brew install ansible` or `pip install ansible`) in the playbook's folder, so roles and `ansible.cfg` next to it apply. `become` works without setup (Lima gives you passwordless sudo). The same inventory works from the terminal: `ansible-playbook -i ~/Library/Application\ Support/HanaLima/ansible/inventory.ini …`.
- **English and Japanese UI**: follows your macOS language.

## Requirements

- macOS 26 or later (developed on macOS 27 with Apple Silicon; Intel Macs are untested)
- [Lima](https://lima-vm.io/) 2.3 or later, from Homebrew
- To build: Xcode 26 or later, including the Metal Toolchain (required by [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm))

## Quick Start

1. Install Lima and the additional guest agents:

   ```bash
   brew install lima lima-additional-guestagents
   ```

2. Download `HanaLima-<version>.dmg` from [Releases](https://github.com/izawa/HanaLima/releases/latest), open it, drag **HanaLima** into **Applications**, and launch it. It is signed with Developer ID and notarized, so it opens without a warning. To build it yourself instead, see [Building from source](#building-from-source).

3. Click **＋ New VM** at the bottom of the sidebar and create a VM. The template is preset to Ubuntu LTS (`ubuntu-lts`); you can pick another, such as `alpine`. New VMs run on HanaLima's driver by default. The first start downloads the OS image.

To use a fixed IP or a bridged network, open **Networks** in the sidebar, create a network with **＋**, then choose **Add NIC** in the Network section of the VM's **Settings** tab.

### Building from source

1. Install the Metal Toolchain for Xcode, if you haven't already:

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

2. Clone and build. The script builds `build/HanaLima.app` and signs it ad hoc for your Mac:

   ```bash
   git clone https://github.com/izawa/HanaLima.git
   cd HanaLima
   scripts/build-app.sh release
   ```

3. Launch it:

   ```bash
   open build/HanaLima.app
   ```

   Or install it into `/Applications` (quits a running HanaLima first) and launch it from there:

   ```bash
   scripts/make-app.sh --install --open
   ```

### Language

HanaLima shows its UI in Japanese when Japanese is your preferred language, and in English otherwise. To use a different language for HanaLima only, choose it under System Settings → General → Language & Region → Applications, or launch it once with:

```bash
open -a HanaLima --args -AppleLanguages '(en)'
```

## How it works

HanaLima does not link Lima's Go code. It drives the `limactl` CLI, Lima's public interface, and reads its JSON output (`limactl list --format json`, `limactl watch --json`). Changes to `lima.yaml` go through `limactl edit`, so Lima validates them.

Virtual networks are provided by `hanalima-netd`, a helper bundled in the app. Each network is registered as a per-user LaunchAgent with socket activation. A VM attaches with Lima's `networks: - socket: <path>` (the socket_vmnet protocol), and the helper relays its frames to a vmnet network (NAT/host-only) or a bridged vmnet interface, or, for a guest-only network, switches frames between the VMs itself with no vmnet. The helper needs no root, only the `com.apple.security.virtualization` entitlement, which `scripts/build-app.sh` applies. Networks keep working when the app is not running, including for VMs started with plain `limactl start`.

| Path | Purpose |
|---|---|
| `Sources/LimaKit` | `limactl` wrapper (no UI dependencies) |
| `Sources/NetworkKit` | Virtual network definitions, LaunchAgent management, DHCP helpers |
| `Sources/hanalima-netd` | Network helper (Lima socket ⇄ vmnet relay / guest-only switch) |
| `Sources/HanaLima` | SwiftUI app |
| `Driver/` | Lima external driver `lima-driver-hanalima` (vmType `hanalima`) |
| `Prototypes/` | Experiments from the networking investigation, including a reproduction of a macOS vmnet bug |
| `docs/` | Design notes and investigation logs (in Japanese) |

Files HanaLima creates:

- `~/Library/Application Support/HanaLima/` — `networks.json`, the installed helper, network sockets
- `~/Library/LaunchAgents/org.izawa.HanaLima.net.<name>.plist` — one per virtual network
- `~/Library/Logs/HanaLima/` — helper logs
- `<prefix>/lib/lima/lima-driver-hanalima` (`/opt/homebrew/lib/lima/` with Homebrew) — the VM driver, copied there at every launch

Lima's own files (`~/.lima`, the image cache in `~/Library/Caches/lima`, and `~/Library/LaunchAgents/io.lima-vm.autostart.<name>.plist` for start at login) are managed by `limactl`. **Storage → Usage** in the sidebar shows them.

## Known issues

- macOS 27.0.1's vmnet has bugs that HanaLima works around. In particular, reusing a vmnet network after its interface stopped can take over a bridged interface's `bridge100` and remove the Mac's own IPv4 address (reported to Apple as FB25122122). HanaLima never reuses networks, but other virtualization tools running at the same time might. If your Mac loses its IPv4 address, renew DHCP in System Settings (or run `sudo ipconfig set en0 DHCP`) or restart. Details: [docs/02-networking-investigation.md](docs/02-networking-investigation.md).
- Lima limits two features: Lima's snapshots work only for QEMU VMs, still in 2.3 (HanaLima operates on them while the VM is stopped, because live snapshots fail silently with 9p shares; VZ VMs get HanaLima's own), and HanaLima shows screen thumbnails only for VZ VMs with a display whose window is open. Lima 2.3 can also capture a QEMU VM's screen, which HanaLima doesn't use yet. VMs on HanaLima's driver are not limited this way: `limactl snapshot` and thumbnails work through the driver.
- Bridging to Wi-Fi works on our network (tested with a VM getting a LAN address over `en1`), but some access points refuse frames from more than one MAC address per client; if a VM on a Wi-Fi bridge gets no address, try a wired interface.

## Uninstalling

In the app, first switch any VMs on HanaLima's driver to VZ in the Settings tab (they can't start without the driver) and delete the HanaLima networks (this unregisters their LaunchAgents), then remove the app, its data and the driver copy (`/opt/homebrew/lib/lima/` with Homebrew):

```bash
rm -rf ~/Library/Application\ Support/HanaLima ~/Library/Logs/HanaLima /opt/homebrew/lib/lima/lima-driver-hanalima
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

`scripts/release.sh` builds the notarized DMG for a release (maintainers only: it needs the Developer ID certificate and notarytool credentials in the keychain; `--no-notarize` stops after signing). The whole release procedure, up to GitHub Releases, is in [docs/13](docs/13-release.md) (in Japanese).

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
