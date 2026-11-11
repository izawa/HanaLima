import AgentKit
import Foundation
import LimaKit
import MCPKit
import NetworkKit

/// The `plan`, `apply` and `delete` tools (docs/14 §2, §4, stage 2): builds new guest-only
/// networks and VMs from a declaration, and deletes what MCP made. Plans live in memory for
/// ten minutes; jobs and the ledger of what MCP made are kept by `AgentState`.
@MainActor
@Observable
final class BuildJobs {
    enum Failure: Error { case invalid(String) }

    struct StoredPlan {
        let id: String
        let spec: TopologySpec
        let plan: TopologyPlan
        let expires: Date
    }

    /// A job waiting for the person (docs/14 §6.1): every delete, and a build that needs it
    /// (more memory than the Mac has, say).
    struct ApprovalRequest: Identifiable {
        enum Kind {
            /// The record id each VM had when the person was asked: a VM made again under the
            /// same name since is not the one approved.
            case delete(vms: [String], vmIDs: [String: UUID], networks: [String])
            case build(spec: TopologySpec, plan: TopologyPlan)
        }
        let jobID: String
        let kind: Kind
        var id: String { jobID }
    }

    static let planLifetime: TimeInterval = 600

    private(set) var awaitingApproval: [ApprovalRequest] = []
    @ObservationIgnored private var plans: [String: StoredPlan] = [:]
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let state: AgentState

    init(model: AppModel, state: AgentState) {
        self.model = model
        self.state = state
        state.observe { [weak self] in self?.pruneDeletes() }
    }

    /// The job already filed under `key` (a retry), checked before anything else.
    private func existing(key: String, tool: String, input: MCPKit.JSONValue) throws -> Job? {
        do { return try state.jobs.existing(key: key, tool: tool, input: input) } catch JobStoreError.keyConflict(let id) {
            throw Failure.invalid("key already used by job \(id) with different arguments")
        }
    }

    // MARK: - plan

    func plan(_ arguments: MCPKit.JSONValue) throws -> String {
        guard let object = arguments.objectValue else { throw Failure.invalid("arguments must be an object") }
        if let unknown = object.keys.first(where: { !["spec"].contains($0) }) { throw Failure.invalid("unknown argument: \(unknown)") }
        guard let json = object["spec"] else { throw Failure.invalid("spec is required") }
        let (spec, problems) = TopologySpec.decode(json)
        guard let spec else {
            return (["plan -\tblocked"] + problems.map(Self.problemLine)).joined(separator: "\n")
        }
        let plan = TopologyPlanner.plan(spec, facts: facts())
        // Unique across launches: a counter starting again at p1 made an `apply` retried with an
        // old key and "p1" look like that old request, which then answered with its old job.
        plans = plans.filter { $0.value.expires > .now }
        var id = Self.newPlanID()
        while plans[id] != nil { id = Self.newPlanID() }  // short for the client; never two alike
        let stored = StoredPlan(id: id, spec: spec, plan: plan, expires: Date.now.addingTimeInterval(Self.planLifetime))
        plans[id] = stored
        return plan.text(planID: id, expires: stored.expires)
    }

    static func newPlanID() -> String {
        "p" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
    }

    private static func problemLine(_ p: PlanProblem) -> String {
        "problem\t\(p.code)\t\(p.path)\t\(p.message)" + (p.alternative.map { "\talternative: \($0)" } ?? "")
    }

    private func facts() -> PlannerFacts {
        PlannerFacts(
            vms: model.instances.map { inst in
                let id = model.metadata[inst.name]?.id
                return .init(name: inst.name, id: id, ownedByMCP: id.map(state.ownsVM) ?? false)
            },
            networks: model.virtualNetworks,
            ownedNetworks: Set(model.virtualNetworks.map(\.name).filter(state.ownsNetwork)),
            templates: model.templates,
            physicalMemory: Int64(ProcessInfo.processInfo.physicalMemory),
            runningMemory: model.instances.filter(\.isRunning).reduce(0) { $0 + ($1.memory ?? 0) },
            hasDriver: AppModel.hasDriver)
    }

    // MARK: - apply

