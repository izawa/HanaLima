import Foundation
import Testing
@testable import NetworkKit

@Suite struct GuestOnlyDHCPTests {
    private static let subnet = IPv4Subnet(cidr: "192.168.233.0/29")!
    private static let serverIP = IPv4("192.168.233.1")!
    private static let serverMAC: [UInt8] = [2, 0, 0, 0, 0, 1]
    private static let first: [UInt8] = [0x52, 0x55, 0x55, 1, 2, 3]
    private static let second: [UInt8] = [0x52, 0x55, 0x55, 1, 2, 4]
    private static let third: [UInt8] = [0x52, 0x55, 0x55, 1, 2, 5]
    private static let reserved: [UInt8] = [0x52, 0x55, 0x55, 0xa, 0xb, 0xc]
    private static let fixedIP: [UInt8] = [192, 168, 233, 6]
    private static let bootp = 42

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_762_192_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
    }

    private func server(clock: Clock = Clock()) -> GuestOnlyDHCP {
        GuestOnlyDHCP(subnet: Self.subnet, serverIP: Self.serverIP, serverMAC: Self.serverMAC,
                      reservations: [.init(mac: "52:55:55:A:B:C", ip: "192.168.233.6")],
                      leaseTime: 80, now: { clock.read() })
    }

    private func handle(_ server: GuestOnlyDHCP, _ frame: [UInt8]) -> [UInt8]? {
        frame.withUnsafeBytes { server.handle($0) }
    }

    /// Options stay explicit so malformed packets can be built without sockets.
    private static func request(_ type: UInt8, mac: [UInt8] = first, requested: [UInt8]? = nil,
                                ciaddr: [UInt8] = [0, 0, 0, 0], broadcast: Bool = false,
                                hostname: String? = nil, extra: [UInt8] = []) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 236)
        body[0] = 1; body[1] = 1; body[2] = 6
        body.replaceSubrange(4..<8, with: [0x12, 0x34, 0x56, 0x78])
        body[10] = broadcast ? 0x80 : 0
        body.replaceSubrange(12..<16, with: ciaddr)
        body.replaceSubrange(28..<34, with: mac)
        body += [99, 130, 83, 99, 53, 1, type]
        if let requested { body += [50, 4] + requested }
        if let hostname { body += [12, UInt8(hostname.utf8.count)] + Array(hostname.utf8) }
        body += extra + [255]
        let udpLength = body.count + 8
        let total = udpLength + 20
        let ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 255), 0, 0, 0, 0, 64, 17, 0, 0,
                           0, 0, 0, 0, 255, 255, 255, 255]
        return [UInt8](repeating: 255, count: 6) + mac + [8, 0] + ip
            + [0, 68, 0, 67, UInt8(udpLength >> 8), UInt8(udpLength & 255), 0, 0] + body
    }

    private static func yiaddr(_ frame: [UInt8]) -> [UInt8] { Array(frame[(bootp + 16)..<(bootp + 20)]) }

    private static func options(_ frame: [UInt8]) -> [UInt8: [UInt8]] {
        var result: [UInt8: [UInt8]] = [:]
        var i = bootp + 240
        while i < frame.count {
            let code = frame[i]
            if code == 255 { break }
            if code == 0 { i += 1; continue }
            guard i + 1 < frame.count else { break }
            let count = Int(frame[i + 1])
            guard i + 2 + count <= frame.count else { break }
            result[code] = Array(frame[(i + 2)..<(i + 2 + count)])
            i += 2 + count
        }
        return result
    }

    @Test func offerRequestAndWireFormat() throws {
        let server = server()
        #expect(server.leases.isEmpty)
        let discover = Self.request(1, hostname: "lima-foo", extra: [61, 3, 1, 9, 9])
        let offer = try #require(handle(server, discover))
        let ip = Self.yiaddr(offer)
        #expect(ip == [192, 168, 233, 2])
        #expect(Self.options(offer)[53] == [2])
        #expect(Array(offer[0..<6]) == Self.first)
        #expect(Array(offer[6..<12]) == Self.serverMAC)
        #expect(Array(offer[26..<30]) == [192, 168, 233, 1])
        #expect(Array(offer[30..<34]) == ip)
        #expect(Array(offer[34..<38]) == [0, 67, 0, 68])
        #expect(Array(offer[40..<42]) == [0, 0])
        #expect(offer[42] == 2 && offer[43] == 1 && offer[44] == 6)
        #expect(Array(offer[46..<50]) == Array(discover[46..<50]))
        #expect(Array(offer[52..<58]) == Array(discover[52..<58]))
        #expect(Array(offer[62..<66]) == [192, 168, 233, 1])
        #expect(Array(offer[70..<86]) == Array(discover[70..<86]))
        #expect(Array(offer[278..<282]) == [99, 130, 83, 99])
        #expect(offer.count == 42 + 300)
        #expect(Int(offer[16]) << 8 | Int(offer[17]) == offer.count - 14)
        #expect(Int(offer[38]) << 8 | Int(offer[39]) == offer.count - 34)
        #expect(DHCPClientIDFilter.ipv4HeaderChecksum(offer[14..<34]) == UInt16(offer[24]) << 8 | UInt16(offer[25]))
        let options = Self.options(offer)
        #expect(Set(options.keys) == Set([1, 51, 53, 54, 58, 59]))
        #expect(options[3] == nil && options[6] == nil)
        #expect(options[54] == [192, 168, 233, 1])
        #expect(options[1] == [255, 255, 255, 248])
        #expect(options[51] == [0, 0, 0, 80])
        #expect(options[58] == [0, 0, 0, 40])
        #expect(options[59] == [0, 0, 0, 70])
        let again = try #require(handle(server, Self.request(1)))
        #expect(Self.yiaddr(again) == ip)
        let ack = try #require(handle(server, Self.request(3, requested: ip, extra: [54, 4, 192, 168, 233, 1])))
        #expect(Self.options(ack)[53] == [5])
        #expect(Self.yiaddr(ack) == ip)
        let renewal = try #require(handle(server, Self.request(3, ciaddr: ip)))
        #expect(Self.yiaddr(renewal) == ip)
        #expect(server.leases.first?.name == "lima-foo")
        let second = try #require(handle(server, Self.request(1, mac: Self.second)))
        #expect(Self.yiaddr(second) != ip)
    }

    @Test func reservationsBroadcastAndLeaseFile() throws {
        let clock = Clock()
        let server = server(clock: clock)
        #expect(server.leaseFileText().isEmpty)
        let offer = try #require(handle(server, Self.request(1, mac: Self.reserved, broadcast: true,
                                                           hostname: "lima-reserved", extra: [61, 3, 7, 8, 9])))
        #expect(Self.yiaddr(offer) == Self.fixedIP)
        #expect(Array(offer[0..<6]) == [UInt8](repeating: 255, count: 6))
        #expect(Array(offer[30..<34]) == [255, 255, 255, 255])
        #expect(offer[52] == 0x80)
        let ack = try #require(handle(server, Self.request(3, mac: Self.reserved, requested: Self.fixedIP)))
        #expect(Self.options(ack)[53] == [5])
        let parsed = DHCPLeases.parse(server.leaseFileText())
        #expect(parsed == server.leases)
        #expect(parsed.first?.ip == "192.168.233.6")
        #expect(parsed.first?.name == "lima-reserved")
        #expect(parsed.first?.hwAddress == "1,52:55:55:a:b:c")
        #expect(parsed.first?.expires == clock.read().addingTimeInterval(80))
        #expect(server.leaseFileText().contains("identifier=1,52:55:55:a:b:c"))
    }

    @Test func nakReleaseAndAssignableRequest() throws {
        let server = server()
        let offer = try #require(handle(server, Self.request(1)))
        let ip = Self.yiaddr(offer)
        _ = try #require(handle(server, Self.request(1, mac: Self.second)))
        let nak = try #require(handle(server, Self.request(3, requested: [192, 168, 233, 5])))
        #expect(Self.options(nak)[53] == [6])
        #expect(Self.yiaddr(nak) == [0, 0, 0, 0])
        #expect(handle(server, Self.request(7, ciaddr: ip)) == nil)
        #expect(server.leases.count == 1)
        let next = try #require(handle(server, Self.request(1, mac: Self.third)))
        #expect(Self.yiaddr(next) == ip)
        let fresh = self.server()
        let ack = try #require(handle(fresh, Self.request(3, requested: [192, 168, 233, 4])))
        #expect(Self.options(ack)[53] == [5])
        #expect(Self.yiaddr(ack) == [192, 168, 233, 4])
        let occupied = try #require(handle(fresh, Self.request(3, mac: Self.second, requested: [192, 168, 233, 4])))
        #expect(Self.options(occupied)[53] == [6])
        let reserved = try #require(handle(fresh, Self.request(3, mac: Self.second, requested: Self.fixedIP)))
        #expect(Self.options(reserved)[53] == [6])
    }

    @Test func expiryDeclineAndInform() throws {
        let clock = Clock()
        let server = server(clock: clock)
        let offer = try #require(handle(server, Self.request(1)))
        let ip = Self.yiaddr(offer)
        #expect(handle(server, Self.request(4, requested: ip)) == nil)
        #expect(server.leases.isEmpty)
        let second = try #require(handle(server, Self.request(1, mac: Self.second)))
        #expect(Self.yiaddr(second) != ip)
        clock.advance(79)
        #expect(server.leases.count == 1)
        clock.advance(1)
        #expect(server.leases.isEmpty)
        #expect(server.leaseFileText().isEmpty)
        let reused = try #require(handle(server, Self.request(1, mac: Self.third)))
        #expect(Self.yiaddr(reused) == ip)
        let inform = try #require(handle(server, Self.request(8, ciaddr: [192, 168, 233, 5])))
        #expect(Self.options(inform)[53] == [5])
        #expect(Self.yiaddr(inform) == [0, 0, 0, 0])
        #expect(Array(inform[30..<34]) == [192, 168, 233, 5])
        #expect(Self.options(inform)[3] == nil && Self.options(inform)[6] == nil)
        #expect(server.leases.count == 1)
    }

    private static func arp(target: [UInt8] = [192, 168, 233, 1]) -> [UInt8] {
        [UInt8](repeating: 255, count: 6) + first + [8, 6, 0, 1, 8, 0, 6, 4, 0, 1]
            + first + [192, 168, 233, 2] + [UInt8](repeating: 0, count: 6) + target
    }

    @Test func arpResponder() throws {
        let server = server()
        let out = try #require(handle(server, Self.arp()))
        #expect(Array(out[0..<6]) == Self.first)
        #expect(Array(out[6..<12]) == Self.serverMAC)
        #expect(Array(out[12..<22]) == [8, 6, 0, 1, 8, 0, 6, 4, 0, 2])
        #expect(Array(out[22..<28]) == Self.serverMAC)
        #expect(Array(out[28..<32]) == [192, 168, 233, 1])
        #expect(Array(out[32..<38]) == Self.first)
        #expect(Array(out[38..<42]) == [192, 168, 233, 2])
        #expect(handle(server, out) == nil)
        #expect(handle(server, Self.arp(target: [192, 168, 233, 2])) == nil)
        #expect(server.leases.isEmpty)
    }

    @Test func ignoresOtherTrafficAndMalformedFrames() {
        let server = server()
        #expect(handle(server, [UInt8](repeating: 0, count: 60)) == nil)
        for frame in [Self.request(1), Self.arp()] {
            for length in 0..<frame.count { #expect(handle(server, Array(frame.prefix(length))) == nil) }
        }
        let original = Self.request(1)
        for (offset, value): (Int, UInt8) in [(12, 0x86), (14, 0x44), (14, 0x4f), (23, 6), (20, 0x20),
                                           (21, 1), (35, 67), (37, 68), (38, 0xff), (39, 8), (42, 2),
                                           (43, 2), (44, 7), (278, 0)] {
            var malformed = original
            malformed[offset] = value
            #expect(handle(server, malformed) == nil)
        }
        #expect(handle(server, Self.request(1, extra: [12, 200, 1])) == nil)
        #expect(handle(server, Self.request(1, extra: [50, 1, 1])) == nil)
        #expect(handle(server, Self.request(1, extra: [54, 4, 192, 168, 233, 99])) == nil)
        #expect(handle(server, Self.request(2)) == nil)
        #expect(server.leases.isEmpty)
    }

    @Test func exhaustedAndTinyPools() throws {
        let server = server()
        for byte in UInt8(1)...4 {
            let offer = try #require(handle(server, Self.request(1, mac: [2, 0, 0, 0, 0, byte])))
            #expect(Self.yiaddr(offer).last == byte + 1)
        }
        #expect(handle(server, Self.request(1)) == nil)
        let fixed = try #require(handle(server, Self.request(1, mac: Self.reserved)))
        #expect(Self.yiaddr(fixed) == Self.fixedIP)
        for prefix in [31, 32] {
            let tiny = GuestOnlyDHCP(subnet: IPv4Subnet(containing: Self.serverIP, prefixLength: prefix),
                                     serverIP: Self.serverIP, serverMAC: Self.serverMAC, reservations: [])
            #expect(handle(tiny, Self.request(1)) == nil)
        }
    }

    @Test func concurrentAllocation() {
        let server = server()
        DispatchQueue.concurrentPerform(iterations: 40) { index in
            let frame = Self.request(1, mac: [2, 0, 0, 0, 0, UInt8(index)])
            _ = frame.withUnsafeBytes { server.handle($0) }
            _ = server.leases
            _ = server.leaseFileText()
        }
        #expect(server.leases.count == 4)
        #expect(Set(server.leases.map(\.ip)).count == 4)
    }
}
