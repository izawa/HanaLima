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

    var name: String
    var dir: URL
    var os: String
    var arch: String
    var cpus: Int
    var memoryBytes: UInt64
    var sshLocalPort: Int
    var mounts: [Mount]
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
