import Foundation
import Testing
@testable import NetworkKit

/// The guest-only switch's decisions (docs/17, docs/18): learning, destinations, faults.
@Suite struct SwitchTableTests {
    /// Random values handed out in order, so each loss decision is known.
    private final class Draws: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double]
        private(set) var used = 0
        init(_ values: [Double]) { self.values = values }
        func next() -> Double { lock.withLock { used += 1; return values.removeFirst() } }
    }

    private let a: UInt64 = 0x5255_5500_0001
    private let b: UInt64 = 0x5255_5500_0002
    private let broadcast: UInt64 = 0xffff_ffff_ffff
    private let now = ContinuousClock.now

    @Test func knownUnicastGoesToItsOwnerOnly() {
        var table = SwitchTable()
        table.learn(a, on: 1)
        table.learn(b, on: 2)
        let route = table.deliveries(to: b, from: 1, ports: [1, 2, 3], now: now)
        #expect(route.deliveries == [.init(port: 2, verdict: .pass(delay: .zero))] && !route.flooded)
        #expect(table.deliveries(to: a, from: 1, ports: [1, 2, 3], now: now).deliveries.isEmpty, "not back to the sender")
        #expect(table.deliveries(to: b, from: 1, ports: [1, 3], now: now).deliveries.isEmpty, "the owner disconnected")
    }

    /// docs/18 §8: a frame to every other port is decided for each destination on its own.
    @Test func floodedFramesGetAVerdictPerDestination() throws {
        let draws = Draws([0.1, 0.9, 0.2, 0.9])
        var table = SwitchTable(faults: FaultTable(random: { draws.next() }))
        _ = try table.faults.start(.init(target: NetworkFault.Spec.everyone, lossPercent: 50, seconds: 60), now: now)
        let route = table.deliveries(to: broadcast, from: 4, ports: [3, 1, 4, 2], now: now)
        #expect(route.flooded)
        #expect(route.deliveries == [.init(port: 1, verdict: .lost), .init(port: 2, verdict: .pass(delay: .zero)), .init(port: 3, verdict: .lost)],
                "in port order, one draw each")
        #expect(draws.used == 3)
        // An unknown unicast address floods the same way.
        let unknown = table.deliveries(to: 0x5255_5500_00ff, from: 4, ports: [1], now: now)
        #expect(unknown.flooded && unknown.deliveries.map(\.port) == [1])
    }

    @Test func learningIsCappedPerPortAndForgotten() {
        var table = SwitchTable()
        for i in 0..<(SwitchTable.learnLimit + 5) { table.learn(0x5255_5500_1000 + UInt64(i), on: 1) }
        #expect(table.macs(of: 1).count == SwitchTable.learnLimit)
        table.learn(0x0100_0000_0001, on: 2)  // a multicast source is never learned
        #expect(table.macs(of: 2).isEmpty)
        #expect(table.forget(1).count == SwitchTable.learnLimit && table.macs(of: 1).isEmpty)
    }

    @Test func aFaultByMACFollowsThePortThatLearnedIt() throws {
        var table = SwitchTable()
        _ = try table.faults.start(.init(target: "52:55:55:00:00:02", block: true, seconds: 60), now: now)
        #expect(!table.isBlocked(2, now: now), "nothing learned yet")
        table.learn(b, on: 2)
        #expect(table.isBlocked(2, now: now) && !table.isBlocked(1, now: now))
        #expect(table.blocked(among: [1, 2, 3], now: now) == [2])
        #expect(table.verdict(for: 2, now: now) == .blocked)
        // The VM reconnects: a new port learns the MAC and the fault follows.
        table.forget(2)
        table.learn(b, on: 5)
        #expect(table.blocked(among: [1, 5], now: now) == [5])
        #expect(!table.isBlocked(5, now: now + .seconds(61)), "expired")
    }

    @Test func macsReadAsText() {
        #expect(SwitchTable.value("52:55:55:0a:00:01") == 0x5255_550a_0001)
        #expect(SwitchTable.value("bad") == nil)
        #expect(SwitchTable.text(0x5255_550a_0001) == "52:55:55:0a:00:01")
        let frame: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x52, 0x55, 0x55, 0, 0, 1]
        frame.withUnsafeBytes { #expect(SwitchTable.mac($0, at: 6) == a) }
    }
}
