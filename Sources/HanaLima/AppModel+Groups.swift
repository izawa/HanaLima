import Foundation
import LimaKit
import NetworkKit

/// VM groups in the sidebar (docs/12). Which group a VM is in lives in its record
/// (`InstanceMetadata.group`, by name); `groups.json` keeps the order, the expanded state and
/// groups with no VMs yet.
extension AppModel {
    static var groupLayoutURL: URL { NetworkPaths.supportDirectory.appending(path: VMGroupLayout.fileName) }

    /// A group as the sidebar shows it: member names in order.
    struct SidebarGroup: Equatable {
        var name: String
        var expanded: Bool
        var members: [String]
    }

    /// Groups with their members' names, from the layout and the records.
    var sidebarGroups: [SidebarGroup] {
        let names = namesByID
        return groupLayout.groups.map { g in
            SidebarGroup(name: g.name, expanded: g.expanded,
                         members: g.members.compactMap { names[$0] } + pendingNames(inGroup: g.name))
        }
    }

    /// VMs in no group, in order, then ones still being created that aren't headed for a group.
    var ungroupedNames: [String] {
        let names = namesByID
        let listed = groupLayout.ungrouped.compactMap { names[$0] }
        // A VM without a record yet (listed before the first reconcile) goes at the end.
        let placed = Set(listed).union(groupLayout.groups.flatMap { $0.members.compactMap { names[$0] } })
        let unrecorded = instances.map(\.name).filter { !placed.contains($0) && pendingGroups[$0] == nil }
        return listed + unrecorded + pendingNames(inGroup: nil)
    }

    private var namesByID: [UUID: String] {
        Dictionary(metadata.map { ($0.value.id, $0.key) }, uniquingKeysWith: { a, _ in a })
    }

    /// VMs being created or copied that the layout doesn't have yet, by the group they will be in.
    private func pendingNames(inGroup group: String?) -> [String] {
        guard let group else {
            // Headed for no group: only until listed (then `ungroupedNames` lists them).
            let existing = Set(instances.map(\.name))
            return operations
                .filter { [.create, .clone].contains($0.value.kind) && !existing.contains($0.key) && pendingGroups[$0.key] == nil }
                .keys.sorted()
        }
        // Headed for a group: until the layout has them there (a busy VM's record isn't read yet).
        let placed = Set(groupLayout.groups.flatMap(\.members))
        return pendingGroups
            .filter { $0.value.caseInsensitiveCompare(group) == .orderedSame && !(metadata[$0.key].map { placed.contains($0.id) } ?? false) }
            .keys.sorted()
    }

    func groupName(of vm: String) -> String? {
        guard let group = metadata[vm]?.group, !group.isEmpty,
              let i = groupLayout.index(ofGroup: group) else { return nil }
        return groupLayout.groups[i].name
    }

    /// Repairs the layout against the records (after each listing) and saves it if it changed.
    func updateGroupLayout() {
        // A VM still being created or copied goes where it is headed, before its record says so.
        let vms = metadata.map { name, meta in
            VMGroupLayout.VM(id: meta.id, name: name, group: pendingGroups[name] ?? meta.group, parent: meta.parent?.id)
        }
        let layout = groupLayout.reconciled(with: vms)
        if layout != groupLayout { setGroupLayout(layout) }
    }

    func loadGroupLayout() {
        groupLayout = VMGroupLayout.load(from: Self.groupLayoutURL) ?? VMGroupLayout()
    }

    private func setGroupLayout(_ layout: VMGroupLayout) {
        groupLayout = layout
        do {
            try FileManager.default.createDirectory(at: NetworkPaths.supportDirectory, withIntermediateDirectories: true)
            try layout.save(to: Self.groupLayoutURL)
        } catch {
            alert = AlertMessage(title: String(localized: "グループの並びを保存できませんでした"), message: error.localizedDescription)
        }
    }

    // MARK: - Editing

