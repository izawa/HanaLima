import Foundation
import Testing
@testable import NetworkKit

/// The queues and counters of one guest-only connection (docs/17, docs/18), driven the way netd's
/// writer drives them, with no socket or thread.
@Suite struct GuestPortTests {
    private final class Wakes: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func hit() { lock.withLock { n += 1 } }
    }

    private func port(delayCapacity: Int = DelayLine.capacity) -> (GuestPort, Wakes) {
        let wakes = Wakes()
        return (GuestPort(id: 1, delayCapacity: delayCapacity) { wakes.hit() }, wakes)
    }

    private func frame(_ n: Int, bytes: Int = 60) -> [UInt8] { [UInt8(n & 0xff), UInt8(n >> 8 & 0xff)] + [UInt8](repeating: 0, count: bytes - 2) }

    /// Writes everything the port hands out at `now`, all successfully; returns what was written.
    private func drain(_ port: GuestPort, at now: ContinuousClock.Instant) -> [[UInt8]] {
        var written: [[UInt8]] = []
        while case .write(let f) = port.nextWrite(now: now) {
            port.completeWrite(f, ok: true)
            written.append(f)
        }
        return written
    }

    @Test func oneWakeCoversFramesUntilTheWriterWaitsAgain() {
        let (port, wakes) = port()
        let now = ContinuousClock.now
        port.deliver(frame(1), .pass(delay: .zero), now: now)
        port.deliver(frame(2), .pass(delay: .zero), now: now)
        #expect(wakes.count == 1, "one wake for a burst")
        #expect(drain(port, at: now) == [frame(1), frame(2)])
        #expect(port.nextWrite(now: now) == .wait(until: nil))
        port.deliver(frame(3), .pass(delay: .zero), now: now)
        #expect(wakes.count == 2, "the writer waits again, so the next frame wakes it")
        let counters = port.snapshot(macs: [], connected: true)
        #expect(counters.toGuest == .init(frames: 2, bytes: 120))
    }

    @Test func lossAndBlockAreCountedNotQueued() {
        let (port, _) = port()
        port.deliver(frame(1), .lost)
        port.deliver(frame(2), .blocked)
        let c = port.snapshot(macs: [], connected: true)
        #expect(c.droppedLoss == .init(frames: 1, bytes: 60) && c.droppedBlocked == .init(frames: 1, bytes: 60))
        #expect(port.nextWrite(now: .now) == .wait(until: nil))
    }

    /// docs/18 §8: after a fault is removed, more than 512 frames can be due at once; only as many
    /// as the send queue has room for move, the rest wait, and a reading guest loses nothing.
    @Test func manyFramesDueAtOnceAreNotDropped() {
        let (port, _) = port()
        let t0 = ContinuousClock.now
        for i in 0..<1024 { port.deliver(frame(i), .pass(delay: .milliseconds(100)), now: t0) }
        // The fault is gone; new frames still queue behind the delayed ones.
        for i in 1024..<1027 { port.deliver(frame(i), .pass(delay: .zero), now: t0 + .milliseconds(10)) }
        #expect(port.nextWrite(now: t0 + .milliseconds(50)) == .wait(until: t0 + .milliseconds(100)), "nothing before its time")

        let due = t0 + .milliseconds(100)
        guard case .write(let first) = port.nextWrite(now: due) else { Issue.record("expected a frame"); return }
        port.completeWrite(first, ok: true)
        #expect(port.snapshot(macs: [], connected: true).delayed.frames == UInt64(1027 - GuestPort.sendLimit), "the rest still wait in the line")

        let written = [first] + drain(port, at: due)
        #expect(written == (0..<1027).map { frame($0) }, "all of them, in order")
        let c = port.snapshot(macs: [], connected: true)
        #expect(c.droppedFull.frames == 0 && c.droppedOverflow.frames == 0 && c.delayed.frames == 0)
        #expect(c.toGuest.frames == 1027)
    }

    /// docs/18 §8: a port whose guest stops reading fills only its own delay line.
    @Test func aPortNotReadFillsOnlyItsOwnLine() {
        let (stuck, _) = port(delayCapacity: 600)
        let (reading, _) = port(delayCapacity: 600)
        let t0 = ContinuousClock.now
        for i in 0..<20 {
            stuck.deliver(frame(i), .pass(delay: .milliseconds(100)), now: t0)
            reading.deliver(frame(i), .pass(delay: .milliseconds(100)), now: t0)
            _ = drain(reading, at: t0 + .milliseconds(100) + .milliseconds(i))  // only this writer runs
        }
        let s = stuck.snapshot(macs: [], connected: true)
        let r = reading.snapshot(macs: [], connected: true)
        #expect(s.droppedOverflow.frames == 10 && s.delayed.frames == 10, "600 bytes hold ten frames")
        #expect(r.droppedOverflow.frames == 0 && r.toGuest.frames == 20)
    }

    /// docs/18 §8: a disconnect drops what still waits, delay line included, as closed, once.
    @Test func closingDropsTheWaitingFramesAsClosed() {
        let (port, wakes) = port()
        let t0 = ContinuousClock.now
        port.deliver(frame(1), .pass(delay: .zero), now: t0)
        port.deliver(frame(2), .pass(delay: .seconds(5)), now: t0)
        port.deliver(frame(3), .pass(delay: .seconds(5)), now: t0)
        port.close()
        #expect(wakes.count == 2, "close wakes the writer")
        port.deliver(frame(4), .pass(delay: .zero), now: t0)
        #expect(port.nextWrite(now: t0) == .finished)
        #expect(port.nextWrite(now: t0) == .finished, "again: nothing more to count")
        let c = port.snapshot(macs: ["52:55:55:00:00:01"], connected: false)
        #expect(c.droppedClosed == .init(frames: 4, bytes: 240), "three that waited and one after the close")
        #expect(c.delayed.frames == 0 && !c.connected && c.macs == ["52:55:55:00:00:01"])
    }

    @Test func aFailedWriteDropsItAndTheRestOnce() {
        let (port, _) = port()
        let t0 = ContinuousClock.now
        for i in 0..<3 { port.deliver(frame(i), .pass(delay: .zero), now: t0) }
        port.deliver(frame(3), .pass(delay: .seconds(1)), now: t0)
        guard case .write(let f) = port.nextWrite(now: t0) else { Issue.record("expected a frame"); return }
        port.completeWrite(f, ok: false)
        #expect(port.nextWrite(now: t0) == .finished)
        port.close()
        #expect(port.nextWrite(now: t0) == .finished)
        let c = port.snapshot(macs: [], connected: false)
        #expect(c.droppedClosed.frames == 4 && c.toGuest.frames == 0)
    }

    @Test func aBlockEmptiesBothQueues() {
        let (port, _) = port()
        let t0 = ContinuousClock.now
        port.deliver(frame(1), .pass(delay: .zero), now: t0)
        port.deliver(frame(2), .pass(delay: .seconds(1)), now: t0)
        port.purgeForBlock()
        let c = port.snapshot(macs: [], connected: true)
        #expect(c.droppedBlocked.frames == 2 && c.delayed.frames == 0 && c.droppedClosed.frames == 0)
        #expect(port.nextWrite(now: t0 + .seconds(2)) == .wait(until: nil))
    }

    @Test func aFullSendQueueDrops() {
        let (port, _) = port()
        for i in 0..<(GuestPort.sendLimit + 2) { port.deliver(frame(i), .pass(delay: .zero)) }
        let c = port.snapshot(macs: [], connected: true)
        #expect(c.droppedFull.frames == 2 && port.droppedFullCount == 2)
    }
}
