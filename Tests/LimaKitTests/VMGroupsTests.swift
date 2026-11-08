import Foundation
import Testing
@testable import LimaKit

@Suite struct VMGroupsTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vmgroups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func vm(_ name: String, group: String? = nil, parent: UUID? = nil) -> VMGroupLayout.VM {
        VMGroupLayout.VM(id: UUID(), name: name, group: group, parent: parent)
    }

    @Test func missingFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(VMGroupLayout.load(from: dir.appending(path: VMGroupLayout.fileName)) == nil)
    }

    @Test func corruptFileIsLeftUntouched() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: VMGroupLayout.fileName)
        let data = Data("{damaged json".utf8)
        try data.write(to: url)
        #expect(VMGroupLayout.load(from: url) == nil)
        #expect(try Data(contentsOf: url) == data)
    }

    @Test func saveLoadRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: VMGroupLayout.fileName)
        let layout = VMGroupLayout(groups: [
            .init(name: "Lab", expanded: false, members: [UUID(), UUID()]),
            .init(name: "Empty"),
        ], ungrouped: [UUID()])
        try VMGroupLayout().save(to: url)
        try layout.save(to: url)
        #expect(VMGroupLayout.load(from: url) == layout)
        let json = try String(contentsOf: url, encoding: .utf8)
        #expect(json.contains("\n"))
        let expandedKey = try #require(json.range(of: "\"expanded\""))
        let membersKey = try #require(json.range(of: "\"members\""))
        #expect(expandedKey.lowerBound < membersKey.lowerBound)
        #expect(VMGroupLayout.fileName == "groups.json")
    }

    @Test func unknownGroupAddedAtEndExpanded() {
        let first = vm("alpha", group: "Lab")
        let second = vm("zulu", group: "lab")
        let other = vm("beta", group: "Other")
        let layout = VMGroupLayout(groups: [.init(name: "Existing", expanded: false)])
        let result = layout.reconciled(with: [second, other, first])
        #expect(result.groups == [
            .init(name: "Existing", expanded: false),
            .init(name: "Lab", members: [first.id, second.id]),
            .init(name: "Other", members: [other.id]),
        ])
    }

    @Test func emptyGroupsKeptInPlace() {
        let member = vm("guest", group: "Lab")
        let layout = VMGroupLayout(groups: [
            .init(name: "Before", expanded: false),
            .init(name: "Lab", members: [member.id]),
            .init(name: "After"),
        ])
        #expect(layout.reconciled(with: [member]) == layout)
        #expect(layout.reconciled(with: []).groups == [
            .init(name: "Before", expanded: false), .init(name: "Lab"), .init(name: "After"),
        ])
    }

    @Test func caseInsensitiveMatchingKeepsCasingAndExpansion() {
        let member = vm("guest", group: "lab")
        let layout = VMGroupLayout(groups: [.init(name: "Lab", expanded: false)])
        #expect(layout.index(ofGroup: "LAB") == 0)
        #expect(layout.index(ofGroup: "Missing") == nil)
        #expect(layout.reconciled(with: [member]).groups == [
            .init(name: "Lab", expanded: false, members: [member.id]),
        ])
    }

    @Test func staleIDsDropped() {
        let grouped = vm("grouped", group: "Lab")
        let ungrouped = vm("ungrouped")
        let layout = VMGroupLayout(
            groups: [.init(name: "Lab", members: [UUID(), grouped.id, UUID()])],
            ungrouped: [UUID(), ungrouped.id])
        let result = layout.reconciled(with: [grouped, ungrouped])
        #expect(result.groups[0].members == [grouped.id])
        #expect(result.ungrouped == [ungrouped.id])
    }

    @Test func recordMovesVMToAnotherGroup() {
        let member = vm("guest", group: "New")
        let layout = VMGroupLayout(groups: [
            .init(name: "Old", members: [member.id]), .init(name: "New"),
        ], ungrouped: [member.id])
        let result = layout.reconciled(with: [member])
        #expect(result.groups[0].members.isEmpty)
        #expect(result.groups[1].members == [member.id])
        #expect(result.ungrouped.isEmpty)
    }

    @Test func newVMsAppendedInNameOrder() {
        for group in [nil, "Lab"] as [String?] {
            let existing = vm("zulu", group: group)
            let alpha = vm("alpha", group: group)
            let beta = vm("beta", group: group)
            let layout = VMGroupLayout(
                groups: [.init(name: "Lab", members: group == nil ? [] : [existing.id])],
                ungrouped: group == nil ? [existing.id] : [])
            let result = layout.reconciled(with: [beta, existing, alpha])
            #expect((group == nil ? result.ungrouped : result.groups[0].members)
                == [existing.id, alpha.id, beta.id])
        }
    }

    @Test func copyInsertedAfterParentInGroup() {
        let parent = vm("parent", group: "Lab")
        let other = vm("other", group: "Lab")
        let copy = vm("copy", group: "lab", parent: parent.id)
        let layout = VMGroupLayout(groups: [.init(name: "Lab", members: [parent.id, other.id])])
        #expect(layout.reconciled(with: [other, parent, copy]).groups[0].members
            == [parent.id, copy.id, other.id])
    }

    @Test func copyInsertedAfterUngroupedParent() {
        let parent = vm("parent")
        let other = vm("other")
        let copy = vm("copy", parent: parent.id)
        let layout = VMGroupLayout(ungrouped: [parent.id, other.id])
        #expect(layout.reconciled(with: [other, parent, copy]).ungrouped
            == [parent.id, copy.id, other.id])
    }

    @Test func twoCopiesFollowParentInNameOrder() {
        for group in [nil, "Lab"] as [String?] {
            let parent = vm("parent", group: group)
            let other = vm("other", group: group)
            let alpha = vm("alpha-copy", group: group, parent: parent.id)
            let beta = vm("beta-copy", group: group, parent: parent.id)
            let layout = VMGroupLayout(
                groups: [.init(name: "Lab", members: group == nil ? [] : [parent.id, other.id])],
                ungrouped: group == nil ? [parent.id, other.id] : [])
            let result = layout.reconciled(with: [beta, other, alpha, parent])
            #expect((group == nil ? result.ungrouped : result.groups[0].members)
                == [parent.id, alpha.id, beta.id, other.id])
            #expect(result.reconciled(with: [parent, alpha, beta, other]) == result)
        }
    }

    @Test func duplicateIDsRemovedKeepingFirstValidOccurrence() {
        let member = vm("grouped", group: "Lab")
        let ungrouped = vm("ungrouped")
        let layout = VMGroupLayout(groups: [
            .init(name: "Wrong", members: [member.id, ungrouped.id]),
            .init(name: "Lab", members: [ungrouped.id, member.id, member.id]),
            .init(name: "lab", members: [member.id]),
        ], ungrouped: [member.id, ungrouped.id, ungrouped.id])
        let result = layout.reconciled(with: [member, ungrouped])
        #expect(result.groups.map(\.members) == [[], [member.id], []])
        #expect(result.ungrouped == [ungrouped.id])
    }

    @Test func existingOrderPreserved() {
        for group in [nil, "Lab"] as [String?] {
            let alpha = vm("alpha", group: group)
            let beta = vm("beta", group: group)
            let zulu = vm("zulu", group: group)
            let ids = [zulu.id, alpha.id, beta.id]
            let layout = VMGroupLayout(
                groups: [.init(name: "Lab", members: group == nil ? [] : ids)],
                ungrouped: group == nil ? ids : [])
            #expect(layout.reconciled(with: [beta, alpha, zulu]) == layout)
        }
    }

    @Test func emptyAndWhitespaceGroupsAreUngrouped() {
        let empty = vm("alpha", group: "")
        let whitespace = vm("beta", group: " \t\n")
        let absent = vm("gamma")
        let result = VMGroupLayout().reconciled(with: [absent, whitespace, empty])
        #expect(result.groups.isEmpty)
        #expect(result.ungrouped == [empty.id, whitespace.id, absent.id])
    }

    @Test func copyWithParentElsewhereAppended() {
        let parent = vm("parent", group: "Other")
        let existing = vm("existing", group: "Lab")
        let copy = vm("copy", group: "Lab", parent: parent.id)
        let orphan = vm("orphan", group: "Lab", parent: UUID())
        let layout = VMGroupLayout(groups: [.init(name: "Lab", members: [existing.id])])
        #expect(layout.reconciled(with: [orphan, copy, existing, parent]).groups[0].members
            == [existing.id, copy.id, orphan.id])
    }

    /// Both missing (groups.json lost): the parent is placed first even if the copy's name sorts before it.
    @Test func newCopyFollowsANewParentThatSortsAfterIt() {
        let parent = UUID(), copy = UUID()
        let layout = VMGroupLayout().reconciled(with: [
            .init(id: parent, name: "zulu", group: nil, parent: nil),
            .init(id: copy, name: "alpha", group: nil, parent: parent),
        ])
        #expect(layout.ungrouped == [parent, copy])
    }
}
