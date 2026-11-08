import Foundation

/// What a drop in HanaLima's sidebar means (docs/12 4.2), given NSOutlineView's proposed item and
/// child index. Kept free of AppKit so the rules can be tested; the sidebar retargets the drop to
/// `target` (so the insertion line shows where it goes) and maps `operation` to a drag operation.
public enum SidebarDropRule {
    public enum Dragged: Equatable, Sendable { case vm(String), group(String) }
    /// The proposed item: the root, the 「仮想マシン」 section, a group, a VM, or anything else.
    public enum Place: Equatable, Sendable { case root, vmSection, group(String), vm(String), other }

    public enum Operation: Equatable, Sendable {
        /// Refused: nothing happens.
        case none
        /// A line where it goes, or a highlighted group.
        case move
        /// The plus: two VMs in no group make a new group.
        case newGroup
    }

    public struct Group: Equatable, Sendable {
        public var name: String
        public var expanded: Bool
        public var members: [String]
        public init(name: String, expanded: Bool, members: [String]) {
            self.name = name
            self.expanded = expanded
            self.members = members
        }
    }

    public struct Decision: Equatable, Sendable {
        public var operation: Operation
        public var target: Place
        public var index: Int
        public init(_ operation: Operation, _ target: Place = .other, _ index: Int = 0) {
            self.operation = operation
            self.target = target
            self.index = index
        }
        public static let none = Decision(.none)
    }

    /// NSOutlineViewDropOnItemIndex: a drop on the item rather than between its children.
    public static let onItem = -1

    /// Children of the 「仮想マシン」 section are the groups, then the VMs in no group, so a
    /// section index counts the groups first.
    public static func decide(_ dragged: Dragged?, on target: Place, at index: Int,
                              groups: [Group], ungrouped: [String]) -> Decision {
        switch dragged {
        case .group:
            // Groups only reorder among groups; onto a group would nest, so it is refused.
            if target == .vmSection, index >= 0 { return Decision(.move, .vmSection, min(index, groups.count)) }
            return .none
        case .vm(let vm):
            switch target {
            case .group(let g) where index == onItem:
                // Into a group (highlighted); nothing if it is already there.
                let members = groups.first { $0.name == g }?.members ?? []
                return members.contains(vm) ? .none : Decision(.move, .group(g), onItem)
            case .group(let g):
                return Decision(.move, .group(g), index)
            case .vm(let other) where index == onItem:
                if other == vm { return .none }
                if let g = groups.first(where: { $0.members.contains(other) }) {
                    // On a VM in a group: no nesting, so the line goes before it.
                    return Decision(.move, .group(g.name), g.members.firstIndex(of: other)!)
                }
                guard let at = ungrouped.firstIndex(of: other) else { return .none }
                if !ungrouped.contains(vm) {
                    // A VM from a group onto one in no group: out of its group, before it.
                    return Decision(.move, .vmSection, groups.count + at)
                }
                return Decision(.newGroup, .vm(other), onItem)
            case .vmSection where index >= 0:
                if index < groups.count {
                    // A VM can't sit between groups: after an expanded group, its end; otherwise
                    // the top of the VMs in no group.
                    if index > 0, groups[index - 1].expanded {
                        return Decision(.move, .group(groups[index - 1].name), groups[index - 1].members.count)
                    }
                    return Decision(.move, .vmSection, groups.count)
                }
                return Decision(.move, .vmSection, min(index, groups.count + ungrouped.count))
            case .root where index >= 0:
                // Below the VMs, between the sections: the end of the VMs in no group.
                return Decision(.move, .vmSection, groups.count + ungrouped.count)
            default:
                return .none
            }
        case nil:
            return .none
        }
    }
}
