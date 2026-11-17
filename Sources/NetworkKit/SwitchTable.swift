import Foundation

/// The decisions of a guest-only network's switch (docs/17, docs/18), apart from its sockets,
/// DHCP and capture: which port owns which MAC, where a frame goes, and what the faults do to
/// it. netd keeps one under its switch lock; ports are named by their connection number.
public struct SwitchTable: Sendable {
    /// One frame for one port, as a fault decided.
    public struct Delivery: Equatable, Sendable {
        public var port: Int
        public var verdict: FaultTable.Verdict
    }

    /// Learned MACs per port, so a guest spraying source addresses can't grow the table forever.
    public static let learnLimit = 32

    private var owners: [UInt64: Int] = [:]
    private var learned: [Int: Int] = [:]
    public var faults: FaultTable

    public init(faults: FaultTable = FaultTable()) { self.faults = faults }

    /// Notes that `mac` (a unicast source) is behind `port`.
    public mutating func learn(_ mac: UInt64, on port: Int) {
        guard mac & 0x0100_0000_0000 == 0, owners[mac] != port else { return }
        let count = learned[port, default: 0]
        guard count < Self.learnLimit else { return }
        owners[mac] = port
        learned[port] = count + 1
    }

    /// Forgets a port that disconnected; returns the MACs it had.
    @discardableResult
    public mutating func forget(_ port: Int) -> [String] {
        let macs = macs(of: port)
        owners = owners.filter { $0.value != port }
        learned[port] = nil
        return macs
    }

    /// The MACs learned on `port`, as text.
    public func macs(of port: Int) -> [String] {
        owners.filter { $0.value == port }.keys.sorted().map(Self.text)
    }

    /// Where a frame to `destination` from `source` goes, among the connected `ports`: the
    /// owner of a known unicast address (not back to the sender), else every other port, in
    /// order, each with its own verdict. `flooded` is true when it went to every other port.
    public func deliveries(to destination: UInt64, from source: Int, ports: [Int], now: ContinuousClock.Instant) -> (deliveries: [Delivery], flooded: Bool) {
        if destination & 0x0100_0000_0000 == 0, let owner = owners[destination] {
            guard owner != source, ports.contains(owner) else { return ([], false) }
            return ([Delivery(port: owner, verdict: verdict(for: owner, now: now))], false)
        }
        return (ports.filter { $0 != source }.sorted().map { Delivery(port: $0, verdict: verdict(for: $0, now: now)) }, true)
    }

    /// The fault in force for a port: one for the whole segment, or one for a MAC it learned.
    public func fault(for port: Int, now: ContinuousClock.Instant) -> NetworkFault.Spec? {
        guard !faults.isEmpty else { return nil }
        return faults.fault(at: now) { mac in Self.value(mac).map { owners[$0] == port } ?? false }
    }

    public func verdict(for port: Int, now: ContinuousClock.Instant) -> FaultTable.Verdict {
        faults.verdict(fault(for: port, now: now))
    }

    public func isBlocked(_ port: Int, now: ContinuousClock.Instant) -> Bool {
        fault(for: port, now: now)?.block == true
    }

    /// The ports among `ports` under a block now.
    public func blocked(among ports: [Int], now: ContinuousClock.Instant) -> [Int] {
        ports.filter { isBlocked($0, now: now) }
    }

    /// A MAC address in a frame (six bytes from `offset`).
    public static func mac(_ frame: UnsafeRawBufferPointer, at offset: Int) -> UInt64 {
        (0..<6).reduce(UInt64(0)) { $0 << 8 | UInt64(frame[offset + $1]) }
    }

    static func value(_ mac: String) -> UInt64? {
        let parts = mac.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var v: UInt64 = 0
        for p in parts {
            guard let b = UInt8(p, radix: 16) else { return nil }
            v = v << 8 | UInt64(b)
        }
        return v
    }

    static func text(_ v: UInt64) -> String {
        (0..<6).map { String(format: "%02x", UInt8(v >> (8 * (5 - $0)) & 0xff)) }.joined(separator: ":")
    }
}
