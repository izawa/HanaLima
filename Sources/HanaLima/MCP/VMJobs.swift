import Foundation
import LimaKit
import MCPKit

/// The `vm` and `job` tools (docs/14 §4, §7): operations on existing VMs, run as jobs that a
/// person approves in the app first (every VM is the user's until MCP can create its own).
///
/// Start, stop and hibernate reuse the group operations' planner and runner (`GroupPlan`,
/// `GroupRunner`, the model's `recheck`/`performStep`), so the checks and the confirmations
/// (deleted-network NICs, the socket_vmnet mix) are the same as in the app. The other actions
/// run through the same runner with steps that need no confirmation.
@MainActor
@Observable
final class VMJobs {
    enum Action: String, CaseIterable {
        case start, stop, restart, pause, resume, hibernate
        case snapshotCreate = "snapshot_create", snapshotRestore = "snapshot_restore"
        /// The `exec` tool (not a `vm` action): a script in each target.
        case exec

        /// The group operation with the same checks, if there is one.
        var groupAction: GroupAction? {
            switch self {
            case .start: .start
            case .stop: .stop
            case .hibernate: .hibernate
            default: nil
            }
        }
    }

    /// A submitted job's plan: what the approval sheet shows and the runner follows.
    struct Plan {
        var jobID: String
        let action: Action
        let summary: String
        let steps: [GroupPlan.Step]
        let skipped: [GroupPlan.Skip]
        let tag: String?
        /// snapshot_restore: the snapshot each VM was planned to go back to, by id (one made
        /// again under the same name while waiting for approval is not the one approved).
        var snapshotIDs: [String: UUID] = [:]
        /// exec: what to run and its limits.
        var exec: ExecRequest?
    }

    struct ExecRequest {
        let script: String
        let timeout: Duration
        /// Output kept per target, in bytes (the response's budget split among the targets).
        let keepBytes: Int
    }

    /// The output of exec jobs, by job and target: in memory only, never in the state file or
    /// the call log (it may hold secrets).
    @ObservationIgnored private var outputs: [String: [String: String]] = [:]

    enum Failure: Error { case invalid(String) }

