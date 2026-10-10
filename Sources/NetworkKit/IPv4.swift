import Foundation

/// A minimal IPv4 address value type.
public struct IPv4: Hashable, Comparable, Sendable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), let octet = UInt8(p) else { return nil }
            v = v << 8 | UInt32(octet)
        }
        value = v
    }

    public var description: String {
        "\(value >> 24).\(value >> 16 & 0xff).\(value >> 8 & 0xff).\(value & 0xff)"
    }

    public static func < (a: IPv4, b: IPv4) -> Bool { a.value < b.value }

    public static func mask(prefixLength: Int) -> IPv4 {
        IPv4(prefixLength == 0 ? 0 : UInt32.max << (32 - UInt32(prefixLength)))
    }
}

/// An IPv4 subnet in CIDR form.
public struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    public var network: IPv4
    public var prefixLength: Int

    public init(containing address: IPv4, prefixLength: Int) {
        self.prefixLength = prefixLength
        self.network = IPv4(address.value & IPv4.mask(prefixLength: prefixLength).value)
    }

    public init?(cidr: String) {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let addr = IPv4(String(parts[0])), let len = Int(parts[1]), (0...32).contains(len) else {
            return nil
        }
        self.init(containing: addr, prefixLength: len)
    }

    public var mask: IPv4 { IPv4.mask(prefixLength: prefixLength) }
    public var broadcast: IPv4 { IPv4(network.value | ~mask.value) }
    public var description: String { "\(network)/\(prefixLength)" }

    public func contains(_ address: IPv4) -> Bool { address.value & mask.value == network.value }

    public func overlaps(_ other: IPv4Subnet) -> Bool {
        let shorter = min(prefixLength, other.prefixLength)
        let m = IPv4.mask(prefixLength: shorter).value
        return network.value & m == other.network.value & m
    }

    /// RFC 1918 private ranges.
    public var isPrivate: Bool {
        [IPv4Subnet(cidr: "10.0.0.0/8")!, IPv4Subnet(cidr: "172.16.0.0/12")!, IPv4Subnet(cidr: "192.168.0.0/16")!]
            .contains { $0.prefixLength <= prefixLength && $0.contains(network) }
    }
}
