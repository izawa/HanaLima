import Foundation

/// Makes vmnet DHCP reservations work for any guest OS.
///
/// vmnet matches reservations by MAC address, but its DHCP server (bootpd) identifies a client
/// by the DHCP client identifier (option 61) when one is sent, and most current Linux DHCP
/// clients (dhcpcd, systemd-networkd, …) send an RFC 4361 DUID-based identifier by default. For
/// guests with a reservation, hanalima-netd removes option 61 from their DHCP requests so bootpd
/// falls back to the hardware address and the reservation applies. Replies then carry no client
/// identifier, which clients accept (RFC 6842 only requires echoing one that was received).
public enum DHCPClientIDFilter {
    /// If `frame` is an Ethernet/IPv4/UDP DHCP request (client port 68 → server port 67) that
    /// carries option 61, returns a copy without it, with IPv4/UDP lengths and the IPv4 header
    /// checksum fixed up (the UDP checksum is set to 0, which IPv4 permits). Otherwise nil.
    public static func strippingClientIdentifier(from frame: UnsafeRawBufferPointer) -> [UInt8]? {
        let ethHeader = 14
        guard frame.count >= ethHeader + 20 + 8 + 240 else { return nil }
        // EtherType IPv4 (no VLAN tags on these links).
        guard frame[12] == 0x08, frame[13] == 0x00 else { return nil }
        let ip = ethHeader
        guard frame[ip] >> 4 == 4 else { return nil }
        let ipHeaderLength = Int(frame[ip] & 0x0f) * 4
        guard ipHeaderLength >= 20, frame[ip + 9] == 17 else { return nil } // UDP
        // Fragmented packets are not DHCP-sized; skip them.
        guard frame[ip + 6] & 0x3f == 0, frame[ip + 7] == 0 else { return nil }
        let ipTotalLength = Int(frame[ip + 2]) << 8 | Int(frame[ip + 3])
        guard ipTotalLength >= ipHeaderLength + 8, ip + ipTotalLength <= frame.count else { return nil }
        let udp = ip + ipHeaderLength
        let srcPort = Int(frame[udp]) << 8 | Int(frame[udp + 1])
        let dstPort = Int(frame[udp + 2]) << 8 | Int(frame[udp + 3])
        guard srcPort == 68, dstPort == 67 else { return nil }
        let bootp = udp + 8
        let end = ip + ipTotalLength
        // op = BOOTREQUEST, magic cookie 99.130.83.99 at offset 236.
        let cookie = bootp + 236
        guard bootp < end, frame[bootp] == 1, cookie + 4 <= end,
              frame[cookie] == 99, frame[cookie + 1] == 130, frame[cookie + 2] == 83, frame[cookie + 3] == 99 else {
            return nil
        }

        // Walk the options to find option 61.
        var i = cookie + 4
        var found: Range<Int>?
        while i < end {
            let code = frame[i]
            if code == 255 { break }
            if code == 0 { i += 1; continue }
            guard i + 1 < end else { return nil }
            let len = Int(frame[i + 1])
            guard i + 2 + len <= end else { return nil }
            if code == 61 { found = i..<(i + 2 + len); break }
            i += 2 + len
        }
        guard let removed = found else { return nil }

        var out = [UInt8](frame[0..<removed.lowerBound])
        out += frame[removed.upperBound..<frame.count]
        let newTotal = ipTotalLength - removed.count
        out[ip + 2] = UInt8(newTotal >> 8)
        out[ip + 3] = UInt8(newTotal & 0xff)
        let udpLength = newTotal - ipHeaderLength
        out[udp + 4] = UInt8(udpLength >> 8)
        out[udp + 5] = UInt8(udpLength & 0xff)
        out[udp + 6] = 0
        out[udp + 7] = 0
        let sum = ipv4HeaderChecksum(out[ip..<(ip + ipHeaderLength)])
        out[ip + 10] = UInt8(sum >> 8)
        out[ip + 11] = UInt8(sum & 0xff)
        return out
    }

    /// Source MAC of an Ethernet frame as "aa:bb:cc:dd:ee:ff".
    public static func sourceMAC(of frame: UnsafeRawBufferPointer) -> String? {
        guard frame.count >= 12 else { return nil }
        return (6..<12).map { String(format: "%02x", frame[$0]) }.joined(separator: ":")
    }

    /// RFC 1071 checksum over the header with the checksum field treated as zero.
    static func ipv4HeaderChecksum(_ header: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt32 = 0
        let bytes = Array(header)
        for i in stride(from: 0, to: bytes.count, by: 2) where i != 10 {
            sum += UInt32(bytes[i]) << 8 | UInt32(i + 1 < bytes.count ? bytes[i + 1] : 0)
        }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
