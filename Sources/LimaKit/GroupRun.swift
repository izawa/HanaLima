import Foundation

public enum GroupAction: String, Sendable, CaseIterable {
    case start, stop, hibernate
}

/// A snapshot of one member VM, gathered in group order.
public struct GroupMemberFacts: Equatable, Sendable {
    public var name: String
    public var id: UUID
    public var running: Bool
    public var busy: Bool
    public var hibernated: Bool
    public var ready: Bool
    public var hanaLimaDriver: Bool
    public var memory: Int64
    public var refusal: String?
    public var deletedNetworks: [String]
    public var networkConflict: String?
    public var inOtherRun: Bool

    public init(name: String, id: UUID, running: Bool, busy: Bool, hibernated: Bool,
                ready: Bool, hanaLimaDriver: Bool, memory: Int64, refusal: String?,
                deletedNetworks: [String], networkConflict: String?, inOtherRun: Bool) {
        self.name = name
        self.id = id
        self.running = running
        self.busy = busy
        self.hibernated = hibernated
        self.ready = ready
        self.hanaLimaDriver = hanaLimaDriver
        self.memory = memory
        self.refusal = refusal
        self.deletedNetworks = deletedNetworks
        self.networkConflict = networkConflict
        self.inOtherRun = inOtherRun
    }
}

public enum GroupConfirmation: String, Sendable, Hashable, CaseIterable {
    case removeDeletedNICs, allowNetworkConflict
}

public enum GroupSkipReason: Equatable, Sendable {
    case alreadyRunning, alreadyStopped, hibernated, busy, notHanaLimaDriver, notReady, inOtherRun
    case refused(String)
    case deletedNetworksWhileHibernated
}

public struct GroupPlan: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public var name: String
        public var id: UUID
        public var memory: Int64
        /// Details for each required confirmation, supplied to the app for display.
        public var confirmations: [GroupConfirmation: String]
        public var resumes: Bool

        public init(name: String, id: UUID, memory: Int64,
                    confirmations: [GroupConfirmation: String], resumes: Bool) {
            self.name = name
            self.id = id
            self.memory = memory
            self.confirmations = confirmations
            self.resumes = resumes
        }
    }

    public struct Skip: Equatable, Sendable {
        public var name: String
        public var reason: GroupSkipReason

        public init(name: String, reason: GroupSkipReason) {
            self.name = name
            self.reason = reason
        }
    }

    public var action: GroupAction
    public var steps: [Step]
    public var skipped: [Skip]

    public init(action: GroupAction, steps: [Step], skipped: [Skip]) {
        self.action = action
        self.steps = steps
        self.skipped = skipped
    }

    public var memoryToStart: Int64 {
        action == .start ? steps.reduce(0) { $0 + $1.memory } : 0
    }

    public static func make(_ action: GroupAction, members: [GroupMemberFacts]) -> GroupPlan {
        var plan = GroupPlan(action: action, steps: [], skipped: [])
        let ordered = action == .start ? members : Array(members.reversed())
        for member in ordered {
            let reason: GroupSkipReason?
            switch action {
            case .start:
                if member.running { reason = .alreadyRunning }
                else if member.busy { reason = .busy }
                else if member.inOtherRun { reason = .inOtherRun }
                else if let refusal = member.refusal { reason = .refused(refusal) }
                else if member.hibernated && !member.deletedNetworks.isEmpty {
                    reason = .deletedNetworksWhileHibernated
                } else { reason = nil }
            case .stop, .hibernate:
                if member.busy { reason = .busy }
                else if member.inOtherRun { reason = .inOtherRun }
                else if !member.running && member.hibernated { reason = .hibernated }
                else if !member.running { reason = .alreadyStopped }
                else if action == .hibernate && !member.hanaLimaDriver { reason = .notHanaLimaDriver }
                else if action == .hibernate && !member.ready { reason = .notReady }
                else { reason = nil }
            }
            if let reason {
                plan.skipped.append(Skip(name: member.name, reason: reason))
                continue
            }
            var confirmations: [GroupConfirmation: String] = [:]
            if action == .start {
                if !member.deletedNetworks.isEmpty {
                    confirmations[.removeDeletedNICs] = member.deletedNetworks.joined(separator: ", ")
                }
                if let conflict = member.networkConflict {
                    confirmations[.allowNetworkConflict] = conflict
                }
            }
            plan.steps.append(Step(name: member.name, id: member.id, memory: member.memory,
                                   confirmations: confirmations, resumes: action == .start && member.hibernated))
        }
        return plan
    }
}

public enum GroupStepOutcome: Equatable, Sendable {
    case done
    case skipped(String)
    case notConfirmed
    case failed(String)
    case notRun
}

public struct GroupStepResult: Equatable, Sendable {
    public var name: String
    public var outcome: GroupStepOutcome

    public init(name: String, outcome: GroupStepOutcome) {
        self.name = name
        self.outcome = outcome
    }
}

public enum GroupStepReport: Equatable, Sendable {
    case done
    case failed(String)
    /// The remaining steps would fail for the same reason, so stop the run.
    case failedStoppingRun(String)
}

public enum GroupRunner {
    /// Runs sequentially. Cancellation lets the current step finish; every step gets a result and progress update.
    public static func run(
        _ plan: GroupPlan,
        approved: [String: Set<GroupConfirmation>],
        isCancelled: @Sendable () async -> Bool,
        recheck: @Sendable (GroupPlan.Step) async -> String?,
        perform: @Sendable (GroupPlan.Step, Set<GroupConfirmation>) async -> GroupStepReport,
        progress: @Sendable (GroupStepResult) async -> Void
    ) async -> [GroupStepResult] {
        var results: [GroupStepResult] = []
        var stopped = false
        for step in plan.steps {
            let outcome: GroupStepOutcome
            if !stopped { stopped = await isCancelled() }
            if stopped {
                outcome = .notRun
            } else {
                let approvals = approved[step.name] ?? []
                if !Set(step.confirmations.keys).isSubset(of: approvals) {
                    outcome = .notConfirmed
                } else if let reason = await recheck(step) {
                    outcome = .skipped(reason)
                } else {
                    switch await perform(step, approvals) {
                    case .done: outcome = .done
                    case .failed(let reason): outcome = .failed(reason)
                    case .failedStoppingRun(let reason):
                        outcome = .failed(reason)
                        stopped = true
                    }
                }
            }
            let result = GroupStepResult(name: step.name, outcome: outcome)
            results.append(result)
            await progress(result)
        }
        return results
    }
}
