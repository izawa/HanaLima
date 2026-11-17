import Foundation
import Testing
@testable import NetworkKit

struct FaultTests {
    private let mac = "02:00:00:00:00:0a"
    private let otherMAC = "02:00:00:00:00:0b"

    @Test(arguments: [
        ("52:55:55:D3:DD:1F", "52:55:55:d3:dd:1f"),
        ("2:0:0:0:0:A", "02:00:00:00:00:0a"),
        ("*", "*"),
    ])
    func validatesTarget(target: String, normalized: String) throws {
        let spec = try NetworkFault.Spec(target: target, delayMs: 1, seconds: 1).validated()
        #expect(spec.target == normalized)
    }

    @Test(arguments: [1, 1800])
    func acceptsSecondsBoundary(seconds: Int) throws {
        let spec = try NetworkFault.Spec(target: mac, delayMs: 1, seconds: seconds).validated()
        #expect(spec.seconds == seconds)
    }

    @Test(arguments: [0, 1801])
    func refusesSecondsOutOfRange(seconds: Int) {
        #expect(throws: NetdControl.Failure.self) {
            try NetworkFault.Spec(target: mac, delayMs: 1, seconds: seconds).validated()
        }
    }

    @Test func refusesInvalidEffects() {
        let specs: [NetworkFault.Spec] = [
            .init(target: mac, delayMs: 5001, seconds: 1),
            .init(target: mac, lossPercent: 100.1, seconds: 1),
            .init(target: mac, delayMs: 1, block: true, seconds: 1),
            .init(target: mac, lossPercent: 1, block: true, seconds: 1),
            .init(target: mac, seconds: 1),
        ]
        for spec in specs {
            #expect(throws: NetdControl.Failure.self) { try spec.validated() }
        }
    }

    @Test func startAssignsIdentityAndExpiration() throws {
        var table = FaultTable()
        let now = ContinuousClock.now
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let spec = NetworkFault.Spec(target: mac, delayMs: 100, seconds: 10)
        let fault = try table.start(spec, now: now, date: date)
        #expect(!fault.id.isEmpty)
        #expect(fault.spec == spec)
        #expect(fault.startedAt == date)
        #expect(fault.expiresAt == fault.startedAt.addingTimeInterval(10))
        #expect(table.faults(at: now) == [fault])
    }

    @Test func refusesDuplicateAndOverlappingTargets() throws {
        var table = FaultTable()
        let now = ContinuousClock.now
        let first = try table.start(.init(target: mac, delayMs: 1, seconds: 10), now: now)
        #expect(throws: NetdControl.Failure.self) {
            try table.start(.init(target: "2:0:0:0:0:A", block: true, seconds: 10), now: now)
        }
        #expect(throws: NetdControl.Failure.self) {
            try table.start(.init(target: "*", block: true, seconds: 10), now: now)
        }
        let second = try table.start(.init(target: otherMAC, block: true, seconds: 10), now: now)
        #expect(table.faults(at: now) == [first, second])

        var segment = FaultTable()
        let all = try segment.start(.init(target: "*", block: true, seconds: 10), now: now)
        #expect(throws: NetdControl.Failure.self) {
            try segment.start(.init(target: mac, delayMs: 1, seconds: 10), now: now)
        }
        #expect(segment.faults(at: now) == [all])
    }

    @Test func stopsOneOrAllAndRefusesUnknownID() throws {
        var table = FaultTable()
        let now = ContinuousClock.now
        let first = try table.start(.init(target: mac, delayMs: 1, seconds: 10), now: now)
        let second = try table.start(.init(target: otherMAC, delayMs: 1, seconds: 10), now: now)
        #expect(try table.stop(id: first.id) == [first])
        #expect(table.faults(at: now) == [second])
        #expect(throws: NetdControl.Failure.self) { try table.stop(id: "unknown") }
        #expect(table.faults(at: now) == [second])
        let restarted = try table.start(first.spec, now: now)
        #expect(try table.stop(id: nil) == [second, restarted])
        #expect(table.isEmpty)
    }

    @Test func expiresAtDeadlineAndHidesExpiredFaults() throws {
        var table = FaultTable()
        let now = ContinuousClock.now
        let first = try table.start(.init(target: mac, delayMs: 1, seconds: 2), now: now)
        let second = try table.start(.init(target: otherMAC, delayMs: 1, seconds: 3), now: now)
        #expect(table.faults(at: now + .seconds(1)) == [first, second])
        #expect(table.expire(now + .seconds(1)) == false)
        #expect(table.faults(at: now + .seconds(2)) == [second])
        #expect(table.expire(now + .seconds(2)) == true)
        #expect(table.expire(now + .seconds(2)) == false)
        #expect(table.expire(now + .seconds(3)) == true)
        #expect(table.isEmpty)
    }

    @Test func firstStartedOwnedMACWinsUntilDeadline() throws {
        var table = FaultTable()
        let now = ContinuousClock.now
        let first = try table.start(.init(target: mac, delayMs: 1, seconds: 2), now: now)
        let second = try table.start(.init(target: otherMAC, delayMs: 2, seconds: 3), now: now)
        #expect(table.fault(at: now, owns: { _ in true }) == first.spec)
        #expect(table.fault(at: now, owns: { $0 == otherMAC }) == second.spec)
        #expect(table.fault(at: now, owns: { _ in false }) == nil)
        #expect(table.fault(at: now + .seconds(2), owns: { _ in true }) == second.spec)
        #expect(table.fault(at: now + .seconds(3), owns: { _ in true }) == nil)
        #expect(table.fault(at: now + .seconds(4), owns: { _ in true }) == nil)
    }

    @Test func segmentMatchesWithoutOwnedMACs() throws {
        var table = FaultTable()
        let now = ContinuousClock.now
        let fault = try table.start(.init(target: "*", block: true, seconds: 1), now: now)
        #expect(table.fault(at: now, owns: { _ in false }) == fault.spec)
        #expect(table.fault(at: now + .seconds(1), owns: { _ in true }) == nil)
    }

    @Test func verdictUsesInjectedRandomAndPassesDelay() {
        let table = FaultTable(random: { 0.3 })
        #expect(table.verdict(nil) == .pass(delay: .zero))
        #expect(table.verdict(.init(target: mac, block: true, seconds: 1)) == .blocked)
        #expect(table.verdict(.init(target: mac, delayMs: 123, lossPercent: 50, seconds: 1)) == .lost)
        #expect(table.verdict(.init(target: mac, delayMs: 123, lossPercent: 20, seconds: 1)) == .pass(delay: .milliseconds(123)))
        #expect(table.verdict(.init(target: mac, delayMs: 5000, seconds: 1)) == .pass(delay: .milliseconds(5000)))
    }

    @Test(arguments: [0.0, 0.3, 0.999999])
    func lossExtremes(random: Double) {
        let table = FaultTable(random: { random })
        #expect(table.verdict(.init(target: mac, delayMs: 1, lossPercent: 0, seconds: 1)) == .pass(delay: .milliseconds(1)))
        #expect(table.verdict(.init(target: mac, lossPercent: 100, seconds: 1)) == .lost)
    }

    @Test func delayLineTracksFramesAndPopsInOrderAtDueTime() {
        var line = DelayLine()
        let now = ContinuousClock.now
        let due = now + .seconds(1)
        #expect(line.isEmpty && line.count == 0 && line.bytes == 0)
        #expect(line.nextDue == nil)
        #expect(line.push([1, 2], due: due) == true)
        #expect(line.push([3], due: due) == true)
        #expect(line.push([4, 5, 6], due: now + .seconds(2)) == true)
        #expect(!line.isEmpty && line.count == 3 && line.bytes == 6)
        #expect(line.nextDue == due)
        #expect(line.popDue(due - .nanoseconds(1)).isEmpty)
        #expect(line.count == 3 && line.bytes == 6)
        #expect(line.popDue(due) == [[1, 2], [3]])
        #expect(line.count == 1 && line.bytes == 3)
        #expect(line.nextDue == now + .seconds(2))
        #expect(line.popDue(now + .seconds(2)) == [[4, 5, 6]])
        #expect(line.isEmpty && line.count == 0 && line.bytes == 0)
        #expect(line.nextDue == nil)
    }

    @Test func shorterDelayCannotOvertakePredecessor() {
        var line = DelayLine()
        let now = ContinuousClock.now
        #expect(line.push([1], due: now + .seconds(3)) == true)
        let later = now + .seconds(1)
        #expect(line.push([2], due: later + .milliseconds(100)) == true)
        #expect(line.popDue(later + .milliseconds(100)).isEmpty)
        #expect(line.popDue(now + .seconds(3) - .nanoseconds(1)).isEmpty)
        #expect(line.nextDue == now + .seconds(3))
        #expect(line.popDue(now + .seconds(3)) == [[1], [2]])
    }

    @Test func overflowPreservesBufferedBytesAndFrames() {
        var line = DelayLine(capacity: 3)
        let now = ContinuousClock.now
        #expect(line.push([1, 2], due: now) == true)
        #expect(line.push([3, 4], due: now + .seconds(10)) == false)
        #expect(line.bytes == 2 && line.count == 1)
        #expect(line.nextDue == now)
        #expect(line.push([5], due: now) == true)
        #expect(line.bytes == 3 && line.count == 2)
        #expect(line.popDue(now) == [[1, 2], [5]])
    }

    @Test func removeAllResetsDelayAndPreservesCapacity() {
        var line = DelayLine(capacity: 4)
        let now = ContinuousClock.now
        #expect(line.push([0], due: now) == true)
        #expect(line.push([1, 2], due: now + .seconds(10)) == true)
        #expect(line.popDue(now) == [[0]])
        #expect(line.removeAll() == [[1, 2]])
        #expect(line.isEmpty && line.count == 0 && line.bytes == 0)
        #expect(line.nextDue == nil)
        #expect(line.capacity == 4)
        #expect(line.push([3], due: now) == true)
        #expect(line.nextDue == now)
        #expect(line.popDue(now) == [[3]])
    }

    @Test func olderPortJSONDefaultsFaultCountersToZero() throws {
        var port = NetworkObservation.Port(id: 1, macs: [mac], connectedAt: Date(timeIntervalSince1970: 100))
        port.fromGuest = .init(frames: 2, bytes: 120)
        port.droppedLoss = .init(frames: 1, bytes: 60)
        port.droppedBlocked = port.droppedLoss
        port.droppedOverflow = port.droppedLoss
        port.delayed = port.droppedLoss
        let encoded = try JSONEncoder().encode(port)
        #expect(try JSONDecoder().decode(NetworkObservation.Port.self, from: encoded) == port)
        var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["droppedLoss", "droppedBlocked", "droppedOverflow", "delayed"] {
            #expect(json.removeValue(forKey: key) != nil)
        }
        let decoded = try JSONDecoder().decode(NetworkObservation.Port.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.droppedLoss == .init())
        #expect(decoded.droppedBlocked == .init())
        #expect(decoded.droppedOverflow == .init())
        #expect(decoded.delayed == .init())
        #expect(decoded.fromGuest == port.fromGuest)
        #expect(decoded.id == port.id && decoded.macs == port.macs)
    }

    @Test func observationDecodesOptionalFaultCapabilities() throws {
        let observation = NetworkObservation(runID: "run", sequence: 1, sampledAt: Date(timeIntervalSince1970: 100), uptime: 1, ports: [])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
        json.removeValue(forKey: "faults")
        json.removeValue(forKey: "capabilities")
        let old = try JSONDecoder().decode(NetworkObservation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.faults == nil && old.capabilities == nil)
        #expect(!old.supportsFaults)

        json["capabilities"] = ["faults"]
        let current = try JSONDecoder().decode(NetworkObservation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(current.capabilities == ["faults"])
        #expect(current.supportsFaults)
    }

    @Test func popDueStopsAtTheLimitAndKeepsTheRest() {
        var line = DelayLine()
        let now = ContinuousClock.now
        for i in 0..<5 { let kept = line.push([UInt8(i)], due: now); #expect(kept) }
        let first = line.popDue(now, limit: 2)
        #expect(first == [[0], [1]])
        #expect(line.count == 3)
        let rest = line.popDue(now)
        #expect(rest == [[2], [3], [4]])
    }

    @Test func specDecodesWithTheUnusedEffectsLeftOut() throws {
        let block = try JSONDecoder().decode(NetworkFault.Spec.self, from: Data(#"{"target":"*","block":true,"seconds":30}"#.utf8))
        #expect(block == .init(target: "*", block: true, seconds: 30))
        let delay = try JSONDecoder().decode(NetworkFault.Spec.self, from: Data(#"{"target":"52:55:55:00:00:01","delayMs":100,"seconds":60}"#.utf8))
        #expect(delay == .init(target: "52:55:55:00:00:01", delayMs: 100, seconds: 60))
    }
}
