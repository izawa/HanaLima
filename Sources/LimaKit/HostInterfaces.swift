import Foundation
import vmnet

/// A host network interface a HanaLima bridge can attach to.
public struct HostInterface: Sendable, Hashable, Identifiable {
    public var id: String { device }
    public var device: String
    /// e.g. "Wi-Fi", "Ethernet".
    public var displayName: String

    public init(device: String, displayName: String) {
        self.device = device
        self.displayName = displayName
    }
}

public enum HostInterfaces {
    /// Interfaces vmnet can bridge to, with their System Settings names.
    public static func bridgeable() async -> [HostInterface] {
        var devices: [String] = []
        if let list = vmnet_copy_shared_interface_list() {
            for i in 0..<xpc_array_get_count(list) {
                if let s = xpc_array_get_string(list, i) { devices.append(String(cString: s)) }
            }
        }
        let ns = ProcessRunner(executableURL: URL(fileURLWithPath: "/usr/sbin/networksetup"), environment: [:])
        let ports = (try? await ns.run(["-listallhardwareports"]).stdoutString) ?? ""
        let names = parseHardwarePorts(ports)
        return devices.map { HostInterface(device: $0, displayName: names[$0] ?? $0) }
    }

    static func parseHardwarePorts(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var port: String?
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line.hasPrefix("Device: "), let p = port { result[String(line.dropFirst("Device: ".count))] = p }
        }
        return result
    }
}