    let store: JobStore
    @ObservationIgnored private let state: AgentState
    /// Plans of the jobs waiting for approval, oldest first; the sheet shows the first.
    private(set) var awaitingApproval: [Plan] = []
    /// Waits hold a socket connection each; past this many, a wait answers at once so that
    /// get and cancel always find a free connection (AgentHost.maxConnections).
    static let maxWaits = 8
    @ObservationIgnored private var activeWaits = 0
    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel, state: AgentState) {
        self.model = model
        self.state = state
        store = state.jobs
        // An approval that expired or was cancelled by the client leaves the sheet.
        state.observe { [weak self] in self?.pruneApprovals() }
    }

    // MARK: - Tools

    /// `vm` and `exec` as the client calls them: file the job, then, with `wait` (seconds), wait
    /// for it to finish so a short operation needs no `job` call (docs/14 §5.3). A job waiting
    /// for the person's approval answers at once: the client should tell them.
    func call(_ tool: String, _ arguments: MCPKit.JSONValue) async throws -> String {
        var rest = arguments
        var seconds = 0
        if case .object(var o) = arguments, let raw = o.removeValue(forKey: "wait") {
            guard let n = raw.intValue, (0...120).contains(n) else { throw Failure.invalid("wait must be an integer in 0...120") }
            seconds = n
            rest = .object(o)
        }
        var job = tool == "exec" ? try submitExec(rest) : try submit(rest)
        // A wait holds a socket connection, like `job` wait: past the cap, answer at once.
        if seconds > 0, job.state == .running, activeWaits < Self.maxWaits {
            activeWaits += 1
            defer { activeWaits -= 1 }
            let deadline = ContinuousClock.now + .seconds(seconds)
            while job.state == .running, ContinuousClock.now < deadline,
                  let next = await store.wait(job.id, after: job.seq, timeout: deadline - ContinuousClock.now) {
                job = next
            }
        }
        let text = JobStore.text(job, detail: job.results.count <= 3)
        return job.tool == "exec" && job.state.isFinished ? text + "\n" + outputText(job.id) : text
    }

    /// The kept output of an exec job, VM by VM.
    private func outputText(_ id: String) -> String {
        let parts = (outputs[id] ?? [:]).sorted { $0.key < $1.key }.map { "--- \($0.key)\n\($0.value)" }
        return parts.isEmpty ? "--- no output kept (not an exec job, or HanaLima restarted)" : parts.joined(separator: "\n")
    }

    /// `vm`: validates, plans, and files a job waiting for approval.
    func submit(_ arguments: MCPKit.JSONValue) throws -> Job {
        store.expireStale()
        guard let object = arguments.objectValue else { throw Failure.invalid("arguments must be an object") }
        let known: Set = ["key", "targets", "group", "action", "tag"]
        if let unknown = object.keys.first(where: { !known.contains($0) }) { throw Failure.invalid("unknown argument: \(unknown)") }
        guard let key = object["key"]?.stringValue, !key.isEmpty else { throw Failure.invalid("key is required (any string unique to this request)") }
        guard let raw = object["action"]?.stringValue, let action = Action(rawValue: raw) else {
            throw Failure.invalid("action must be one of \(Action.allCases.map(\.rawValue).joined(separator: ","))")
        }
        do {
            // A retry finds its job even if the VMs it named were renamed or deleted since.
            if let job = try store.existing(key: key, tool: "vm", input: arguments) { return job }
        } catch JobStoreError.keyConflict(let id) {
            throw Failure.invalid("key already used by job \(id) with different arguments")
        }
        let names = try targets(object, action: action)
        let tag = object["tag"]?.stringValue
        if [.snapshotCreate, .snapshotRestore].contains(action), (tag ?? "").isEmpty {
            throw Failure.invalid("tag is required for \(action.rawValue)")
        }
        let summary = "\(action.rawValue) \(names.joined(separator: ", "))" + (tag.map { " (\($0))" } ?? "")
        return try file(makePlan(action: action, names: names, tag: tag, summary: summary), key: key, tool: "vm", input: arguments)
    }

    /// Files `draft` as a job: at once, after the person's approval, or (nothing to do) finished.
    private func file(_ draft: Plan, key: String, tool: String, input arguments: MCPKit.JSONValue) throws -> Job {
        // Nothing to do (all already running, say): no approval to ask for, just the reasons.
        // VMs MCP made need no approval either (docs/14 §6.1), except to roll a disk back.
        let needsApproval = draft.action == .snapshotRestore || draft.steps.contains { !state.ownsVM($0.id) }
        if let error = state.saveError { throw Failure.invalid("HanaLima can't save its MCP state (\(error)); nothing was started") }
        let (job, _) = try store.submit(key: key, tool: tool, input: arguments, summary: draft.summary, needsApproval: needsApproval)
        var plan = draft
        plan.jobID = job.id
        if plan.steps.isEmpty {
            recordSkips(plan)
            store.finish(job.id)
        } else if needsApproval {
            awaitingApproval.append(plan)
            #if DEBUG
            // The MCP E2E test: a debug build run with HANALIMA_MCP_AUTO_APPROVE=1 allows at once.
            if ProcessInfo.processInfo.environment["HANALIMA_MCP_AUTO_APPROVE"] == "1" { approve(plan, confirmations: [:]) }
            #endif
        } else {
            Task { await run(plan, confirmations: [:]) }
        }
        return store.job(job.id) ?? job
    }

    /// `exec`: a script in each target, as a job (approval rules as `vm`).
    func submitExec(_ arguments: MCPKit.JSONValue) throws -> Job {
        store.expireStale()
        guard let object = arguments.objectValue else { throw Failure.invalid("arguments must be an object") }
        let known: Set = ["key", "targets", "script", "timeoutSeconds", "outputBytes"]
        if let unknown = object.keys.first(where: { !known.contains($0) }) { throw Failure.invalid("unknown argument: \(unknown)") }
        guard let key = object["key"]?.stringValue, !key.isEmpty else { throw Failure.invalid("key is required") }
        do {
            if let job = try store.existing(key: key, tool: "exec", input: arguments) { return job }
        } catch JobStoreError.keyConflict(let id) {
            throw Failure.invalid("key already used by job \(id) with different arguments")
        }
        guard let script = object["script"]?.stringValue, !script.isEmpty, script.utf8.count <= 64 * 1024, !script.contains("\0") else {
            throw Failure.invalid("script is required (UTF-8, up to 64 KiB)")
        }
        let timeout = try Self.integer(object["timeoutSeconds"], "timeoutSeconds", 1...600, default: 60)
        let budget = try Self.integer(object["outputBytes"], "outputBytes", 1...16384, default: 4096)
        let names = try targets(object, action: .exec)
        guard names.count <= 16 else { throw Failure.invalid("at most 16 targets") }
        let summary = "exec \(names.joined(separator: ", "))"
        var plan = makePlan(action: .exec, names: names, tag: nil, summary: summary)
        plan.exec = ExecRequest(script: script, timeout: .seconds(timeout), keepBytes: budget / max(names.count, 1))
        return try file(plan, key: key, tool: "exec", input: arguments)
    }

    private static func integer(_ value: MCPKit.JSONValue?, _ name: String, _ range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let value else { return fallback }
        guard let n = value.intValue, range.contains(n) else { throw Failure.invalid("\(name) must be an integer in \(range.lowerBound)...\(range.upperBound)") }
        return n
    }

    /// `job`: get, wait or cancel.
    func job(_ arguments: MCPKit.JSONValue) async throws -> String {
        store.expireStale()
        guard let object = arguments.objectValue else { throw Failure.invalid("arguments must be an object") }
        let known: Set = ["id", "action", "after", "waitSeconds", "detail", "output"]
        if let unknown = object.keys.first(where: { !known.contains($0) }) { throw Failure.invalid("unknown argument: \(unknown)") }
        guard let id = object["id"]?.stringValue, store.job(id) != nil else { throw Failure.invalid("unknown job id") }
        let detail = object["detail"]?.boolValue ?? false
        let withOutput = object["output"]?.boolValue ?? false
        switch object["action"]?.stringValue ?? "get" {
        case "get":
            let text = JobStore.text(store.job(id)!, detail: detail)
            guard withOutput else { return text }
            return text + "\n" + outputText(id)
        case "wait":
            let after = object["after"]?.intValue ?? store.job(id)!.seq
            let seconds = activeWaits < Self.maxWaits ? min(max(object["waitSeconds"]?.intValue ?? 120, 1), 120) : 0
            activeWaits += 1
            defer { activeWaits -= 1 }
            let job = await store.wait(id, after: after, timeout: .seconds(seconds))
            return job.map { JobStore.text($0, detail: detail) } ?? "unknown job id"
        case "cancel":
            let job = try store.cancel(id)
            dropApproval(id)
            return JobStore.text(job, detail: detail)
        default:
            throw Failure.invalid("action must be get, wait or cancel")
        }
    }

    // MARK: - Approval (the sheet)

    func approve(_ plan: Plan, confirmations: [String: Set<GroupConfirmation>]) {
        guard (try? store.approve(plan.jobID)) != nil else { dropApproval(plan.jobID); return }
        dropApproval(plan.jobID)
        Task { await run(plan, confirmations: confirmations) }
    }

    func deny(_ plan: Plan) {
        try? store.deny(plan.jobID)
        dropApproval(plan.jobID)
    }

    /// Drops plans whose jobs ended while waiting (expired, cancelled by the client).
    private func pruneApprovals() {
        // Output of jobs the store has let go of (keep limit) goes with them.
        if outputs.keys.contains(where: { store.job($0) == nil }) {
            outputs = outputs.filter { store.job($0.key) != nil }
        }
        if awaitingApproval.contains(where: { store.job($0.jobID)?.state != .awaitingApproval }) {
            awaitingApproval.removeAll { store.job($0.jobID)?.state != .awaitingApproval }
        }
    }

    /// The person turned AI operations off: deny what waits, stop running jobs after their
    /// current step.
    func cancelAll() {
        for job in store.jobs where !job.state.isFinished { _ = try? store.cancel(job.id) }
        awaitingApproval.removeAll()
    }

    private func dropApproval(_ id: String) {
        awaitingApproval.removeAll { $0.jobID == id }
    }

    // MARK: - Planning and running

    private func targets(_ object: [String: MCPKit.JSONValue], action: Action) throws -> [String] {
        if let group = object["group"] {
            guard object["targets"] == nil else { throw Failure.invalid("give targets or group, not both") }
            guard action.groupAction != nil else { throw Failure.invalid("group works only with start, stop and hibernate") }
            guard let name = group.stringValue, let members = model.groupMembers(name) else { throw Failure.invalid("unknown group") }
            guard !members.isEmpty else { throw Failure.invalid("the group has no VMs") }
            return members
        }
        guard let array = object["targets"]?.arrayValue, !array.isEmpty else { throw Failure.invalid("targets (VM names) or group is required") }
        let names = array.compactMap(\.stringValue)
        guard names.count == array.count else { throw Failure.invalid("targets must be an array of strings") }
        guard Set(names).count == names.count else { throw Failure.invalid("targets has duplicates") }
        if let missing = names.first(where: { model.instance(named: $0) == nil }) { throw Failure.invalid("unknown VM: \(missing)") }
        return names
    }

    /// The plan before it has a job (jobID is filled in once filed).
    private func makePlan(action: Action, names: [String], tag: String?, summary: String) -> Plan {
        if let group = action.groupAction {
            let plan = GroupPlan.make(group, members: model.memberFacts(names, for: group))
            return Plan(jobID: "", action: action, summary: summary, steps: plan.steps, skipped: plan.skipped, tag: tag)
        }
        // The same checks as just before each step, so the sheet asks only about what can run.
        var steps: [GroupPlan.Step] = []
        var skipped: [GroupPlan.Skip] = []
        var snapshotIDs: [String: UUID] = [:]
        for name in names {
            guard let id = model.metadata[name]?.id else {
                skipped.append(GroupPlan.Skip(name: name, reason: .refused("no HanaLima record yet; open the app once")))
                continue
            }
            let step = GroupPlan.Step(name: name, id: id, memory: model.instance(named: name)?.memory ?? 0, confirmations: [:], resumes: false)
            if let reason = recheck(step, action: action, tag: tag) {
                skipped.append(GroupPlan.Skip(name: name, reason: .refused(reason)))
            } else {
                steps.append(step)
                if action == .snapshotRestore, let inst = model.instance(named: name) {
                    snapshotIDs[name] = DiskSnapshot.list(instanceDir: inst.instanceDir).first { $0.name == tag }?.id
                }
            }
        }
        return Plan(jobID: "", action: action, summary: summary, steps: steps, skipped: skipped, tag: tag, snapshotIDs: snapshotIDs)
    }

    private func recordSkips(_ plan: Plan) {
        for skip in plan.skipped {
            store.record(plan.jobID, JobTargetResult(target: skip.name, outcome: "skipped", message: GroupRunSheet.text(skip.reason)))
        }
    }

    private func run(_ plan: Plan, confirmations: [String: Set<GroupConfirmation>]) async {
        let id = plan.jobID
        recordSkips(plan)
        _ = await GroupRunner.run(
            plan.steps, approved: confirmations,
            isCancelled: { await MainActor.run { self.store.job(id)?.cancelRequested ?? true } },
            recheck: { step in await self.recheck(step, action: plan.action, tag: plan.tag) },
            perform: { step, approvals in
                await MainActor.run { self.store.setCurrent(id, step.name) }
                return await self.perform(step, plan, approvals: approvals)
            },
            progress: { result in
                await MainActor.run { self.store.record(id, Self.targetResult(result)) }
            })
        store.setCurrent(id, nil)
        store.finish(id)
    }

    private func recheck(_ step: GroupPlan.Step, action: Action, tag: String?) -> String? {
        if let group = action.groupAction { return model.recheck(step, action: group) }
        guard let name = model.currentName(of: step), let inst = model.instance(named: name) else {
            return "not found (deleted or made again)"
        }
        if model.isBusy(name) { return "busy with another operation" }
        switch action {
        case .restart: return inst.isRunning ? model.diskUnusableReason(name)?.title : "not running"
        case .pause: return model.isPaused(name) ? "already paused" : model.pauseBlocker(name)
        case .resume: return model.isPaused(name) ? nil : "not paused"
        case .exec:
            if !inst.isRunning { return "not running" }
            if model.isPaused(name) { return "paused" }
            return model.isReady(name) ? nil : "still booting"
        case .snapshotCreate, .snapshotRestore:
            if inst.isRunning { return "stop the VM first" }
            if model.isHibernated(name) { return "hibernated; start or discard the saved state first" }
            if let owner = model.sharedDiskOwners[name] { return "shares its disk with \(owner); make it independent in the app first" }
            if action == .snapshotRestore, let tag {
                let matches = DiskSnapshot.list(instanceDir: inst.instanceDir).filter { $0.name == tag }
                if matches.count != 1 { return matches.isEmpty ? "no snapshot named \(tag)" : "\(matches.count) snapshots are named \(tag); restore one in the app" }
            }
            return inst.usesVirtualization ? nil : "only vz and hanalima VMs (QEMU snapshots are made in the app)"
        case .start, .stop, .hibernate: return nil
        }
    }

    private func perform(_ step: GroupPlan.Step, _ plan: Plan, approvals: Set<GroupConfirmation>) async -> GroupStepReport {
        if let group = plan.action.groupAction { return await model.performStep(step, action: group, approvals: approvals) }
        guard let name = model.currentName(of: step) else { return .failed("not found") }
        let error: String?
        switch plan.action {
        case .restart: error = await model.restartNow(name)
        case .pause: error = await model.sendPauseOp(.pause, kind: .pause, to: name)
        case .resume: error = await model.sendPauseOp(.resume, kind: .resume, to: name)
        case .snapshotCreate:
            let tag = plan.tag ?? ""
            error = await model.performDiskSnapshot(.snapshotCreate, name) { dir in _ = try DiskSnapshot.create(instanceDir: dir, name: tag) }
        case .snapshotRestore:
            guard let inst = model.instance(named: name), let id = plan.snapshotIDs[step.name],
                  let snapshot = DiskSnapshot.list(instanceDir: inst.instanceDir).first(where: { $0.id == id }) else {
                return .failed("the snapshot approved is gone")
            }
            error = await model.performDiskSnapshot(.snapshotApply, name) { dir in try DiskSnapshot.restore(snapshot, of: dir, into: dir) }
        case .exec:
            guard let exec = plan.exec else { return .failed("no script") }
            let id = plan.jobID
            let result = await model.runGuestScript(name, script: exec.script, timeout: exec.timeout, keepBytes: exec.keepBytes,
                                                    stop: { [weak self] in self?.store.job(id)?.cancelRequested ?? true })
            outputs[plan.jobID, default: [:]][step.name] = result.output
            if let failure = result.error { error = failure }
            else if let exit = result.exit, exit != 0 { error = "exit \(exit)" }
            else { error = nil }
        case .start, .stop, .hibernate: error = nil
        }
        return error.map(GroupStepReport.failed) ?? .done
    }

    private static func targetResult(_ result: GroupStepResult) -> JobTargetResult {
        switch result.outcome {
        case .done: JobTargetResult(target: result.name, outcome: "done", message: nil)
        case .skipped(let why): JobTargetResult(target: result.name, outcome: "skipped", message: why)
        case .notConfirmed: JobTargetResult(target: result.name, outcome: "notConfirmed", message: "the person didn't tick its confirmation")
        case .failed(let why): JobTargetResult(target: result.name, outcome: "failed", message: why)
        case .notRun: JobTargetResult(target: result.name, outcome: "notRun", message: "cancelled before it")
        }
    }
}
