import Foundation

/// DHCP and ARP for a guest-only switch; the host needs no interface on the subnet.
public final class GuestOnlyDHCP: @unchecked Sendable {
    private struct Lease {
        var ip: IPv4
        var name: String
        var expires: Date
    }

    private let subnet: IPv4Subnet
    private let serverIP: IPv4
    private let serverMAC: [UInt8]
    private let reservations: [String: IPv4]
    private let reservedIPs: Set<IPv4>
    private let leaseSeconds: UInt32
    private let now: @Sendable () -> Date
    // Allocation and snapshots share a lock so concurrent relay threads cannot double-allocate.
    private let lock = NSLock()
    private var active: [String: Lease] = [:]
    private var declined: [IPv4: Date] = [:]
    /// Bumped on every change to the leases (grant, release, decline, expiry), so the caller
    /// knows when the lease file needs rewriting; ARP and ignored frames don't touch it.
    public private(set) var stateVersion = 0

    public init(subnet: IPv4Subnet, serverIP: IPv4, serverMAC: [UInt8], reservations: [DHCPReservation],
                leaseTime: TimeInterval = 86400, now: @escaping @Sendable () -> Date = { Date() }) {
        self.subnet = subnet
        self.serverIP = serverIP
        self.serverMAC = Array((serverMAC + [UInt8](repeating: 0, count: 6)).prefix(6))
        self.now = now
        leaseSeconds = leaseTime.isFinite ? UInt32(max(1, min(Double(UInt32.max), leaseTime))) : 86400
        var fixed: [String: IPv4] = [:]
        for reservation in reservations {
            if let mac = DHCPReservation.normalizedMAC(reservation.mac), let ip = IPv4(reservation.ip) {
                fixed[mac] = ip
            }
        }
        self.reservations = fixed
        reservedIPs = Set(reservations.compactMap { IPv4($0.ip) })
    }

    /// Returns a frame for the originating VM, or nil so the caller can switch it normally.
    public func handle(_ frame: UnsafeRawBufferPointer) -> [UInt8]? {
        guard frame.count >= 14 else { return nil }
        let bytes = Array(frame)
        if Self.word(bytes, 12) == 0x0806 { return arpReply(bytes) }
        guard Self.word(bytes, 12) == 0x0800, bytes.count >= 34,
              bytes[14] >> 4 == 4, bytes[23] == 17,
              bytes[20] & 0x3f == 0, bytes[21] == 0 else { return nil }
        let headerLength = Int(bytes[14] & 15) * 4
        let total = Int(Self.word(bytes, 16))
        guard headerLength >= 20, total >= headerLength + 8 + 240,
              total <= bytes.count - 14 else { return nil }
        let udp = 14 + headerLength
        let length = Int(Self.word(bytes, udp + 4))
        guard Self.word(bytes, udp) == 68, Self.word(bytes, udp + 2) == 67,
              length >= 248, length <= total - headerLength else { return nil }
        let bootp = Array(bytes[(udp + 8)..<(udp + length)])
        guard bootp[0] == 1, bootp[1] == 1, bootp[2] == 6,
              Array(bootp[236..<240]) == [99, 130, 83, 99] else { return nil }
        var options: [UInt8: [UInt8]] = [:]
        var i = 240
        var ended = false
        while i < bootp.count {
            let code = bootp[i]
            if code == 255 { ended = true; break }
            if code == 0 { i += 1; continue }
            guard i + 1 < bootp.count else { return nil }
            let count = Int(bootp[i + 1])
            guard count <= bootp.count - i - 2 else { return nil }
            options[code] = Array(bootp[(i + 2)..<(i + 2 + count)])
            i += 2 + count
        }
        guard ended, let type = options[53], type.count == 1,
              options[50].map({ $0.count == 4 }) ?? true,
              options[54].map({ $0 == Self.octets(serverIP.value) }) ?? true else { return nil }
        let macBytes = Array(bootp[28..<34])
        let mac = macBytes.map { String(format: "%02x", $0) }.joined(separator: ":")
        let ciaddr = IPv4(Self.address(bootp, 12))
        let requested = options[50].map { IPv4(Self.address($0, 0)) } ?? (ciaddr.value == 0 ? nil : ciaddr)
        // Hostnames are written to a line-oriented lease file; discard control characters.
        let hostname = options[12].map { String(decoding: $0.filter { $0 >= 32 && $0 != 127 }, as: UTF8.self) }
        let time = now()
        lock.lock()
        defer { lock.unlock() }
        expire(at: time)

        switch type[0] {
        case 1, 3:
            let candidate = assigned(to: mac, requested: type[0] == 3 ? requested : nil)
            if type[0] == 3, requested == nil || candidate != requested {
                return reply(bootp, type: 6, address: nil)
            }
            guard let candidate else { return type[0] == 3 ? reply(bootp, type: 6, address: nil) : nil }
            active[mac] = Lease(ip: candidate, name: hostname ?? active[mac]?.name ?? "",
                                expires: time.addingTimeInterval(Double(leaseSeconds)))
            stateVersion += 1
            return reply(bootp, type: type[0] == 1 ? 2 : 5, address: candidate)
        case 4:
            if let requested, active[mac]?.ip == requested || reservations[mac] == requested {
                declined[requested] = time.addingTimeInterval(Double(leaseSeconds))
                active.removeValue(forKey: mac)
                stateVersion += 1
            }
        case 7:
            if reservations[mac] == nil, let requested, active[mac]?.ip == requested {
                active.removeValue(forKey: mac)
                stateVersion += 1
            }
        case 8:
            if let hostname, active[mac] != nil { active[mac]?.name = hostname; stateVersion += 1 }
            return reply(bootp, type: 5, address: nil)
        default: break
        }
        return nil
    }

