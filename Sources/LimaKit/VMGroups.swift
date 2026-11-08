import Foundation

/// HanaLima's VM groups (docs/12): which VMs are in which group lives in each VM's record
/// (InstanceMetadata.group, by group name); this file keeps only the order of groups and VMs,
/// whether each group is expanded, and groups with no VMs yet.
public struct VMGroupLayout: Codable, Equatable, Sendable {
    public struct Group: Codable, Equatable, Sendable {
        public var name: String
        public var expanded: Bool
        /// Record ids (InstanceMetadata.id) in sidebar order.
        public var members: [UUID]

        public init(name: String, expanded: Bool = true, members: [UUID] = []) {
            self.name = name
            self.expanded = expanded
            self.members = members
        }
    }

    /// What the layout needs to know about each VM.
    public struct VM: Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var group: String?      // From the VM's record; nil or empty means no group.
        public var parent: UUID?       // The record's parent id, if a copy.

        public init(id: UUID, name: String, group: String?, parent: UUID?) {
            self.id = id
            self.name = name
            self.group = group
            self.parent = parent
        }
    }

    public var groups: [Group]
    public var ungrouped: [UUID]

    public init(groups: [Group] = [], ungrouped: [UUID] = []) {
        self.groups = groups
        self.ungrouped = ungrouped
    }

    public static let fileName = "groups.json"

    /// nil when the file is missing or can't be decoded (a damaged file is never overwritten by load).
    public static func load(from url: URL) -> VMGroupLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    /// Atomic write, pretty-printed, sorted keys.
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Index of the group with this name, ignoring case.
    public func index(ofGroup name: String) -> Int? {
        groups.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The layout repaired against the current VMs (docs/12 3.2).
    public func reconciled(with vms: [VM]) -> VMGroupLayout {
        var result = self
        let ordered = vms.sorted {
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
        var grouped = Array(repeating: [VM](), count: groups.count)
        var ungroupedVMs: [VM] = []
        var assigned = Set<UUID>()
        for vm in ordered where assigned.insert(vm.id).inserted {
            guard let name = vm.group, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                ungroupedVMs.append(vm)
                continue
            }
            let index: Int
            if let existing = result.index(ofGroup: name) {
                index = existing
            } else {
                index = result.groups.count
                result.groups.append(Group(name: name))
                grouped.append([])
            }
            grouped[index].append(vm)
        }

        var seen = Set<UUID>()
        for index in result.groups.indices {
            result.groups[index].members = Self.reconcile(
                result.groups[index].members, with: grouped[index], seen: &seen)
        }
        result.ungrouped = Self.reconcile(ungrouped, with: ungroupedVMs, seen: &seen)
        return result
    }

    private static func reconcile(_ ids: [UUID], with vms: [VM], seen: inout Set<UUID>) -> [UUID] {
        let valid = Set(vms.map(\.id))
        var result = ids.filter { valid.contains($0) && seen.insert($0).inserted }
        // New VMs in name order, but a copy only after its parent is placed when the parent is
        // new too (both missing, e.g. after groups.json was lost).
        var pending = vms.filter { !seen.contains($0.id) }
        let newIDs = Set(pending.map(\.id))
        // Remember the last new sibling so later copies do not reverse their name order.
        var lastCopy: [UUID: UUID] = [:]
        while !pending.isEmpty {
            let ready = pending.filter { vm in
                guard let parent = vm.parent, newIDs.contains(parent) else { return true }
                return seen.contains(parent)
            }
            // A cycle can't come from real records; place the rest as they are rather than loop.
            let batch = ready.isEmpty ? pending : ready
            for vm in batch where seen.insert(vm.id).inserted {
                if let parent = vm.parent,
                   let index = result.firstIndex(of: lastCopy[parent] ?? parent) {
                    result.insert(vm.id, at: index + 1)
                    lastCopy[parent] = vm.id
                } else {
                    result.append(vm.id)
                }
            }
            let placed = Set(batch.map(\.id))
            pending.removeAll { placed.contains($0.id) }
        }
        return result
    }
}
