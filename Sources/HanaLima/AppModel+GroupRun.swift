import Foundation
import LimaKit

/// Starting, stopping and hibernating every VM of a group (docs/12 chapter 5). The plan comes
/// from `GroupPlan.make` (which VMs, in which order, which are skipped or need a confirmation);
/// the window shows it in one sheet, then `GroupRunner` takes the VMs one at a time.
struct GroupRunRequest: Identifiable {
    let id = UUID()
    let group: String
    let plan: GroupPlan
    /// Memory of the VMs running now (for the start sheet's note).
    let runningMemory: Int64
    /// Free space where the saved states go, for hibernating (nil: unknown).
    let freeSpace: Int64?
}

/// A group-wide operation in progress or just finished, shown on the group page.
struct GroupRunState {
    let plan: GroupPlan
    var results: [GroupStepResult] = []
    /// The VM being worked on now.
    var current: String?
    var cancelRequested = false
    var finished = false

    var action: GroupAction { plan.action }
    /// Record ids of the VMs not reached yet (another group's run skips them). Ids, not names:
    /// a VM renamed meanwhile is still this run's.
    var pending: Set<UUID> {
        guard !finished else { return [] }
        return Set(plan.steps.dropFirst(results.count).map(\.id))
    }
}

extension GroupAction {
    var label: String {
        switch self {
        case .start: String(localized: "すべて起動")
        case .stop: String(localized: "すべて停止")
        case .hibernate: String(localized: "すべて休止")
        }
    }
}

extension AppModel {
    private func runKey(_ group: String) -> String { group.lowercased() }

    func groupRun(of group: String) -> GroupRunState? { groupRuns[runKey(group)] }

    func isGroupRunActive(_ group: String) -> Bool { groupRun(of: group).map { !$0.finished } ?? false }

    /// Prepares a group-wide operation and asks the window to show its sheet.
    func requestGroupRun(_ action: GroupAction, group: String) {
        guard let index = groupLayout.index(ofGroup: group) else { return }
        let name = groupLayout.groups[index].name
        guard !isGroupRunActive(name) else { return }
        let members = sidebarGroups.first { $0.name == name }?.members ?? []
        let plan = GroupPlan.make(action, members: memberFacts(members, for: action, group: name))
        let runningMemory = instances.filter(\.isRunning).reduce(Int64(0)) { $0 + ($1.memory ?? 0) }
        var free: Int64?
        if action == .hibernate, let dir = instances.first?.instanceDir.deletingLastPathComponent() {
            free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
        }
        selection = .group(name)
        groupRunRequest = GroupRunRequest(group: name, plan: plan, runningMemory: runningMemory, freeSpace: free)
    }

    /// What the planner needs to know about each member, in group order.
    private func memberFacts(_ members: [String], for action: GroupAction, group: String) -> [GroupMemberFacts] {
        let others = groupRuns.filter { $0.key != runKey(group) }.values.reduce(into: Set<UUID>()) { $0.formUnion($1.pending) }
        // A start checks the socket_vmnet mix against the running VMs and the ones it starts first.
        var startingFirst: [String] = instances.filter(\.isRunning).map(\.name)
        return members.compactMap { name -> GroupMemberFacts? in
            guard let inst = instance(named: name), let id = metadata[name]?.id else { return nil }
            let refusal = diskUnusableReason(name).map(\.title)
            var conflict: String?
            if action == .start && !inst.isRunning {
                conflict = networkConflict(starting: name, alongside: startingFirst)?.message
                if refusal == nil && !isBusy(name) { startingFirst.append(name) }
            }
            return GroupMemberFacts(
                name: name, id: id, running: inst.isRunning, busy: isBusy(name), hibernated: isHibernated(name),
                ready: isReady(name), hanaLimaDriver: inst.usesHanaLimaDriver, memory: inst.memory ?? 0,
                refusal: refusal,
                deletedNetworks: deletedNetworkSockets(of: inst).map(Self.networkName(ofSocket:)),
                networkConflict: conflict, inOtherRun: others.contains(id))
        }
    }