    func apply(_ arguments: MCPKit.JSONValue) throws -> String {
        guard let object = arguments.objectValue else { throw Failure.invalid("arguments must be an object") }
        if let unknown = object.keys.first(where: { !["plan", "key"].contains($0) }) { throw Failure.invalid("unknown argument: \(unknown)") }
        guard let key = object["key"]?.stringValue, !key.isEmpty else { throw Failure.invalid("key is required") }
        guard let planID = object["plan"]?.stringValue else { throw Failure.invalid("plan is required") }
        if let job = try existing(key: key, tool: "apply", input: arguments) { return JobStore.text(job, detail: false) }
        guard let stored = plans[planID], stored.expires > .now else { throw Failure.invalid("unknown or expired plan; call plan again") }
        guard stored.plan.problems.isEmpty else { throw Failure.invalid("the plan is blocked by its problems; fix the spec and plan again") }
        // The Mac may have changed since the plan (a name taken, a network made).
        let now = TopologyPlanner.plan(stored.spec, facts: facts())
        guard now.fingerprint == stored.plan.fingerprint, now.problems.isEmpty else {
            throw Failure.invalid("PLAN_STALE: the Mac changed since the plan; call plan again")
        }
        if let error = state.saveError { throw Failure.invalid("HanaLima can't save its MCP state (\(error)); nothing was started") }
        // One build at a time: two would save networks.json over each other.
        if state.jobs.jobs.contains(where: { $0.tool == "apply" && !$0.state.isFinished }) {
            throw Failure.invalid("another build is running; wait for it with job, then plan again")
        }
        let summary = "build " + ([stored.plan.group].compactMap { $0 } + stored.plan.vms.map(\.name)).joined(separator: " ")
        let needsApproval = !now.approvals.isEmpty
        let (job, _) = try state.jobs.submit(key: key, tool: "apply", input: arguments, summary: summary, needsApproval: needsApproval)
        if needsApproval {
            enqueue(ApprovalRequest(jobID: job.id, kind: .build(spec: stored.spec, plan: now)))
        } else {
            Task { await run(now, jobID: job.id) }
        }
        return JobStore.text(job, detail: false)
    }

    private func run(_ plan: TopologyPlan, jobID id: String) async {
        let jobs = state.jobs
        func record(_ target: String, _ error: String?) {
            jobs.record(id, JobTargetResult(target: target, outcome: error == nil ? "done" : "failed", message: error))
        }
        // 1. Networks, with every reservation and the router in place before any VM starts:
        //    saving a network restarts its netd, which would cut running VMs off.
        for net in plan.networks where net.action == .create {
            if jobs.job(id)?.cancelRequested == true { return finish(id) }
            jobs.setCurrent(id, net.network.name)
            let error = await model.saveVirtualNetwork(net.network)
            if error == nil { state.recordNetwork(net.network.name, job: id) }
            record(net.network.name, error)
            if error != nil { return finish(id) }
        }
        // 2. VMs, stopped. A group that didn't exist is the build's, so a delete can remove it
        //    once it's empty.
        let groupIsNew = plan.group.map { model.groupLayout.index(ofGroup: $0) == nil } ?? false
        var failed: Set<String> = []
        for vm in plan.vms where vm.action == .create {
            if jobs.job(id)?.cancelRequested == true { return finish(id) }
            if let error = state.saveError {
                record(vm.name, "not created: HanaLima can't save its MCP state (\(error))")
                return finish(id)
            }
            jobs.setCurrent(id, vm.name)
            if let error = await model.createNow(vm.options, template: vm.template, group: plan.group) {
                record(vm.name, "create: \(error)")
                failed.insert(vm.name)
            } else if let recordID = model.metadata[vm.name]?.id {
                state.recordVM(recordID, name: vm.name, job: id)
                // Only once a VM made it exist.
                if groupIsNew, let group = plan.group, !state.ownsGroup(group), model.groupLayout.index(ofGroup: group) != nil {
                    state.recordGroup(group, job: id)
                }
            }
        }
        // 3. Start in order; a failed router leaves the rest waiting (they'd have no way out).
        let routers = Set(plan.networks.compactMap { net in
            plan.vms.first { vm in vm.nics.contains { $0.network == net.network.name && $0.ip == net.network.router } }?.name
        })
        // A router that couldn't even be created fails its network's other VMs too.
        var routerFailed = !failed.isDisjoint(with: routers)
        for vm in plan.vms where !failed.contains(vm.name) {
            if jobs.job(id)?.cancelRequested == true { return finish(id) }
            if routerFailed && !routers.contains(vm.name) {
                jobs.record(id, JobTargetResult(target: vm.name, outcome: "skipped", message: "a router failed; not started"))
                continue
            }
            jobs.setCurrent(id, vm.name)
            let error = await start(vm)
            if error != nil, routers.contains(vm.name) { routerFailed = true }
            if let error { record(vm.name, error); failed.insert(vm.name) }
        }
        // 4. Check what can be checked without running anything in the guests.
        jobs.setCurrent(id, nil)
        for vm in plan.vms where !failed.contains(vm.name) && jobs.job(id)?.results.contains(where: { $0.target == vm.name }) != true {
            let error = await verify(vm)
            record(vm.name, error)
            if error != nil { failed.insert(vm.name) }
        }
        // 5. Traffic, from inside the guests (docs/14 §2.3). A check that didn't pass is
        //    "unverified", not "can't reach": ICMP may be filtered, the site may be down.
        let checkScripts = TopologyVerification.scripts(for: plan)
        for (vm, entry) in checkScripts.sorted(by: { $0.key < $1.key }) {
            if jobs.job(id)?.cancelRequested == true { return finish(id) }
            jobs.setCurrent(id, vm)
            var runError: String? = failed.contains(vm) ? "not built" : nil
            var output = ""
            if runError == nil {
                let result = await model.runGuestScript(vm, script: entry.script, timeout: .seconds(60), keepBytes: 8192)
                output = result.output
                runError = result.error
            }
            for check in TopologyVerification.results(checks: entry.checks, output: output, runError: runError) {
                jobs.record(id, JobTargetResult(target: "\(check.check.vm) \(check.check.id)",
                                                outcome: check.verified ? "done" : "unverified", message: check.reason))
            }
        }
        // Only a topology with a router has a way out to check.
        if plan.verifyOutside == nil, plan.networks.contains(where: { !$0.network.router.isEmpty }) {
            jobs.record(id, JobTargetResult(target: "- outside", outcome: "unverified", message: "no verifyOutside given"))
        }
        // The short answer counts rows; say which are the traffic checks, so the client
        // needn't ask for the details or check again itself.
        let checks = jobs.job(id)?.results.filter { $0.target.contains(" ") } ?? []
        let verified = checks.filter { $0.outcome == "done" }.count
        jobs.setNote(id, "built \(plan.networks.count) network(s), \(plan.vms.count) VM(s); traffic checks verified \(verified) of \(checks.count)"
            + (plan.verifyOutside.map { " (outside: \($0))" } ?? ""))
        finish(id)
    }

