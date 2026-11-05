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
        /// Lima's `lima:` networks (socket_vmnet, user-v2): not supported by this driver.
        case lima(name: String)
    }

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
        nics = (config["networks"] as? [[String: Any]] ?? []).compactMap { n in
            let mac = n["macAddress"] as? String ?? ""
            if n["vzNAT"] as? Bool == true { return .vzNAT(mac: mac) }
            if let socket = n["socket"] as? String, !socket.isEmpty { return .socket(path: socket, mac: mac) }
            if let lima = n["lima"] as? String, !lima.isEmpty { return .lima(name: lima) }
            return nil
        }
        let home = limaHome
        disks = (config["additionalDisks"] as? [[String: Any]] ?? []).compactMap { d in
            guard let name = d["name"] as? String else { return nil }
            return Disk(name: name, dir: home.appendingPathComponent("_disks/\(name)", isDirectory: true))
        }
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
    var serialLogURL: URL { dir.appendingPathComponent("serialv.log") }
    /// Lima's `filenames.GuestAgentSock`: where the host agent dials the guest agent.
    var guestAgentSocket: String { dir.appendingPathComponent("ga.sock").path }
    /// The vsock port Lima's guest agent listens on (what the vz driver uses).
    static let guestAgentVsockPort: UInt32 = 2222
    /// Lima's `filenames.PIDFile(vmType)`: `limactl stop --force` kills what this names.
    var pidURL: URL { dir.appendingPathComponent("hanalima.pid") }
    var usernetPIDURL: URL { dir.appendingPathComponent("hanalima-usernet.pid") }
    var usernetLogURL: URL { dir.appendingPathComponent("hanalima-usernet.log") }
    /// usernet's sockets, named as Lima's `SockWithDirectory(dir, "default", …)` does.
    var usernetEndpointSocket: String { dir.appendingPathComponent("default_ep.sock").path }
    var usernetFDSocket: String { dir.appendingPathComponent("default_fd.sock").path }
}

struct DriverError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}
