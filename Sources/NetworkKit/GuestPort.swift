import Foundation

/// One connection to a guest-only network's switch (a VM's NIC), without its socket: the frames
/// waiting for the VM and what the port counted (docs/17, docs/18). netd's relay writes what
/// `nextWrite` hands out, reports with `completeWrite`, and waits when told to; `wake` (called
/// outside the locks) tells its writer to look again.
///
/// Locks: `stats` may be taken while the switch's lock is held, and `queue` inside `stats` (for a
/// snapshot), never the other way round.
public final class GuestPort: @unchecked Sendable {
    /// Frames waiting to be written; when full, the VM isn't reading and new frames are dropped.
    public static let sendLimit = 512

    /// What the writer does next.
    public enum Step: Equatable, Sendable {
        case write([UInt8])
        /// Nothing to write: wait for `wake`, or until the next delayed frame is due.
        case wait(until: ContinuousClock.Instant?)
        /// Closed: the writer ends.
        case finished
    }

    public let id: Int
    private let wake: @Sendable () -> Void

    private let queue = NSLock()
    private var outgoing: [[UInt8]] = []
    /// Frames waiting out a fault's delay, apart from `outgoing` so its limit still means "the
    /// VM isn't reading".
    private var delayLine: DelayLine
    private var closed = false
    /// A wakeup is pending (one covers any number of frames); cleared when the writer is about to wait.
    private var wakePending = false
    private var fullDrops = 0

    private let stats = NSLock()
    private var counters: NetworkObservation.Port

    public init(id: Int, connectedAt: Date = .now, delayCapacity: Int = DelayLine.capacity, wake: @escaping @Sendable () -> Void) {
        self.id = id
        self.wake = wake
        delayLine = DelayLine(capacity: delayCapacity)
        counters = NetworkObservation.Port(id: id, connectedAt: connectedAt)
    }

    /// Frames dropped because the send queue was full (for the disconnect log line).
    public var droppedFullCount: Int { queue.withLock { fullDrops } }

    /// A frame of `length` bytes came from the guest.
    public func received(_ length: Int) {
        stats.withLock {
            counters.fromGuest.add(length)
            if length < 14 { counters.malformed += 1 }
        }
    }

    public func count(_ counter: WritableKeyPath<NetworkObservation.Port, NetworkObservation.Counter>, _ length: Int) {
        stats.withLock { counters[keyPath: counter].add(length) }
    }

    /// Hands a frame for this VM over as a fault decided: lost, blocked, or queued (delayed).
    public func deliver(_ frame: [UInt8], _ verdict: FaultTable.Verdict, now: ContinuousClock.Instant = .now) {
        switch verdict {
        case .pass(let delay): enqueue(frame, delay: delay, now: now)
        case .lost: count(\.droppedLoss, frame.count)
        case .blocked: count(\.droppedBlocked, frame.count)
        }
    }

    /// A frame with a delay, or any frame while delayed ones wait, goes through the delay line,
    /// so none overtakes another.
    private func enqueue(_ frame: [UInt8], delay: Duration, now: ContinuousClock.Instant) {
        enum Outcome { case queued(signal: Bool), full, closed, overflow }
        let outcome: Outcome = queue.withLock {
            guard !closed else { return .closed }
            if delay > .zero || !delayLine.isEmpty {
                guard delayLine.push(frame, due: now + delay) else { return .overflow }
            } else {
                guard outgoing.count < Self.sendLimit else { fullDrops += 1; return .full }
                outgoing.append(frame)
            }
            let signal = !wakePending
            wakePending = true
            return .queued(signal: signal)
        }
        switch outcome {
        case .queued(let signal): if signal { wake() }
        case .full: count(\.droppedFull, frame.count)
        case .closed: count(\.droppedClosed, frame.count)
        case .overflow: count(\.droppedOverflow, frame.count)
        }
    }

    /// A block started: what waits for this VM is dropped (as blocked).
    public func purgeForBlock() {
        let gone: [[UInt8]] = queue.withLock {
            defer { outgoing.removeAll() }
            return outgoing + delayLine.removeAll()
        }
        stats.withLock { for f in gone { counters.droppedBlocked.add(f.count) } }
    }

    /// No more frames: the writer drops what is left (as closed) and finishes.
    public func close() {
        queue.withLock { closed = true }
        wake()
    }

    /// The next step for the writer. Delayed frames whose time came join the send queue as far
    /// as it has room; the rest wait in the line (the VM may simply not have caught up yet).
    public func nextWrite(now: ContinuousClock.Instant = .now) -> Step {
        var discarded: [[UInt8]] = []
        let step: Step = queue.withLock {
            if closed {
                discarded = outgoing + delayLine.removeAll()
                outgoing.removeAll()
                return .finished
            }
            outgoing += delayLine.popDue(now, limit: Self.sendLimit - outgoing.count)
            if outgoing.isEmpty {
                wakePending = false  // about to wait: the next frame signals
                return .wait(until: delayLine.nextDue)
            }
            return .write(outgoing.removeFirst())
        }
        countClosed(discarded)
        return step
    }

    /// The writer's report on a frame `nextWrite` handed out. A failed write means the VM went
    /// away: that frame and all that waits are dropped (as closed) and the port closes.
    public func completeWrite(_ frame: [UInt8], ok: Bool) {
        if ok {
            count(\.toGuest, frame.count)
            return
        }
        let rest: [[UInt8]] = queue.withLock {
            closed = true
            defer { outgoing.removeAll() }
            return outgoing + delayLine.removeAll()
        }
        countClosed([frame] + rest)
    }

    private func countClosed(_ frames: [[UInt8]]) {
        guard !frames.isEmpty else { return }
        stats.withLock { for f in frames { counters.droppedClosed.add(f.count) } }
    }

    /// This port's counters, with `macs` and whether it is still connected.
    public func snapshot(macs: [String], connected: Bool) -> NetworkObservation.Port {
        stats.withLock {
            var port = counters
            port.macs = macs
            port.connected = connected
            let waiting = queue.withLock { (frames: delayLine.count, bytes: delayLine.bytes) }
            port.delayed = .init(frames: UInt64(waiting.frames), bytes: UInt64(waiting.bytes))
            return port
        }
    }
}
