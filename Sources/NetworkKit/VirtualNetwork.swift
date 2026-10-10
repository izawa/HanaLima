import Foundation

/// A HanaLima virtual network, served by `hanalima-netd` on top of vmnet.
/// Lima instances attach with `networks: - socket: <socketPath>`.
public struct VirtualNetwork: Codable, Hashable, Sendable, Identifiable {
    public enum Mode: String, Codable, Sendable, CaseIterable, Identifiable {
        /// NAT to the outside world, reachable from the host and other VMs.
        case shared
        /// Host and VMs only, no outside access.
        case host
        /// VMs join the LAN of `bridgedInterface`; addresses come from the LAN's DHCP server.
        /// Uses the legacy vmnet bridged mode, which needs no root when the helper is signed
        /// with com.apple.security.virtualization.
        case bridged

        public var id: String { rawValue }
    }

    public var id: String { name }

    public var name: String
    public var mode: Mode
    /// Host-side address of the network, e.g. "192.168.200.1". vmnet reserves it for the host
    /// and hands out the rest of the subnet by DHCP. Unused in bridged mode.
    public var gateway: String
    public var prefixLength: Int
    public var comment: String
    /// Fixed addresses handed out by vmnet's DHCP server, keyed by the guest NIC's MAC address.
    /// Unused in bridged mode.
    public var reservations: [DHCPReservation]
    /// Host interface to bridge to in bridged mode, e.g. "en0".
    public var bridgedInterface: String

    public init(name: String, mode: Mode = .shared, gateway: String = "192.168.200.1",
                prefixLength: Int = 24, comment: String = "", reservations: [DHCPReservation] = [],
                bridgedInterface: String = "en0") {
        self.name = name
        self.mode = mode
        self.gateway = gateway
        self.prefixLength = prefixLength
        self.comment = comment
        self.reservations = reservations
        self.bridgedInterface = bridgedInterface
    }

