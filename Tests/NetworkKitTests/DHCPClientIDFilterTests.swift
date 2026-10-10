import Foundation
import Testing
@testable import NetworkKit

@Suite struct DHCPClientIDFilterTests {
    static let mac: [UInt8] = [0x52, 0x55, 0x55, 0xd3, 0xdd, 0x1f]

    /// Builds an Ethernet/IPv4/UDP DHCPDISCOVER with the given options (before the end option).
    static func discover(options: [UInt8], srcPort: UInt16 = 68, dstPort: UInt16 = 67) -> [UInt8] {
        var bootp = [UInt8](repeating: 0, count: 236)
        bootp[0] = 1; bootp[1] = 1; bootp[2] = 6
        bootp.replaceSubrange(28..<34, with: mac)
        bootp += [99, 130, 83, 99] + options + [255]
        let udpLen = 8 + bootp.count
        var udp: [UInt8] = [UInt8(srcPort >> 8), UInt8(srcPort & 0xff), UInt8(dstPort >> 8), UInt8(dstPort & 0xff),
                            UInt8(udpLen >> 8), UInt8(udpLen & 0xff), 0xab, 0xcd]
        udp += bootp
        let total = 20 + udp.count
        var ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0, 0, 0, 0, 64, 17, 0, 0,
                           0, 0, 0, 0, 255, 255, 255, 255]
        let sum = DHCPClientIDFilter.ipv4HeaderChecksum(ip[...])
        ip[10] = UInt8(sum >> 8); ip[11] = UInt8(sum & 0xff)
        return [255, 255, 255, 255, 255, 255] + mac + [0x08, 0x00] + ip + udp
    }

    static let clientID: [UInt8] = [61, 13, 255, 0x55, 0xd3, 0xdd, 0x1f, 0, 1, 0, 1, 0x32, 0x5b, 0x59, 0x80]
    static let messageType: [UInt8] = [53, 1, 1]
    static let paramList: [UInt8] = [55, 3, 1, 3, 6]

    func filter(_ frame: [UInt8]) -> [UInt8]? {
        frame.withUnsafeBytes { DHCPClientIDFilter.strippingClientIdentifier(from: $0) }
    }

    @Test func removesOption61AndFixesHeaders() throws {
        let original = Self.discover(options: Self.messageType + Self.clientID + Self.paramList)
        let out = try #require(filter(original))
        #expect(out.count == original.count - Self.clientID.count)
        #expect(out == Self.discover(options: Self.messageType + Self.paramList).enumerated().map { i, b in
            // UDP checksum is zeroed by the filter.
            (i == 14 + 20 + 6 || i == 14 + 20 + 7) ? 0 : b
        })
        // IPv4 header checksum verifies.
        let header = Array(out[14..<34])
        #expect(DHCPClientIDFilter.ipv4HeaderChecksum(header[...]) == UInt16(header[10]) << 8 | UInt16(header[11]))
        let total = Int(out[16]) << 8 | Int(out[17])
        #expect(total == out.count - 14)
        let udpLen = Int(out[38]) << 8 | Int(out[39])
        #expect(udpLen == total - 20)
    }

    @Test func handlesPadOptions() throws {
        let original = Self.discover(options: [0, 0] + Self.clientID + Self.messageType)
        let out = try #require(filter(original))
        #expect(!out.contains(sequence: Self.clientID))
    }

    @Test func leavesOtherTrafficAlone() {
        #expect(filter(Self.discover(options: Self.messageType + Self.paramList)) == nil) // no option 61
        #expect(filter(Self.discover(options: Self.clientID, srcPort: 67, dstPort: 68)) == nil) // server reply
        var arp = Self.discover(options: Self.clientID)
        arp[12] = 0x08; arp[13] = 0x06
        #expect(filter(arp) == nil)
        #expect(filter([UInt8](repeating: 0, count: 60)) == nil)
    }

    @Test func rejectsTruncatedOptions() {
        var frame = Self.discover(options: Self.messageType + [61, 200, 1, 2])
        frame.removeLast() // drop the end option so the bogus length runs off the packet
        #expect(filter(frame) == nil)
    }

    @Test func extractsSourceMAC() {
        let frame = Self.discover(options: [])
        #expect(frame.withUnsafeBytes { DHCPClientIDFilter.sourceMAC(of: $0) } == "52:55:55:d3:dd:1f")
    }

    @Test func normalizesMACs() {
        #expect(DHCPReservation.normalizedMAC("52:55:55:D3:DD:1F") == "52:55:55:d3:dd:1f")
        #expect(DHCPReservation.normalizedMAC("2:0:0:0:0:a") == "02:00:00:00:00:0a")
        #expect(DHCPReservation.normalizedMAC("52-55-55-d3-dd-1f") == nil)
        #expect(DHCPReservation.normalizedMAC("52:55:55:d3:dd") == nil)
    }

    @Test func validatesReservations() {
        var n = VirtualNetwork(name: "dev", gateway: "192.168.200.1")
        n.reservations = [DHCPReservation(mac: "52:55:55:00:00:01", ip: "192.168.200.50")]
        #expect(n.validate(against: []).isEmpty)
        n.reservations.append(DHCPReservation(mac: "52:55:55:00:00:01", ip: "192.168.200.1"))
        let errors = n.validate(against: [])
        #expect(errors.count == 2) // duplicate MAC + gateway address
        n.reservations = [DHCPReservation(mac: "x", ip: "192.168.200.9")]
        #expect(n.validate(against: []).count == 1)
    }

    @Test func decodesNetworksWithoutReservations() throws {
        let json = #"{"name":"a","mode":"shared","gateway":"192.168.200.1","prefixLength":24,"comment":""}"#
        let n = try JSONDecoder().decode(VirtualNetwork.self, from: Data(json.utf8))
        #expect(n.reservations.isEmpty)
    }
}

private extension Array where Element == UInt8 {
    func contains(sequence: [UInt8]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}
