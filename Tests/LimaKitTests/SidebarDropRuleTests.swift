import Testing
@testable import LimaKit

/// The sidebar's drop rules (docs/12 4.2), with NSOutlineView's proposals for each spot.
@Suite struct SidebarDropRuleTests {
    typealias R = SidebarDropRule
    let groups = [
        R.Group(name: "lab", expanded: true, members: ["gateway", "guest1"]),
        R.Group(name: "distros", expanded: false, members: ["fedora"]),
        R.Group(name: "empty", expanded: true, members: []),
    ]
    let ungrouped = ["dev", "mac", "old"]

    func decide(_ d: R.Dragged, _ p: R.Place, _ i: Int) -> R.Decision {
        R.decide(d, on: p, at: i, groups: groups, ungrouped: ungrouped)
    }

    @Test func vmBetweenUngroupedVMsIsALine() {
        #expect(decide(.vm("guest1"), .vmSection, 4) == R.Decision(.move, .vmSection, 4))
    }

    @Test func vmBelowEverythingGoesToTheEnd() {
        #expect(decide(.vm("guest1"), .root, 1) == R.Decision(.move, .vmSection, 6))
        #expect(decide(.vm("guest1"), .vmSection, 99) == R.Decision(.move, .vmSection, 6))
    }

    @Test func vmOntoAnotherGroupHighlightsIt() {
        #expect(decide(.vm("dev"), .group("distros"), R.onItem) == R.Decision(.move, .group("distros"), R.onItem))
        #expect(decide(.vm("dev"), .group("empty"), R.onItem) == R.Decision(.move, .group("empty"), R.onItem))
    }

    @Test func vmOntoItsOwnGroupDoesNothing() {
        #expect(decide(.vm("guest1"), .group("lab"), R.onItem) == .none)
    }

    @Test func vmBetweenMembersIsALine() {
        #expect(decide(.vm("dev"), .group("lab"), 1) == R.Decision(.move, .group("lab"), 1))
    }

    @Test func vmOntoAGroupedVMGoesBeforeIt() {
        #expect(decide(.vm("dev"), .vm("guest1"), R.onItem) == R.Decision(.move, .group("lab"), 1))
    }

    @Test func twoUngroupedVMsMakeANewGroup() {
        #expect(decide(.vm("dev"), .vm("mac"), R.onItem) == R.Decision(.newGroup, .vm("mac"), R.onItem))
    }

    @Test func groupedVMOntoAnUngroupedOneLeavesItsGroup() {
        #expect(decide(.vm("gateway"), .vm("mac"), R.onItem) == R.Decision(.move, .vmSection, 4))
    }

    @Test func vmOntoItselfOrOtherSectionsIsRefused() {
        #expect(decide(.vm("dev"), .vm("dev"), R.onItem) == .none)
        #expect(decide(.vm("dev"), .other, R.onItem) == .none)
        #expect(decide(.vm("dev"), .other, 0) == .none)
    }

    @Test func vmBetweenGroupsIsRetargeted() {
        // After the expanded "lab": its end. After the collapsed "distros": the top of the ungrouped VMs.
        #expect(decide(.vm("dev"), .vmSection, 1) == R.Decision(.move, .group("lab"), 2))
        #expect(decide(.vm("dev"), .vmSection, 2) == R.Decision(.move, .vmSection, 3))
        #expect(decide(.vm("dev"), .vmSection, 0) == R.Decision(.move, .vmSection, 3))
    }

    @Test func groupsOnlyReorderAmongGroups() {
        #expect(decide(.group("distros"), .vmSection, 0) == R.Decision(.move, .vmSection, 0))
        #expect(decide(.group("lab"), .vmSection, 5) == R.Decision(.move, .vmSection, 3))
        #expect(decide(.group("lab"), .group("empty"), R.onItem) == .none)
        #expect(decide(.group("lab"), .group("empty"), 0) == .none)
        #expect(decide(.group("lab"), .vm("dev"), R.onItem) == .none)
    }
}
