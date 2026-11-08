import Observation
import SwiftUI

enum Item: Hashable, CustomStringConvertible {
    case group(String), vm(String), disks

    var description: String {
        switch self {
        case .group(let n): "group:\(n)"
        case .vm(let n): "vm:\(n)"
        case .disks: "disks"
        }
    }
}

struct VMGroup: Identifiable {
    var name: String
    var members: [String]
    var expanded = true
    var id: String { name }
}

@Observable @MainActor
final class Store {
    var groups = [
        VMGroup(name: "隔離テスト", members: ["gateway", "guest1", "guest2"]),
        VMGroup(name: "ディストリ", members: ["fedora", "ubuntu-lts", "ubuntu-24.04"]),
        VMGroup(name: "空", members: []),
    ]
    var ungrouped = ["hanalima-dev", "macOS27", "JAIST-Alumni"]
    var selection: Item?
    var renaming: String?
    /// The AppKit outline has opened the editor for `renaming`.
    var renamingStarted = true
    var events: [String] = []
    /// Set by the ＋ menu; the outline creates the group and opens its name for editing.
    var requestNewGroup = false

    func note(_ s: String) {
        events.append(s)
        print("EVENT \(s)")
    }

    func groupIndex(of vm: String) -> Int? { groups.firstIndex { $0.members.contains(vm) } }

    func remove(_ vm: String) {
        if let g = groupIndex(of: vm) { groups[g].members.removeAll { $0 == vm } }
        ungrouped.removeAll { $0 == vm }
    }

    func move(_ vms: [String], toGroup name: String, at index: Int? = nil) {
        guard let g = groups.firstIndex(where: { $0.name == name }) else { return }
        for vm in vms { remove(vm) }
        let at = min(index ?? groups[g].members.count, groups[g].members.count)
        groups[g].members.insert(contentsOf: vms, at: at)
        note("move \(vms) -> group \(name) at \(at)")
    }

    func moveOut(_ vms: [String], at index: Int? = nil) {
        for vm in vms { remove(vm) }
        let at = min(index ?? ungrouped.count, ungrouped.count)
        ungrouped.insert(contentsOf: vms, at: at)
        note("move \(vms) -> ungrouped at \(at)")
    }

    /// Places `vm` at `index` of a group's members (nil: the ungrouped VMs), where `index` counts
    /// the list as it was before the drag (NSOutlineView's convention).
    func place(_ vm: String, inGroup name: String?, at index: Int) {
        var index = index
        if let name, let g = groups.firstIndex(where: { $0.name == name }) {
            if let from = groups[g].members.firstIndex(of: vm), from < index { index -= 1 }
            remove(vm)
            groups[g].members.insert(vm, at: max(0, min(index, groups[g].members.count)))
            note("place \(vm) in \(name) at \(index) = \(groups[g].members)")
        } else {
            if let from = ungrouped.firstIndex(of: vm), from < index { index -= 1 }
            remove(vm)
            ungrouped.insert(vm, at: max(0, min(index, ungrouped.count)))
            note("place \(vm) ungrouped at \(index) = \(ungrouped)")
        }
    }

    /// A new group named 新規グループ (numbered if taken) holding `vms`, after the other groups.
    func addGroup(with vms: [String]) -> String {
        var name = "新規グループ"
        var n = 2
        while groups.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "新規グループ \(n)"; n += 1 }
        for vm in vms { remove(vm) }
        groups.append(VMGroup(name: name, members: vms))
        note("new group \(name) with \(vms)")
        return name
    }

    func ungroup(_ name: String) {
        guard let g = groups.firstIndex(where: { $0.name == name }) else { return }
        ungrouped.insert(contentsOf: groups[g].members, at: 0)
        groups.remove(at: g)
        if selection == .group(name) { selection = nil }
        note("ungroup \(name)")
    }

    func insert(_ vms: [String], before target: String) {
        for vm in vms { remove(vm) }
        if let g = groupIndex(of: target), let i = groups[g].members.firstIndex(of: target) {
            groups[g].members.insert(contentsOf: vms, at: i)
            note("insert \(vms) before \(target) in \(groups[g].name)")
        } else if let i = ungrouped.firstIndex(of: target) {
            ungrouped.insert(contentsOf: vms, at: i)
            note("insert \(vms) before \(target) in ungrouped")
        }
    }

    func reorder(inGroup name: String, from: IndexSet, to: Int) {
        guard let g = groups.firstIndex(where: { $0.name == name }) else { return }
        groups[g].members.move(fromOffsets: from, toOffset: to)
        note("reorder in \(name): \(Array(from)) -> \(to) = \(groups[g].members)")
    }

    func reorderUngrouped(from: IndexSet, to: Int) {
        ungrouped.move(fromOffsets: from, toOffset: to)
        note("reorder ungrouped: \(Array(from)) -> \(to) = \(ungrouped)")
    }

    func reorderGroups(from: IndexSet, to: Int) {
        groups.move(fromOffsets: from, toOffset: to)
        note("reorder groups: \(Array(from)) -> \(to) = \(groups.map(\.name))")
    }

    func rename(_ old: String, to new: String) {
        // Names are the groups' identity (docs/12 4.2): no empty or duplicate names, ignoring case.
        guard let g = groups.firstIndex(where: { $0.name == old }), !new.isEmpty,
              !groups.contains(where: { $0.name != old && $0.name.caseInsensitiveCompare(new) == .orderedSame })
        else { renaming = nil; return }
        groups[g].name = new
        if selection == .group(old) { selection = .group(new) }
        renaming = nil
        note("rename \(old) -> \(new)")
    }

    /// The rows as the sidebar should show them, for mapping table rows to items.
    var flattened: [String] {
        var rows = ["<section 仮想マシン>"]
        for g in groups {
            rows.append("group:\(g.name)")
            if g.expanded { rows += g.members.map { "vm:\($0)" } }
        }
        rows += ungrouped.map { "vm:\($0)" }
        rows += ["<section ストレージ>", "disks"]
        return rows
    }
}
