import Foundation

public enum JobState: String, Sendable, Codable {
    case awaitingApproval, running, succeeded, partial, failed, cancelled, denied, expired
    /// Running or waiting when the app quit: nothing resumes it; plan again to finish.
    case interrupted

    public var isFinished: Bool {
        switch self {
        case .awaitingApproval, .running: false
        case .succeeded, .partial, .failed, .cancelled, .denied, .expired, .interrupted: true
        }
    }
}

public struct JobTargetResult: Sendable, Equatable, Codable {
    public var target: String
    public var outcome: String
    public var message: String?

    public init(target: String, outcome: String, message: String? = nil) {
        self.target = target
        self.outcome = outcome
        self.message = message
    }
}

public struct Job: Sendable, Equatable, Codable {
    public let id: String
    public let key: String
    public let tool: String
    public let input: JSONValue
    public let summary: String
    public var state: JobState
    public var seq: Int
    public var current: String?
    public var results: [JobTargetResult]
    public var cancelRequested: Bool
    public let createdAt: Date
    /// One line the runner adds for the short answer, e.g. what the checks verified.
    public var note: String?
}

public enum JobStoreError: Error, Equatable {
    case keyConflict(jobID: String)
    case notFound
    /// Approving a job that already expired, was cancelled or was decided.
    case notAwaitingApproval
}

/// Keeps jobs on the app's actor so approval decisions and runner updates stay ordered.
@MainActor
public final class JobStore {
    private let now: @MainActor () -> Date
    private let approvalTimeout: TimeInterval
    private let keep: Int
    public private(set) var nextID = 1
    private var stored: [Job] = []

    private struct Waiter {
        let jobID: String
        let after: Int
        let continuation: CheckedContinuation<Job?, Never>
        let timer: Task<Void, Never>
    }
    private var waiters: [UUID: Waiter] = [:]

    public var onChange: (@MainActor () -> Void)?

    public init(now: @escaping @MainActor () -> Date = Date.init,
                approvalTimeout: TimeInterval = 600, keep: Int = 50) {
        self.now = now
        self.approvalTimeout = approvalTimeout
        self.keep = max(0, keep)
    }

    /// The jobs saved at the last quit (AgentState): unfinished ones become interrupted.
    public convenience init(restoring jobs: [Job], nextID: Int) {
        self.init()
        stored = jobs.map { job in
            var job = job
            if !job.state.isFinished { job.state = .interrupted; job.current = nil }
            return job
        }
        self.nextID = max(nextID, 1)
    }

    /// The job already filed under `key` for the same request (nil: none), or keyConflict. The
    /// tools ask this before resolving their targets: a retry must find its job even after the
    /// VMs it named were renamed or deleted.
    public func existing(key: String, tool: String, input: JSONValue) throws -> Job? {
        guard let job = stored.first(where: { $0.key == key }) else { return nil }
        guard job.tool == tool, job.input == Self.withoutKey(input) else { throw JobStoreError.keyConflict(jobID: job.id) }
        return job
    }

    private static func withoutKey(_ input: JSONValue) -> JSONValue {
        guard case .object(var arguments) = input else { return input }
        arguments.removeValue(forKey: "key")
        return .object(arguments)
    }

    public func submit(key: String, tool: String, input: JSONValue, summary: String,
                       needsApproval: Bool) throws -> (job: Job, isNew: Bool) {
        if let existing = try existing(key: key, tool: tool, input: input) { return (existing, false) }
        let input = Self.withoutKey(input)
        let job = Job(id: "j\(nextID)", key: key, tool: tool, input: input, summary: summary,
                      state: needsApproval ? .awaitingApproval : .running, seq: 1,
                      current: nil, results: [], cancelRequested: false, createdAt: now())
        nextID += 1
        stored.insert(job, at: 0)
        onChange?()
        return (job, true)
    }

    public func job(_ id: String) -> Job? { stored.first { $0.id == id } }

    public var jobs: [Job] {
        expireStale()
        return stored
    }

    public var awaitingApproval: [Job] {
        expireStale()
        return stored.reversed().filter { $0.state == .awaitingApproval }
    }