    private func finish(_ id: String) {
        state.jobs.setCurrent(id, nil)
        state.jobs.finish(id)
    }

    /// Starts `vm`; a bootstrap VM boots once with NIC 0, then loses it (docs/14 §2). Decided
    /// from the VM's config, not from whether it runs: a build interrupted after the first boot
    /// leaves it running with NIC 0, and only removing NIC 0 finishes it.
    private func start(_ vm: TopologyPlan.PlannedVM) async -> String? {
        guard let client = model.client, let inst = model.instance(named: vm.name) else { return "not found" }
        let isolate = vm.bootstrapUsernet && inst.usesUsernet
        if !inst.isRunning, let error = await model.perform(.start, on: vm.name, client.start(vm.name)) { return "start: \(error)" }
        guard isolate else { return nil }
        if let error = await model.perform(.stop, on: vm.name, client.stop(vm.name)) { return "stop after the first boot: \(error)" }
        if let error = await model.perform(.edit, on: vm.name, client.edit(vm.name, set: [".vmOpts.hanalima.usernet = false"])) {
            return "remove NIC 0: \(error)"
        }
        if let error = await model.perform(.start, on: vm.name, client.start(vm.name)) { return "start without NIC 0: \(error)" }
        return nil
    }

    /// Ready, NIC 0 as planned, and each NIC with a planned address holds a DHCP lease for it
    /// (others: any lease).
    private func verify(_ vm: TopologyPlan.PlannedVM) async -> String? {
        guard model.isReady(vm.name), let inst = model.instance(named: vm.name) else { return "not ready" }
        let wantsUsernet = !vm.bootstrapUsernet && !vm.options.setExpressions.contains(".vmOpts.hanalima.usernet = false")
        if inst.usesUsernet != wantsUsernet { return wantsUsernet ? "NIC 0 is missing" : "NIC 0 is still attached" }
        for _ in 0..<30 {
            await model.refreshNetworkStates()
            let missing = vm.nics.filter { nic in
                guard let net = model.virtualNetworks.first(where: { $0.name == nic.network }) else { return true }
                let address = model.address(of: inst, on: net)
                return nic.ip.map { address != $0 } ?? (address == nil)
            }
            if missing.isEmpty { return nil }
            try? await Task.sleep(for: .seconds(1))
        }
        return "no DHCP lease seen for its NICs"
    }

    // MARK: - delete

