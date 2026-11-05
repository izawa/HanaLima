import Foundation

/// Reads macOS's DHCP lease database (`/var/db/dhcpd_leases`, world-readable), which vmnet's
/// DHCP server writes. Lima guests register with the hostname `lima-<instance>`, so this tells
/// us each VM's address on a virtual network.
public struct DHCPLease: Hashable, Sendable {
    public var name: String
    public var ip: String
    public var hwAddress: String
    public var expires: Date?

    /// The Lima instance name, if the hostname follows Lima's `lima-<name>` convention.
    public var limaInstance: String? {
        name.hasPrefix("lima-") ? String(name.dropFirst(5)) : nil
    }
}

public enum DHCPLeases {
    public static let path = "/var/db/dhcpd_leases"

    /// macOS's leases (vmnet networks) plus the lease files netd writes for guest-only networks.
    public static func load(from path: String = path) -> [DHCPLease] {
        var leases = (try? String(contentsOfFile: path, encoding: .utf8)).map(parse) ?? []
        // Only networks that still exist as guest-only: a file left by a deleted or re-typed
        // network must not answer for a subnet that is now someone else's.
        let networks = (try? NetworkStore.load()) ?? []
        for network in networks where network.isGuestOnly {
            if let text = try? String(contentsOf: NetworkPaths.leases(for: network.name), encoding: .utf8) { leases += parse(text) }
        }
        return leases
    }

    static func parse(_ text: String) -> [DHCPLease] {
        var leases: [DHCPLease] = []
        var fields: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                fields = [:]
            } else if line == "}" {
                if let ip = fields["ip_address"] {
                    let expires = fields["lease"].flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
                        .map { Date(timeIntervalSince1970: TimeInterval($0)) }
                    leases.append(DHCPLease(name: fields["name"] ?? "", ip: ip,
                                            hwAddress: fields["hw_address"] ?? "", expires: expires))
                }
            } else if let eq = line.firstIndex(of: "=") {
                fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        return leases
    }

    /// The most recent lease of `instance` inside `subnet`.
    public static func address(of instance: String, in subnet: IPv4Subnet, leases: [DHCPLease]) -> String? {
        leases
            .filter { $0.limaInstance == instance && IPv4($0.ip).map(subnet.contains) == true }
            .max { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }?
            .ip
    }
}
