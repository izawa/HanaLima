import Foundation
import LimaKit

/// What the driver needs from the instance JSON Lima sends in `Configure` (the same shape as
/// `limactl list --format json`, with the full `config`).
struct InstanceSpec: Sendable {
    struct Mount: Sendable {
        var location: String
        var mountPoint: String
        var writable: Bool
        /// Lima's `limayaml.MountTag`: "lima-" + the first 8 bytes of SHA-256 over
        /// "<location>:<mountPoint>", in hex. cidata writes the same tag into the guest's fstab.
        var tag: String { LimaMACAddress.mountTag(location: location, mountPoint: mountPoint) }
    }

    /// A NIC after the first (Lima's `networks:`), with the MAC Lima's defaults gave it.
    enum NIC: Sendable {
        case vzNAT(mac: String)
        /// A QEMU/socket_vmnet stream socket (HanaLima's netd, or Lima's `socket:`).
        case socket(path: String, mac: String)
        /// A Lima `lima:` network served by socket_vmnet (shared/host/bridged): the same stream
        /// protocol as `socket:`, at `<varRun>/socket_vmnet.<name>`, started by Lima before Start.
        case socketVMNet(name: String, path: String, mac: String)
        /// A further `lima:` user-v2 network (the first one is NIC 0, see `sharedUsernet`): its
        /// shared usernet's fd socket.
        case userV2(name: String, fdSocket: String, mac: String)
        /// A `lima:` network that networks.yaml doesn't define (Validate refuses it).
        case lima(name: String)
    }

    /// Lima's "first usernet network": a `lima:` user-v2 entry replaces the driver's own usernet
    /// as NIC 0 (Lima starts that shared daemon under `_networks/<name>/`; cidata and SSH go
    /// through it). nil when NIC 0 is the per-instance usernet.
    struct SharedUsernet: Sendable {
        var name: String
        var fdSocket: String
        var endpointSocket: String
        /// Where that usernet serves DHCP's gateway and DNS (the subnet's second address).
        var gateway: String
    }
    var sharedUsernet: SharedUsernet?

    /// Lima's `additionalDisks`: `<limaHome>/_disks/<name>/datadisk`, locked with `in_use_by`.
    struct Disk: Sendable {
        var name: String
        var dir: URL
        var image: URL { dir.appendingPathComponent("datadisk") }
        var lock: URL { dir.appendingPathComponent("in_use_by") }
    }

    var name: String
    var dir: URL
    var limaHome: URL
    var os: String
    var arch: String
    var cpus: Int
    var memoryBytes: UInt64
    var sshLocalPort: Int
    var mounts: [Mount]
    var nics: [NIC]
    var disks: [Disk]
    /// `video.display` other than "none": graphics, keyboard and pointer, shown in a window.
    var display: Bool
    var mountType: String
    var sshOverVsock: Bool
    /// `vmOpts.vz.rosetta.enabled`: share macOS's Rosetta with the guest (`vz-rosetta`).
    var rosetta: Bool
    /// `vmOpts.vz.rosetta.binFmt`: the guest registers it for x86_64 binaries (Lima's boot script).
    var rosettaBinFmt: Bool
    /// `vmOpts.hanalima.usernet` (default true): Lima's user-mode network on NIC 0. Off, the VM
    /// has only the NICs in `networks:` (or none), and SSH must go over vsock: the isolation
    /// profile (docs/06, docs/09).
    var usernet: Bool
    /// Set for a boot outside Lima (`--hosted`: the rescue boot, the installer; docs/07).
    var hosted: Hosted?

    /// What a hosted boot attaches besides the instance's own files.
    struct Hosted: Sendable {
        /// The installer ISO, as USB mass storage (EFI boots it).
        var iso: URL?
        /// A FAT image with EFI loaders and a grub.cfg, attached before the ISO (unattended installs).
        var bootImage: URL?
        /// The fix-up ISO (label HANALIMA), as USB mass storage.
        var helper: URL?
        /// A NoCloud seed ISO, as a read-only virtio block device.
        var seed: URL?
        /// Attach Lima's `cidata.iso` if present (the rescue boot: cloud-init sees the same instance).
        var cidata = true
        /// The serial log's name in the instance directory.
        var serialLog = "serialv.log"
    }
    /// Lima's MAC for the first NIC (usernet), which cidata's network config matches eth0 by.
    var macAddress: String { LimaMACAddress.address(instanceDir: dir) ?? "52:55:55:00:00:00" }

