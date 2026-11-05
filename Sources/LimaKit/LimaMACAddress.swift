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
        var path = instanceDir.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return address(machineID: id, instanceDir: path)
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
