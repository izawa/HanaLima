import Foundation
import Security

/// The one VM that receives the USB accessories the user assigns to HanaLima's driver in macOS's
/// "Virtual Machine Accessories" menu (docs/19). The system assigns a device to an app, and every
/// driver process is the same app to it, so HanaLima picks one VM: only that VM's driver
/// registers for accessories. Kept outside lima.yaml so a `limactl clone` copy doesn't inherit
/// it; the VM is named by its folder and its `vz-identifier`, which a clone or a VM made again
/// under the same name doesn't share. Read by the driver at each start, written by the app.
public struct USBTarget: Codable, Equatable, Sendable {
    public static let fileName = "usb-target.json"

    /// The instance directory, symlinks resolved.
    public var instanceDir: String
    /// The VM's `vz-identifier`, base64.
    public var machineIdentifier: String

    public init(instanceDir: String, machineIdentifier: String) {
        self.instanceDir = instanceDir
        self.machineIdentifier = machineIdentifier
    }

    /// The target for the VM in `instanceDir`; nil before its first start (no `vz-identifier`).
    public init?(instanceDir: URL) {
        guard let data = try? Data(contentsOf: instanceDir.appending(path: "vz-identifier")), !data.isEmpty else { return nil }
        self.init(instanceDir: Self.canonical(instanceDir), machineIdentifier: data.base64EncodedString())
    }

    /// Whether this is the VM in `instanceDir`, as it is now.
    public func matches(instanceDir: URL) -> Bool {
        USBTarget(instanceDir: instanceDir) == self
    }

    public static func load(from file: URL) -> USBTarget? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(USBTarget.self, from: data)
    }

    /// Writes the target, or removes the file for none.
    public static func save(_ target: USBTarget?, to file: URL) throws {
        guard let target else {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            return
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(target).write(to: file, options: .atomic)
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The entitlement that lets a process claim USB accessories. Only a build signed with
    /// HanaLima's Developer ID and the driver's provisioning profile carries it (docs/19).
    public static let entitlement = "com.apple.developer.accessory-access.usb"

    /// Whether the executable at `url` is signed with `entitlement` (the app asks this of its
    /// bundled driver before offering USB passthrough).
    public static func isEntitled(executable url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &info) == errSecSuccess,
              let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else { return false }
        return entitlements[entitlement] as? Bool == true
    }
}