    /// Why `name` can't be a group's name (nil: it can). `current`: the group being renamed.
    func groupNameProblem(_ name: String, renaming current: String? = nil) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return String(localized: "グループの名前を入力してください。") }
        if let i = groupLayout.index(ofGroup: trimmed), groupLayout.groups[i].name != current {
            return String(localized: "「\(trimmed)」という名前のグループがすでにあります。")
        }
        return nil
    }

    /// A new group, "新規グループ" (numbered if taken), holding `vms`; its name opens for editing.
    @discardableResult
    func newGroup(with vms: [String] = []) -> String {
        let base = String(localized: "新規グループ")
        var name = base
        var n = 2
        while groupLayout.index(ofGroup: name) != nil { name = "\(base) \(n)"; n += 1 }
        var layout = groupLayout
        layout.groups.append(VMGroupLayout.Group(name: name))
        setGroupLayout(layout)
        for vm in vms { moveVM(vm, toGroup: name) }
        selection = .group(name)
        renamingGroup = name
        return name
    }

    /// Renames a group, rewriting its VMs' records; puts back the ones written if one fails.
    func renameGroup(_ old: String, to new: String) {
        let new = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard new != old, let i = groupLayout.index(ofGroup: old) else { return }
        if let problem = groupNameProblem(new, renaming: groupLayout.groups[i].name) {
            alert = AlertMessage(title: String(localized: "グループの名前を変更できませんでした"), message: problem)
            return
        }
        let members = metadata.filter { $0.value.group.map { $0.caseInsensitiveCompare(old) == .orderedSame } ?? false }
        guard writeGroup(new, to: Array(members.keys), title: String(localized: "グループの名前を変更できませんでした")) else { return }
        for (vm, group) in pendingGroups where group.caseInsensitiveCompare(old) == .orderedSame { pendingGroups[vm] = new }
        var layout = groupLayout
        layout.groups[i].name = new
        setGroupLayout(layout)
        if selection == .group(old) { selection = .group(new) }
    }

    /// Takes the VMs out of the group (to the top of the ungrouped VMs) and removes it.
    func ungroup(_ name: String) {
        guard let i = groupLayout.index(ofGroup: name) else { return }
        let ids = groupLayout.groups[i].members
        let members = metadata.filter { ids.contains($0.value.id) }.map(\.key)
        guard writeGroup(nil, to: members, title: String(localized: "グループを解除できませんでした")) else { return }
        for (vm, group) in pendingGroups where group.caseInsensitiveCompare(name) == .orderedSame { pendingGroups[vm] = nil }
        var layout = groupLayout
        layout.groups.remove(at: i)
        layout.ungrouped.insert(contentsOf: ids, at: 0)
        setGroupLayout(layout)
        if selection == .group(name) { selection = nil }
    }

    /// Moves `vm` into `group` (nil: out of any group) at `index` of that list as it is now
    /// (nil: the end).
    func moveVM(_ vm: String, toGroup group: String?, at index: Int? = nil) {
        guard let meta = metadata[vm] else { return }
        let target = group.flatMap { groupLayout.index(ofGroup: $0) }
        if group != nil && target == nil { return }
        let groupName = target.map { groupLayout.groups[$0].name }
        if (meta.group ?? "").caseInsensitiveCompare(groupName ?? "") != .orderedSame {
            guard writeGroup(groupName, to: [vm], title: String(localized: "グループへ移動できませんでした")) else { return }
        }
        var layout = groupLayout
        var index = index
        // Positions count the target list before the move, as NSOutlineView proposes them.
        func remove(from list: inout [UUID], isTarget: Bool) {
            guard let from = list.firstIndex(of: meta.id) else { return }
            list.remove(at: from)
            if isTarget, let i = index, from < i { index = i - 1 }
        }
        for g in layout.groups.indices { remove(from: &layout.groups[g].members, isTarget: g == target) }
        remove(from: &layout.ungrouped, isTarget: target == nil)
        if let target {
            let count = layout.groups[target].members.count
            layout.groups[target].members.insert(meta.id, at: min(max(index ?? count, 0), count))
        } else {
            let count = layout.ungrouped.count
            layout.ungrouped.insert(meta.id, at: min(max(index ?? count, 0), count))
        }
        setGroupLayout(layout)
    }

    /// Moves the group at `from` to before the group now at `to`.
    func moveGroup(from: Int, to: Int) {
        guard groupLayout.groups.indices.contains(from) else { return }
        var layout = groupLayout
        layout.groups.move(fromOffsets: [from], toOffset: min(max(to, 0), layout.groups.count))
        setGroupLayout(layout)
    }

    func setGroupExpanded(_ name: String, _ expanded: Bool) {
        guard let i = groupLayout.index(ofGroup: name), groupLayout.groups[i].expanded != expanded else { return }
        var layout = groupLayout
        layout.groups[i].expanded = expanded
        setGroupLayout(layout)
    }

    /// Writes `group` into the records of `vms`; on a failure puts back the ones already written
    /// and shows why. Returns whether all were written.
    private func writeGroup(_ group: String?, to vms: [String], title: String) -> Bool {
        var written: [(String, InstanceMetadata)] = []
        for vm in vms {
            guard var meta = metadata[vm] else { continue }
            let old = meta
            meta.group = group
            do {
                try meta.save()
                metadata[vm] = meta
                written.append((vm, old))
            } catch {
                for (name, previous) in written {
                    try? previous.save()
                    metadata[name] = previous
                }
                alert = AlertMessage(title: title, message: error.localizedDescription)
                return false
            }
        }
        return true
    }

    /// Running VMs and all VMs in a group, for the group row's "2/5".
    func groupCounts(_ group: SidebarGroup) -> (running: Int, total: Int) {
        let running = group.members.filter { name in
            instance(named: name)?.isRunning == true && !isPaused(name)
        }.count
        return (running, group.members.count)
    }
}