    init(json: [String: Any]) throws {
        guard let name = json["name"] as? String, let dir = json["dir"] as? String,
              let config = json["config"] as? [String: Any] else {
            throw DriverError("instance JSON lacks name, dir or config")
        }
        self.name = name
        self.dir = URL(fileURLWithPath: dir, isDirectory: true)
        os = config["os"] as? String ?? "Linux"
        arch = config["arch"] as? String ?? "aarch64"
        cpus = config["cpus"] as? Int ?? 4
        memoryBytes = try Self.bytes(config["memory"] as? String ?? "4GiB")
        sshLocalPort = json["sshLocalPort"] as? Int ?? 0
        mounts = (config["mounts"] as? [[String: Any]] ?? []).compactMap { m in
            guard let location = m["location"] as? String else { return nil }
            return Mount(location: location, mountPoint: m["mountPoint"] as? String ?? location,
                         writable: m["writable"] as? Bool ?? false)
        }
        limaHome = URL(fileURLWithPath: json["LimaHome"] as? String ?? self.dir.deletingLastPathComponent().path, isDirectory: true)
        let limaNetworks = LimaNetworks.load(from: limaHome.appending(path: "_config/networks.yaml"))
        var shared: SharedUsernet?
        var resolved: [NIC] = []
        for n in config["networks"] as? [[String: Any]] ?? [] {
            let mac = n["macAddress"] as? String ?? ""
            if n["vzNAT"] as? Bool == true { resolved.append(.vzNAT(mac: mac)); continue }
            if let socket = n["socket"] as? String, !socket.isEmpty { resolved.append(.socket(path: socket, mac: mac)); continue }
            guard let lima = n["lima"] as? String, !lima.isEmpty else { continue }
            guard let net = limaNetworks.network(named: lima) else { resolved.append(.lima(name: lima)); continue }
            if net.mode == "user-v2" {
                let fd = LimaNetworks.usernetSocket(limaHome: limaHome, network: lima, kind: "fd")
                if shared == nil {
                    shared = SharedUsernet(name: lima, fdSocket: fd,
                                           endpointSocket: LimaNetworks.usernetSocket(limaHome: limaHome, network: lima, kind: "ep"),
                                           gateway: LimaNetworks.usernetGateway(of: net) ?? "192.168.104.2")
                } else {
                    resolved.append(.userV2(name: lima, fdSocket: fd, mac: mac))
                }
            } else {
                resolved.append(.socketVMNet(name: lima, path: limaNetworks.socketVMNetSocket(for: lima), mac: mac))
            }
        }
        nics = resolved
        sharedUsernet = shared
        let home = limaHome
        disks = (config["additionalDisks"] as? [[String: Any]] ?? []).compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return Disk(name: name, dir: home.appendingPathComponent("_disks/\(name)", isDirectory: true))
        }
        display = ((config["video"] as? [String: Any])?["display"] as? String ?? "none") != "none"
        mountType = config["mountType"] as? String ?? "virtiofs"
        sshOverVsock = (config["ssh"] as? [String: Any])?["overVsock"] as? Bool ?? false
        let rosettaOpts = ((config["vmOpts"] as? [String: Any])?["vz"] as? [String: Any])?["rosetta"] as? [String: Any]
        rosetta = rosettaOpts?["enabled"] as? Bool == true
        rosettaBinFmt = (rosettaOpts?["binfmt"] as? Bool ?? rosettaOpts?["binFmt"] as? Bool) == true  // Lima's tag is lowercase
        let hanalimaOpts = (config["vmOpts"] as? [String: Any])?["hanalima"] as? [String: Any]
        usernet = hanalimaOpts?["usernet"] as? Bool ?? true
    }

    /// A spec for a hosted boot: the instance's own disk, EFI store and identifier, usernet on
    /// NIC 0 with Lima's MAC, a display unless headless, and nothing of Lima's: no mounts, no
    /// extra NICs, no additional disks.
    init(hostedDir dir: URL, cpus: Int, memoryBytes: UInt64, display: Bool, hosted: Hosted) {
        name = dir.lastPathComponent
        self.dir = dir
        limaHome = dir.deletingLastPathComponent()
        os = "Linux"
        arch = "aarch64"
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        sshLocalPort = 0
        mounts = []
        nics = []
        disks = []
        self.display = display
        mountType = "virtiofs"
        sshOverVsock = false
        rosetta = false
        rosettaBinFmt = false
        usernet = true
        sharedUsernet = nil
        self.hosted = hosted
    }

    /// Lima's `units.RAMInBytes`: "2GiB", "512MiB", "4G", "1024M", plain bytes.
    static func bytes(_ s: String) throws -> UInt64 {
        let scanner = Scanner(string: s.trimmingCharacters(in: .whitespaces))
        guard let number = scanner.scanDouble() else { throw DriverError("not a size: \(s)") }
        let unit = scanner.scanCharacters(from: .letters)?.lowercased() ?? ""
        let factor: Double
        switch unit {
        case "", "b": factor = 1
        case "k", "kb", "kib": factor = 1024
        case "m", "mb", "mib": factor = 1024 * 1024
        case "g", "gb", "gib": factor = 1024 * 1024 * 1024
        case "t", "tb", "tib": factor = 1024 * 1024 * 1024 * 1024
        default: throw DriverError("unknown size unit in \(s)")
        }
        return UInt64(number * factor)
    }

    var diskURL: URL { dir.appendingPathComponent("disk") }
    var imageURL: URL { dir.appendingPathComponent("image") }
    var cidataURL: URL { dir.appendingPathComponent("cidata.iso") }
    var efiURL: URL { dir.appendingPathComponent("vz-efi") }
    var identifierURL: URL { dir.appendingPathComponent("vz-identifier") }
    var serialLogURL: URL { dir.appendingPathComponent(hosted?.serialLog ?? "serialv.log") }
    /// The console both ways (`SerialConsole`); Lima's QEMU driver uses the same name.
    var serialSocket: String { dir.appendingPathComponent(DriverControl.serialSocketName).path }
    /// HanaLima's requests to the driver (`ControlServer`, `DriverControl` in LimaKit).
    var controlSocket: String { dir.appendingPathComponent(DriverControl.socketName).path }
    /// Lima's `filenames.GuestAgentSock`: where the host agent dials the guest agent.
    var guestAgentSocket: String { dir.appendingPathComponent("ga.sock").path }
    /// The vsock port Lima's guest agent listens on (what the vz driver uses).
    static let guestAgentVsockPort: UInt32 = 2222
    /// Lima's `filenames.PIDFile(vmType)`: `limactl stop --force` kills what this names.
    var pidURL: URL { dir.appendingPathComponent(hosted == nil ? "hanalima.pid" : DriverControl.hostedPIDName) }
    var usernetPIDURL: URL { dir.appendingPathComponent("hanalima-usernet.pid") }
    var usernetLogURL: URL { dir.appendingPathComponent("hanalima-usernet.log") }
    /// usernet's sockets, named as Lima's `SockWithDirectory(dir, "default", …)` does; a shared
    /// user-v2 usernet's when the instance uses one as NIC 0.
    var usernetEndpointSocket: String { sharedUsernet?.endpointSocket ?? dir.appendingPathComponent("default_ep.sock").path }
    var usernetFDSocket: String { sharedUsernet?.fdSocket ?? dir.appendingPathComponent("default_fd.sock").path }
    /// Where NIC 0's usernet answers DNS and routes: the per-instance 192.168.5.2, or the shared one's.
    var usernetGateway: String { sharedUsernet?.gateway ?? Usernet.gateway }
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}