    /// Runs the confirmed plan; `approved` holds the confirmations ticked per VM.
    func startGroupRun(_ request: GroupRunRequest, approved: [String: Set<GroupConfirmation>]) {
        let key = runKey(request.group)
        groupRuns[key] = GroupRunState(plan: request.plan, current: request.plan.steps.first?.name)
        Task {
            _ = await GroupRunner.run(
                request.plan, approved: approved,
                isCancelled: { await MainActor.run { self.groupRuns[key]?.cancelRequested ?? true } },
                recheck: { step in await self.recheck(step, action: request.plan.action) },
                perform: { step, approvals in await self.performStep(step, action: request.plan.action, approvals: approvals) },
                progress: { result in
                    await MainActor.run {
                        self.groupRuns[key]?.results.append(result)
                        let done = self.groupRuns[key]?.results.count ?? 0
                        self.groupRuns[key]?.current = done < request.plan.steps.count ? request.plan.steps[done].name : nil
                    }
                })
            groupRuns[key]?.current = nil
            groupRuns[key]?.finished = true
        }
    }

    func cancelGroupRun(_ group: String) {
        groupRuns[runKey(group)]?.cancelRequested = true
    }

    /// Forgets a finished run's results.
    func clearGroupRun(_ group: String) {
        if groupRun(of: group)?.finished == true { groupRuns[runKey(group)] = nil }
    }

    /// The current name of the VM a step was planned for: it may have been renamed since, and a
    /// VM deleted and made again under the same name is another VM (docs/12 5.3).
    private func currentName(of step: GroupPlan.Step) -> String? {
        if metadata[step.name]?.id == step.id { return step.name }
        return metadata.first { $0.value.id == step.id }?.key
    }

    /// Why a step can no longer run as planned, checked just before it (nil: go ahead).
    private func recheck(_ step: GroupPlan.Step, action: GroupAction) -> String? {
        guard let name = currentName(of: step), let inst = instance(named: name) else {
            return String(localized: "見つかりません（削除されたか、作り直されました）。")
        }
        if isBusy(name) { return String(localized: "ほかの処理の最中です。") }
        switch action {
        case .start:
            if inst.isRunning { return String(localized: "すでに実行中です。") }
            return diskUnusableReason(name)?.title
        case .stop:
            return inst.isRunning ? nil : String(localized: "すでに停止しています。")
        case .hibernate:
            return hibernateBlocker(name)
        }
    }

    private func performStep(_ step: GroupPlan.Step, action: GroupAction,
                             approvals: Set<GroupConfirmation>) async -> GroupStepReport {
        guard let client, let name = currentName(of: step) else { return .failed(String(localized: "見つかりません。")) }
        switch action {
        case .start:
            if approvals.contains(.removeDeletedNICs), let inst = instance(named: name),
               let expression = deletedNICsExpression(of: inst) {
                // Only the networks confirmed in the sheet: one deleted since is not approved.
                let now = deletedNetworkSockets(of: inst).map(Self.networkName(ofSocket:)).joined(separator: ", ")
                guard now == step.confirmations[.removeDeletedNICs] else {
                    return .failed(String(localized: "計画のあとで、ほかのネットワークも削除されました。確かめてから、この仮想マシンだけを起動してください。"))
                }
                if let error = await perform(.edit, on: name, client.edit(name, set: [expression])) { return .failed(error) }
            }
            // Just before the start (another VM may have started meanwhile): the socket_vmnet mix.
            if !approvals.contains(.allowNetworkConflict), networkConflict(starting: name) != nil {
                return .failed(String(localized: "計画のあとで、socket_vmnet と HanaLima の仮想ネットワークの同時使用になりました。確かめてから、この仮想マシンだけを起動してください。"))
            }
            if let error = await perform(.start, on: name, client.start(name)) { return .failed(error) }
            return .done
        case .stop:
            if let error = await perform(.stop, on: name, client.stop(name)) { return .failed(error) }
            return .done
        case .hibernate:
            guard let failure = await hibernateNow(name, quiet: true) else { return .done }
            return failure.locked ? .failedStoppingRun(failure.message) : .failed(failure.message)
        }
    }
}
