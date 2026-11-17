import Foundation

/// A fault on a guest-only network (docs/18): delay and loss for the frames delivered to a VM's
/// NIC (or to every port), or a block that passes nothing either way. Lives in the helper's memory
/// until it expires or is removed.
public struct NetworkFault: Codable, Sendable, Hashable, Identifiable {
    public struct Spec: Codable, Sendable, Hashable {
        /// The target for the whole segment.
        public static let everyone = "*"
        public static let maxDelayMs = 5_000
        public static let maxSeconds = 1_800

        /// A NIC's MAC address, or `everyone`.
        public var target: String
        public var delayMs = 0
        public var lossPercent = 0.0
        public var block = false
        public var seconds: Int

        public init(target: String, delayMs: Int = 0, lossPercent: Double = 0, block: Bool = false, seconds: Int) {
            self.target = target; self.delayMs = delayMs; self.lossPercent = lossPercent; self.block = block; self.seconds = seconds
        }

        public var isSegment: Bool { target == Self.everyone }

        private enum CodingKeys: String, CodingKey { case target, delayMs, lossPercent, block, seconds }

        /// The effects not used may be left out (`{"target":"*","block":true,"seconds":30}`).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            target = try c.decode(String.self, forKey: .target)
            delayMs = try c.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
            lossPercent = try c.decodeIfPresent(Double.self, forKey: .lossPercent) ?? 0
            block = try c.decodeIfPresent(Bool.self, forKey: .block) ?? false
            seconds = try c.decode(Int.self, forKey: .seconds)
        }

        /// The spec with its MAC normalized, or why it can't be used.
        public func validated() throws -> Spec {
            var spec = self
            if !isSegment {
                guard let mac = DHCPReservation.normalizedMAC(target) else { throw NetdControl.Failure(message: "bad target \(target)") }
                spec.target = mac
            }
            guard (1...Self.maxSeconds).contains(seconds) else { throw NetdControl.Failure(message: "seconds must be 1–\(Self.maxSeconds)") }
            guard (0...Self.maxDelayMs).contains(delayMs) else { throw NetdControl.Failure(message: "delayMs must be 0–\(Self.maxDelayMs)") }
            guard (0...100).contains(lossPercent) else { throw NetdControl.Failure(message: "lossPercent must be 0–100") }
            if block {
                guard delayMs == 0, lossPercent == 0 else { throw NetdControl.Failure(message: "a block takes no delay or loss") }
            } else {
                guard delayMs > 0 || lossPercent > 0 else { throw NetdControl.Failure(message: "nothing to do") }
            }
            return spec
        }
    }

    public var id: String
    public var spec: Spec
    public var startedAt: Date
    public var expiresAt: Date

    public init(id: String, spec: Spec, startedAt: Date, expiresAt: Date) {
        self.id = id; self.spec = spec; self.startedAt = startedAt; self.expiresAt = expiresAt
    }
}

/// The helper's faults and its decisions on them (kept under the switch's lock). The clock and
/// the random source are parameters, so tests decide every frame.
public struct FaultTable: Sendable {
    /// What happens to one frame.
    public enum Verdict: Equatable, Sendable {
        case pass(delay: Duration)
        case lost
        case blocked
    }

    private struct Entry: Sendable {
        var fault: NetworkFault
        var deadline: ContinuousClock.Instant
    }

    /// In the order started: the first that matches a port wins.
    private var entries: [Entry] = []
    private let random: @Sendable () -> Double

    public init(random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) { self.random = random }

    public var isEmpty: Bool { entries.isEmpty }

    /// The faults in force at `now`.
    public func faults(at now: ContinuousClock.Instant) -> [NetworkFault] {
        entries.filter { $0.deadline > now }.map(\.fault)
    }