    enum CodingKeys: String, CodingKey { case name, mode, gateway, prefixLength, comment, reservations, bridgedInterface }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        mode = try c.decode(Mode.self, forKey: .mode)
        gateway = try c.decode(String.self, forKey: .gateway)
        prefixLength = try c.decode(Int.self, forKey: .prefixLength)
        comment = try c.decodeIfPresent(String.self, forKey: .comment) ?? ""
        reservations = try c.decodeIfPresent([DHCPReservation].self, forKey: .reservations) ?? []
        bridgedInterface = try c.decodeIfPresent(String.self, forKey: .bridgedInterface) ?? "en0"
    }

    public var isBridged: Bool { mode == .bridged }
    /// nil in bridged mode: the LAN owns the addressing.
    public var gatewayAddress: IPv4? { isBridged ? nil : IPv4(gateway) }
    public var subnet: IPv4Subnet? { gatewayAddress.map { IPv4Subnet(containing: $0, prefixLength: prefixLength) } }
    public var netmask: String { IPv4.mask(prefixLength: prefixLength).description }

    /// "NAT", "ホストオンリー" or "ブリッジ".
    public var kindLabel: String {
        switch mode {
        case .shared: "NAT"
        case .host: String(localized: "ホストオンリー")
        case .bridged: String(localized: "ブリッジ")
        }
    }

    /// One-line description for menus, e.g. "dev（NAT 192.168.200.0/24）" or "lan（ブリッジ en0）".
    public var menuDescription: String {
        isBridged ? String(localized: "\(name)（ブリッジ \(bridgedInterface)）") : String(localized: "\(name)（\(kindLabel) \(subnet?.description ?? "")）")
    }

    public var socketPath: String { NetworkPaths.socket(for: name).path }
    public var launchLabel: String { NetworkPaths.launchLabel(for: name) }

    /// Usable prefix lengths. vmnet needs room for the gateway plus at least a few guests.
    public static let prefixLengths = 16...28

    public enum ValidationError: Error, Equatable, LocalizedError {
        case invalidName
        case duplicateName
        case invalidGateway
        case gatewayIsNetworkOrBroadcast
        case invalidPrefixLength
        case notPrivate
        case overlaps(String)
        case invalidReservation(String)
        case missingInterface

        public var errorDescription: String? {
            switch self {
            case .invalidName: String(localized: "名前は英小文字・数字・ハイフンで 1〜24 文字、先頭は英小文字にしてください。")
            case .duplicateName: String(localized: "同じ名前のネットワークが既にあります。")
            case .invalidGateway: String(localized: "ゲートウェイの IPv4 アドレスが正しくありません。")
            case .gatewayIsNetworkOrBroadcast: String(localized: "ゲートウェイにネットワークアドレスやブロードキャストアドレスは使えません（例: 192.168.200.1）。")
            case .invalidPrefixLength: String(localized: "プレフィックス長は /\(VirtualNetwork.prefixLengths.lowerBound)〜/\(VirtualNetwork.prefixLengths.upperBound) にしてください。")
            case .notPrivate: String(localized: "プライベートアドレス（10/8, 172.16/12, 192.168/16）の範囲にしてください。")
            case .overlaps(let what): String(localized: "\(what) とアドレス範囲が重なっています。")
            case .invalidReservation(let why): String(localized: "固定 IP: \(why)")
            case .missingInterface: String(localized: "ブリッジするインターフェースを選んでください。")
            }
        }
    }

    /// Subnets already used by Lima and macOS that a new network must not overlap.
    public static let reservedSubnets: [(name: String, subnet: IPv4Subnet)] = [
        (String(localized: "Lima のユーザーモードネットワーク"), IPv4Subnet(cidr: "192.168.5.0/24")!),
        (String(localized: "vzNAT（macOS の既定 NAT）"), IPv4Subnet(cidr: "192.168.64.0/24")!),
        (String(localized: "Lima の user-v2 ネットワーク"), IPv4Subnet(cidr: "192.168.104.0/24")!),
        (String(localized: "Lima の shared ネットワーク"), IPv4Subnet(cidr: "192.168.105.0/24")!),
        (String(localized: "Lima の host ネットワーク"), IPv4Subnet(cidr: "192.168.106.0/24")!),
    ]

    /// Checks this network against the rules and the other existing networks.
    public func validate(against others: [VirtualNetwork]) -> [ValidationError] {
        var errors: [ValidationError] = []
        if name.wholeMatch(of: /[a-z][a-z0-9-]{0,23}/) == nil || name.hasSuffix("-") { errors.append(.invalidName) }
        if others.contains(where: { $0.name == name }) { errors.append(.duplicateName) }
        if isBridged {
            if bridgedInterface.wholeMatch(of: /[a-z][a-z0-9]{0,14}/) == nil { errors.append(.missingInterface) }
            return errors
        }
        guard Self.prefixLengths.contains(prefixLength) else { return errors + [.invalidPrefixLength] }
        guard let gw = gatewayAddress, let subnet else { return errors + [.invalidGateway] }
        if gw == subnet.network || gw == subnet.broadcast { errors.append(.gatewayIsNetworkOrBroadcast) }
        if !subnet.isPrivate { errors.append(.notPrivate) }
        for (what, reserved) in Self.reservedSubnets where subnet.overlaps(reserved) {
            errors.append(.overlaps(what))
        }
        for other in others where other.name != name {
            if let os = other.subnet, subnet.overlaps(os) { errors.append(.overlaps(String(localized: "ネットワーク「\(other.name)」"))) }
        }
        errors += reservationErrors(gateway: gw, subnet: subnet)
        return errors
    }

    private func reservationErrors(gateway: IPv4, subnet: IPv4Subnet) -> [ValidationError] {
        var errors: [ValidationError] = []
        var macs = Set<String>(), ips = Set<IPv4>()
        for r in reservations {
            guard let mac = DHCPReservation.normalizedMAC(r.mac) else {
                errors.append(.invalidReservation(String(localized: "MAC アドレス「\(r.mac)」が正しくありません。")))
                continue
            }
            guard let ip = IPv4(r.ip) else {
                errors.append(.invalidReservation(String(localized: "IP アドレス「\(r.ip)」が正しくありません。")))
                continue
            }
            if !subnet.contains(ip) || ip == subnet.network || ip == subnet.broadcast || ip == gateway {
                errors.append(.invalidReservation(String(localized: "\(r.ip) は \(subnet.description) の中で、ゲートウェイ以外のアドレスにしてください。")))
            }
            if !macs.insert(mac).inserted { errors.append(.invalidReservation(String(localized: "MAC アドレス \(mac) が重複しています。"))) }
            if !ips.insert(ip).inserted { errors.append(.invalidReservation(String(localized: "IP アドレス \(r.ip) が重複しています。"))) }
        }
        return errors
    }

    /// Suggests a free /24 for a new network, starting at 192.168.200.0/24.
    public static func suggestedGateway(avoiding others: [VirtualNetwork]) -> String {
        for third in 200...254 {
            let candidate = IPv4Subnet(cidr: "192.168.\(third).0/24")!
            let taken = others.compactMap(\.subnet) + reservedSubnets.map(\.subnet)
            if !taken.contains(where: { $0.overlaps(candidate) }) { return "192.168.\(third).1" }
        }
        return "10.200.0.1"
    }
}

public struct DHCPReservation: Codable, Hashable, Sendable, Identifiable {
    public var id: String { mac }
    /// Guest NIC MAC address, e.g. "52:55:55:12:34:56".
    public var mac: String
    public var ip: String
    /// Usually the VM name.
    public var comment: String

    public init(mac: String, ip: String, comment: String = "") {
        self.mac = mac
        self.ip = ip
        self.comment = comment
    }

    /// Lowercase, zero-padded "aa:bb:cc:dd:ee:ff", or nil if not a MAC address.
    public static func normalizedMAC(_ s: String) -> String? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var out: [String] = []
        for p in parts {
            guard (1...2).contains(p.count), let v = UInt8(p, radix: 16) else { return nil }
            out.append(String(format: "%02x", v))
        }
        return out.joined(separator: ":")
    }
}