    /// Only a job still awaiting approval can be approved (not one that expired or was cancelled
    /// meanwhile): the caller starts work only when this succeeds.
    public func approve(_ id: String) throws {
        expireStale()
        guard let job = job(id) else { throw JobStoreError.notFound }
        guard job.state == .awaitingApproval else { throw JobStoreError.notAwaitingApproval }
        update(id) { $0.state = .running }
    }

    public func deny(_ id: String) throws {
        guard job(id) != nil else { throw JobStoreError.notFound }
        update(id) { if $0.state == .awaitingApproval { $0.state = .denied } }
    }

    public func setNote(_ id: String, _ note: String) {
        update(id) { $0.note = note }
    }

    public func setCurrent(_ id: String, _ target: String?) {
        update(id) { if $0.state == .running { $0.current = target } }
    }

    public func record(_ id: String, _ result: JobTargetResult) {
        update(id) { if $0.state == .running { $0.results.append(result) } }
    }

    public func finish(_ id: String) {
        update(id) { job in
            guard job.state == .running else { return }
            job.current = nil
            if job.cancelRequested {
                job.state = .cancelled
            } else if job.results.allSatisfy({ $0.outcome == "done" || $0.outcome == "skipped" }) {
                job.state = .succeeded
            } else if job.results.allSatisfy({ $0.outcome == "failed" }) {
                job.state = .failed
            } else {
                job.state = .partial
            }
        }
    }

    /// Returns the job as cancelled: finishing it may drop it from the store at once (`keep`).
    @discardableResult
    public func cancel(_ id: String) throws -> Job {
        guard let current = job(id) else { throw JobStoreError.notFound }
        return update(id) { job in
            switch job.state {
            case .awaitingApproval: job.state = .cancelled
            case .running: job.cancelRequested = true
            default: break
            }
        } ?? current
    }

    /// Wakes on changes rather than polling, so idle MCP clients do not keep the app busy. A job
    /// awaiting approval waits too: the approval in the app is the change the client waits for.
    public func wait(_ id: String, after: Int, timeout: Duration) async -> Job? {
        guard let job = job(id) else { return nil }
        if job.seq > after || job.state.isFinished || timeout <= .zero || Task.isCancelled { return job }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.resume(token)
                }
                waiters[token] = Waiter(jobID: id, after: after, continuation: continuation, timer: timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resume(token) }
        }
    }

    public func expireStale() {
        let date = now()
        let stale = stored.filter {
            $0.state == .awaitingApproval && date.timeIntervalSince($0.createdAt) > approvalTimeout
        }.map(\.id)
        for id in stale { update(id) { $0.state = .expired } }
    }

    private func resume(_ token: UUID) {
        guard let waiter = waiters.removeValue(forKey: token) else { return }
        waiter.timer.cancel()
        waiter.continuation.resume(returning: job(waiter.jobID))
    }

    @discardableResult
    private func update(_ id: String, _ change: (inout Job) -> Void) -> Job? {
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return nil }
        var job = stored[index]
        change(&job)
        guard job != stored[index] else { return job }
        job.seq += 1
        stored[index] = job
        let ready = waiters.filter {
            $0.value.jobID == id && (job.seq > $0.value.after || job.state.isFinished)
        }.map(\.key)
        // Deliver the final snapshot before retention can remove the job.
        for token in ready { resume(token) }
        var finished = 0
        stored.removeAll {
            guard $0.state.isFinished else { return false }
            finished += 1
            return finished > keep
        }
        onChange?()
        return job
    }

    public nonisolated static func text(_ job: Job, detail: Bool) -> String {
        var lines = ["job \(job.id)\t\(job.state.rawValue)\tseq=\(job.seq)\t\(job.summary)"]
        if job.state == .awaitingApproval {
            lines.append("waiting\tapproval in the HanaLima app (ask the user)")
        }
        if let current = job.current { lines.append("current\t\(current)") }
        if let note = job.note { lines.append("note\t\(note)") }
        if !job.results.isEmpty {
            lines.append("target\toutcome\tmessage")
            // Without detail, the rows that carry a reason; plain successes only as a count.
            for result in job.results where detail || result.outcome != "done" {
                lines.append("\(result.target)\t\(result.outcome)\t\(result.message ?? "")")
            }
            if !detail {
                lines.append("done\t\(job.results.filter { $0.outcome == "done" }.count)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