    /// Adds a fault. Refused when its target already has one, or when it would overlap a fault
    /// for the whole segment (what stacking means isn't defined).
    public mutating func start(_ spec: NetworkFault.Spec, now: ContinuousClock.Instant, date: Date = .now) throws -> NetworkFault {
        let spec = try spec.validated()
        expire(now)
        if entries.contains(where: { $0.fault.spec.target == spec.target }) {
            throw NetdControl.Failure(message: "that target already has a fault")
        }
        if !entries.isEmpty, spec.isSegment || entries.contains(where: { $0.fault.spec.isSegment }) {
            throw NetdControl.Failure(message: "a fault for the whole segment can't be combined with others")
        }
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let fault = NetworkFault(id: id, spec: spec, startedAt: date, expiresAt: date.addingTimeInterval(TimeInterval(spec.seconds)))
        entries.append(Entry(fault: fault, deadline: now + .seconds(spec.seconds)))
        return fault
    }

    /// Removes the fault `id`, or all with nil; returns what it removed.
    public mutating func stop(id: String?) throws -> [NetworkFault] {
        guard let id else { defer { entries = [] }; return entries.map(\.fault) }
        guard let i = entries.firstIndex(where: { $0.fault.id == id }) else { throw NetdControl.Failure(message: "no such fault") }
        return [entries.remove(at: i).fault]
    }

    /// Drops the faults past their deadline; true when any went.
    @discardableResult
    public mutating func expire(_ now: ContinuousClock.Instant) -> Bool {
        let before = entries.count
        entries.removeAll { $0.deadline <= now }
        return entries.count != before
    }

    /// The fault in force for a port, given which MACs it owns.
    public func fault(at now: ContinuousClock.Instant, owns: (String) -> Bool) -> NetworkFault.Spec? {
        entries.first { $0.deadline > now && ($0.fault.spec.isSegment || owns($0.fault.spec.target)) }?.fault.spec
    }

    /// The fate of a frame delivered to a port under `spec`.
    public func verdict(_ spec: NetworkFault.Spec?) -> Verdict {
        guard let spec else { return .pass(delay: .zero) }
        if spec.block { return .blocked }
        if spec.lossPercent > 0, random() * 100 < spec.lossPercent { return .lost }
        return .pass(delay: .milliseconds(spec.delayMs))
    }
}

/// Frames waiting out a port's delay (docs/18), apart from its send queue. Due times never go
/// backwards, so the frames leave in the order they came, also right after a fault is removed.
public struct DelayLine: Sendable {
    public static let capacity = 8 << 20

    private var frames: [(due: ContinuousClock.Instant, frame: [UInt8])] = []
    private var head = 0
    private var lastDue: ContinuousClock.Instant?
    public private(set) var bytes = 0
    public let capacity: Int

    public init(capacity: Int = DelayLine.capacity) { self.capacity = capacity }

    public var isEmpty: Bool { head == frames.count }
    public var count: Int { frames.count - head }
    public var nextDue: ContinuousClock.Instant? { isEmpty ? nil : frames[head].due }

    /// False when the frame doesn't fit (it is then not kept).
    public mutating func push(_ frame: [UInt8], due: ContinuousClock.Instant) -> Bool {
        guard bytes + frame.count <= capacity else { return false }
        let due = lastDue.map { max($0, due) } ?? due
        frames.append((due, frame))
        lastDue = due
        bytes += frame.count
        return true
    }

    /// The frames due at `now`, oldest first, at most `limit` (the rest stay for later).
    public mutating func popDue(_ now: ContinuousClock.Instant, limit: Int = .max) -> [[UInt8]] {
        var out: [[UInt8]] = []
        while out.count < limit, head < frames.count, frames[head].due <= now {
            out.append(frames[head].frame)
            bytes -= frames[head].frame.count
            head += 1
        }
        compact()
        return out
    }

    public mutating func removeAll() -> [[UInt8]] {
        let out = frames[head...].map(\.frame)
        self = DelayLine(capacity: capacity)
        return out
    }

    private mutating func compact() {
        if head == frames.count {
            frames.removeAll(keepingCapacity: true)
            head = 0
            lastDue = nil
        } else if head > 1024, head * 2 > frames.count {
            frames.removeFirst(head)
            head = 0
        }
    }
}
