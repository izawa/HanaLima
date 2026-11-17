import Foundation

/// Reads macOS's DHCP lease database (`/var/db/dhcpd_leases`, world-readable), which vmnet's
/// DHCP server writes. Lima guests register with the hostname `lima-<instance>`, so this tells
/// us each VM's address on a virtual network.
public struct DHCPLease: Hashable, Sendable {
    public var name: String
    public var ip: String
    public var hwAddress: String
    public var expires: Date?

    public init(name: String, ip: String, hwAddress: String, expires: Date?) {
        self.name = name; self.ip = ip; self.hwAddress = hwAddress; self.expires = expires
    }

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

    public static func parse(_ text: String) -> [DHCPLease] {
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
    /// The address of a VM's NIC: the newest lease for its MAC, else one under the VM's name
    /// (a guest that identifies itself by a DUID leaves no MAC in the lease). With a MAC, a
    /// lease by name counts only if it has no MAC: one that has belongs to another NIC (two NICs
    /// of one VM on the same network both lease under its name).
    public static func address(mac: String?, instance: String, in subnet: IPv4Subnet, leases: [DHCPLease]) -> (ip: String, byMAC: Bool)? {
        let inSubnet = leases.filter { IPv4($0.ip).map(subnet.contains) == true }
        guard let mac else { return address(of: instance, in: subnet, leases: inSubnet).map { ($0, false) } }
        if let lease = inSubnet.filter({ Self.mac(of: $0) == mac }).max(by: { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }) {
            return (lease.ip, true)
        }
        return address(of: instance, in: subnet, leases: inSubnet.filter { Self.mac(of: $0) == nil }).map { ($0, false) }
    }

    /// bootpd writes `hw_address=1,52:55:55:…` (the hardware type first). Only type 1 is an
    /// Ethernet MAC; `ff,…` is a client identifier (a DUID), even when it is six bytes long.
    public static func mac(of lease: DHCPLease) -> String? {
        let parts = lease.hwAddress.split(separator: ",", maxSplits: 1)
        guard parts.count == 2, parts[0] == "1" else { return nil }
        return DHCPReservation.normalizedMAC(String(parts[1]))
    }

    public static func address(of instance: String, in subnet: IPv4Subnet, leases: [DHCPLease]) -> String? {
        leases
            .filter { $0.limaInstance == instance && IPv4($0.ip).map(subnet.contains) == true }
            .max { ($0.expires ?? .distantPast) < ($1.expires ?? .distantPast) }?
            .ip
    }
}
