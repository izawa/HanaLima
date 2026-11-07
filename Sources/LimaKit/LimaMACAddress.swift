import CryptoKit
import Foundation
import IOKit

/// The MAC address Lima gives a VM's first NIC (`limayaml.MACAddress`): `52:55:55` followed by
/// the first three bytes of SHA-256 over the Mac's IOPlatformUUID and the instance directory.
/// Lima writes it into the guest's network configuration (cidata's network-config matches eth0
/// by it), so a VM booted outside Lima needs the same address to bring up eth0.
public enum LimaMACAddress {
    public static func address(machineID: String, instanceDir: String) -> String {
        let digest = SHA256.hash(data: Data((machineID + instanceDir).utf8))
        let bytes = [0x52, 0x55, 0x55] + Array(digest.prefix(3))
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The instance directory as Lima spells it (`~/.lima/<name>`, no trailing slash).
    public static func address(instanceDir: URL) -> String? {
        guard let id = machineID() else { return nil }
        return address(machineID: id, instanceDir: limaSpelling(of: instanceDir))
    }

    /// The path exactly as Lima passed it, without a trailing slash. Not `standardizedFileURL`:
    /// for an existing folder it drops the `/private` of `/private/tmp/…` (where Lima keeps it),
    /// and a different MAC leaves the guest's eth0 down.
    static func limaSpelling(of instanceDir: URL) -> String {
        var path = instanceDir.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// Lima's `limayaml.MountTag`: the virtiofs tag of a share, "lima-" + the first 8 bytes of
    /// SHA-256 over "<location>:<mountPoint>" in hex. cidata writes it into the guest's fstab.
    public static func mountTag(location: String, mountPoint: String) -> String {
        let digest = SHA256.hash(data: Data((location + ":" + mountPoint).utf8))
        return "lima-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// IOPlatformUUID, what Lima's `osutil.MachineID` reads from ioreg.
    public static func machineID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let key = kIOPlatformUUIDKey as CFString
        return IORegistryEntryCreateCFProperty(service, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}