    /// Reservations appear only after their VM has asked for an address.
    public var leases: [DHCPLease] {
        let time = now()
        lock.lock()
        defer { lock.unlock() }
        expire(at: time)
        return active.sorted { $0.value.ip < $1.value.ip }.map { mac, lease in
            let hardware = "1," + mac.split(separator: ":").map { String(UInt8($0, radix: 16)!, radix: 16) }.joined(separator: ":")
            return DHCPLease(name: lease.name, ip: lease.ip.description, hwAddress: hardware, expires: lease.expires)
        }
    }

    /// Matches bootpd's lease format so the app can use its existing parser.
    public func leaseFileText() -> String {
        leases.map { lease in
            let seconds = UInt64(max(0, min(Double(Int64.max / 2), lease.expires!.timeIntervalSince1970)))
            return "{\n\tname=\(lease.name)\n\tip_address=\(lease.ip)\n\thw_address=\(lease.hwAddress)\n\tidentifier=\(lease.hwAddress)\n\tlease=0x\(String(seconds, radix: 16))\n}\n"
        }.joined()
    }

    private func expire(at time: Date) {
        let before = active.count
        active = active.filter { $0.value.expires > time }
        declined = declined.filter { $0.value > time }
        if active.count != before { stateVersion += 1 }
    }

    private func assigned(to mac: String, requested: IPv4?) -> IPv4? {
        if let fixed = reservations[mac] { return declined[fixed] == nil ? fixed : nil }
        if let lease = active[mac] { return lease.ip }
        let occupied = Set(active.values.map(\.ip)).union(reservedIPs).union(declined.keys)
        func available(_ ip: IPv4) -> Bool {
            subnet.contains(ip) && ip > subnet.network && ip < subnet.broadcast && ip != serverIP && !occupied.contains(ip)
        }
        if let requested { return available(requested) ? requested : nil }
        // Use a wide counter so even /0 and /32 cannot overflow at the endpoints.
        var value = UInt64(subnet.network.value) + 1
        while value < UInt64(subnet.broadcast.value) {
            let ip = IPv4(UInt32(value))
            if available(ip) { return ip }
            value += 1
        }
        return nil
    }

    private func reply(_ request: [UInt8], type: UInt8, address: IPv4?) -> [UInt8] {
        // A NAK is always broadcast (RFC 2131 §4.3.2): the client's ciaddr is 0 or stale.
        let broadcast = request[10] & 0x80 != 0 || type == 6
        let mac = Array(request[28..<34])
        let destination = broadcast ? UInt32.max : (address?.value ?? Self.address(request, 12))
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 2; bootp[1] = 1; bootp[2] = 6
        bootp.replaceSubrange(4..<8, with: request[4..<8])
        bootp.replaceSubrange(10..<16, with: request[10..<16])
        bootp.replaceSubrange(16..<20, with: Self.octets(address?.value ?? 0))
        bootp.replaceSubrange(20..<24, with: Self.octets(serverIP.value))
        bootp.replaceSubrange(28..<44, with: request[28..<44])
        bootp += [99, 130, 83, 99, 53, 1, type]
        for (code, value): (UInt8, UInt32) in [(54, serverIP.value), (51, leaseSeconds), (1, subnet.mask.value),
                                             (58, leaseSeconds / 2), (59, UInt32(UInt64(leaseSeconds) * 7 / 8))] {
            bootp += [code, 4] + Self.octets(value)
        }
        bootp += [255]
        bootp += [UInt8](repeating: 0, count: max(0, 300 - bootp.count))
        let udpLength = UInt16(bootp.count + 8)
        let total = udpLength + 20
        var ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 255), 0, 0, 0, 0, 64, 17, 0, 0]
        ip += Self.octets(serverIP.value) + Self.octets(destination)
        let checksum = DHCPClientIDFilter.ipv4HeaderChecksum(ip[...])
        ip[10] = UInt8(checksum >> 8); ip[11] = UInt8(checksum & 255)
        return (broadcast ? [UInt8](repeating: 255, count: 6) : mac) + serverMAC + [8, 0] + ip
            + [0, 67, 0, 68, UInt8(udpLength >> 8), UInt8(udpLength & 255), 0, 0] + bootp
    }

    private func arpReply(_ bytes: [UInt8]) -> [UInt8]? {
        guard bytes.count >= 42, Self.word(bytes, 14) == 1, Self.word(bytes, 16) == 0x0800,
              bytes[18] == 6, bytes[19] == 4, Self.word(bytes, 20) == 1,
              Self.address(bytes, 38) == serverIP.value else { return nil }
        let senderMAC = Array(bytes[22..<28])
        var out = senderMAC + serverMAC + [8, 6, 0, 1, 8, 0, 6, 4, 0, 2]
        out += serverMAC + Self.octets(serverIP.value) + senderMAC + bytes[28..<32]
        return out
    }

    private static func word(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func address(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(word(bytes, offset)) << 16 | UInt32(word(bytes, offset + 2))
    }

    private static func octets(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]
    }
}