    func delete(_ arguments: MCPKit.JSONValue) throws -> String {
        guard let object = arguments.objectValue else { throw Failure.invalid("arguments must be an object") }
        if let unknown = object.keys.first(where: { !["key", "vms", "networks"].contains($0) }) { throw Failure.invalid("unknown argument: \(unknown)") }
        guard let key = object["key"]?.stringValue, !key.isEmpty else { throw Failure.invalid("key is required") }
        if let job = try existing(key: key, tool: "delete", input: arguments) { return JobStore.text(job, detail: false) }
        func names(_ field: String) throws -> [String] {
            guard let raw = object[field] else { return [] }
            guard let list = raw.arrayValue?.compactMap(\.stringValue), list.count == raw.arrayValue?.count else {
                throw Failure.invalid("\(field) must be an array of strings")
            }
            return list
        }
        let vms = try names("vms"), networks = try names("networks")
        guard !vms.isEmpty || !networks.isEmpty else { throw Failure.invalid("give vms and/or networks") }
        var vmIDs: [String: UUID] = [:]
        for name in vms {
            guard let id = model.metadata[name]?.id, state.ownsVM(id) else { throw Failure.invalid("\(name) was not made through MCP; delete it in the app") }
            vmIDs[name] = id
        }
        if let error = state.saveError { throw Failure.invalid("HanaLima can't save its MCP state (\(error)); nothing was started") }
        for name in networks where !state.ownsNetwork(name) {
            throw Failure.invalid("\(name) was not made through MCP; delete it in the app")
        }
        let summary = "delete " + (vms + networks).joined(separator: " ")
        let (job, _) = try state.jobs.submit(key: key, tool: "delete", input: arguments, summary: summary, needsApproval: true)
        enqueue(ApprovalRequest(jobID: job.id, kind: .delete(vms: vms, vmIDs: vmIDs, networks: networks)))
        return JobStore.text(job, detail: false)
    }

    /// Queues `request` for the sheet; a debug build run with HANALIMA_MCP_AUTO_APPROVE=1 (the
    /// MCP E2E test) allows it at once instead.
    private func enqueue(_ request: ApprovalRequest) {
        awaitingApproval.append(request)
        #if DEBUG
        if ProcessInfo.processInfo.environment["HANALIMA_MCP_AUTO_APPROVE"] == "1" { approve(request) }
        #endif
    }

    func approve(_ request: ApprovalRequest) {
        awaitingApproval.removeAll { $0.jobID == request.jobID }
        guard (try? state.jobs.approve(request.jobID)) != nil else { return }
        switch request.kind {
        case .delete(let vms, let vmIDs, let networks):
            Task { await runDelete(jobID: request.jobID, vms: vms, vmIDs: vmIDs, networks: networks) }
        case .build(let spec, let plan):
            // The Mac may have changed while the person decided.
            let now = TopologyPlanner.plan(spec, facts: facts())
            guard now.fingerprint == plan.fingerprint, now.problems.isEmpty else {
                state.jobs.record(request.jobID, JobTargetResult(target: "plan", outcome: "failed", message: "PLAN_STALE: the Mac changed; plan again"))
                return finish(request.jobID)
            }
            Task { await run(now, jobID: request.jobID) }
        }
    }

    func deny(_ request: ApprovalRequest) {
        awaitingApproval.removeAll { $0.jobID == request.jobID }
        try? state.jobs.deny(request.jobID)
    }

    /// The person turned AI operations off: deny waiting deletes, stop builds after their step.
    func cancelAll() {
        for job in state.jobs.jobs where !job.state.isFinished && ["apply", "delete"].contains(job.tool) {
            _ = try? state.jobs.cancel(job.id)
        }
        awaitingApproval.removeAll()
    }

    private func pruneDeletes() {
        if awaitingApproval.contains(where: { state.jobs.job($0.jobID)?.state != .awaitingApproval }) {
            awaitingApproval.removeAll { state.jobs.job($0.jobID)?.state != .awaitingApproval }
        }
    }

    private func runDelete(jobID id: String, vms: [String], vmIDs: [String: UUID], networks: [String]) async {
        func stopped() -> Bool { state.jobs.job(id)?.cancelRequested == true }
        for name in vms {
            if stopped() { return finish(id) }
            state.jobs.setCurrent(id, name)
            let error: String?
            if let approved = vmIDs[name], model.metadata[name]?.id == approved, state.ownsVM(approved) {
                error = await model.deleteNow(name)
            } else {
                error = "not the VM that was approved (renamed or made again); left alone"
            }
            state.jobs.record(id, JobTargetResult(target: name, outcome: error == nil ? "done" : "failed", message: error))
        }
        // Groups a build made and this delete emptied go too.
        for group in model.groupLayout.groups.map(\.name) where state.ownsGroup(group) && (model.groupMembers(group) ?? []).isEmpty {
            model.ungroup(group)
            state.forgetGroup(group)
            state.jobs.record(id, JobTargetResult(target: "group \(group)", outcome: "done"))
        }
        for name in networks {
            if stopped() { return finish(id) }
            state.jobs.setCurrent(id, name)
            var error: String?
            if let net = model.virtualNetworks.first(where: { $0.name == name }), !model.instances(using: net).isEmpty {
                error = "still used by \(model.instances(using: net).map(\.name).joined(separator: ", "))"
            } else {
                error = await model.deleteVirtualNetworkNow(name)
            }
            state.jobs.record(id, JobTargetResult(target: name, outcome: error == nil ? "done" : "failed", message: error))
        }
        finish(id)
    }
}
