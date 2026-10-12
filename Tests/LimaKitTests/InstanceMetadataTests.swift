import Foundation
import Testing
@testable import LimaKit

@Suite struct InstanceMetadataTests {
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-meta-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func vm(_ root: URL, _ name: String) throws -> (name: String, dir: URL) {
        let dir = root.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (name, dir)
    }

    @Test func givesNewVMsARecord() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try vm(root, "a")
        let records = InstanceMetadata.reconcile([a])
        #expect(records["a"]?.parent == nil)
        #expect(InstanceMetadata.load(instanceDir: a.dir) == records["a"])
        #expect(InstanceMetadata.reconcile([a]) == records)  // stable
    }

    /// limactl clone copies hanalima-vm.json too: the copy gets a new id with the original as parent.
    @Test func cliCloneBecomesACopy() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try vm(root, "a"), b = try vm(root, "b")
        let original = InstanceMetadata(instanceDir: a.dir, note: "base")
        try original.save()
        try FileManager.default.copyItem(at: InstanceMetadata.url(instanceDir: a.dir), to: InstanceMetadata.url(instanceDir: b.dir))
        let records = InstanceMetadata.reconcile([b, a])  // order must not matter
        #expect(records["a"] == original)
        #expect(records["b"]?.id != original.id)
        #expect(records["b"]?.parent?.id == original.id)
        #expect(records["b"]?.parent?.name == "a")
        #expect(records["b"]?.note == "")
        #expect(InstanceLineage(records).children(of: "a") == ["b"])
        #expect(InstanceLineage(records).parentName(of: "b") == "a")
    }

    @Test func renameKeepsTheIDAndLineage() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try vm(root, "a")
        let records = InstanceMetadata.reconcile([a])
        let copy = try vm(root, "copy")
        try InstanceMetadata(instanceDir: copy.dir, parent: .init(id: records["a"]!.id, name: "a", copiedAt: .now)).save()
        let renamed = root.appending(path: "renamed", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: a.dir, to: renamed)
        let after = InstanceMetadata.reconcile([("renamed", renamed), copy])
        #expect(after["renamed"]?.id == records["a"]?.id)
        #expect(ExternalDisk.samePath(URL(filePath: after["renamed"]!.instanceDir), renamed))
        #expect(InstanceLineage(after).parentName(of: "copy") == "renamed")
    }

    @Test func deletedParentKeepsItsName() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try vm(root, "copy")
        try InstanceMetadata(instanceDir: copy.dir, parent: .init(id: UUID(), name: "gone", copiedAt: .now)).save()
        let records = InstanceMetadata.reconcile([copy])
        #expect(InstanceLineage(records).parentName(of: "copy") == nil)
        #expect(records["copy"]?.parent?.name == "gone")
    }

    @Test func recordsTheSnapshotACopyCameFrom() throws {
        let root = try temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let copy = try vm(root, "copy")
        try InstanceMetadata(instanceDir: copy.dir, parent: .init(id: UUID(), name: "a", copiedAt: .now, snapshot: "before")).save()
        #expect(InstanceMetadata.load(instanceDir: copy.dir)?.parent?.snapshot == "before")
    }

    @Test func handSetMACsAreDropped() {
        #expect(InstanceCopy.cloneExpressions(sourceConfig: "networks:\n- vzNAT: true\n  macAddress: \"52:55:55:12:34:56\"\n")
            == ["del(.networks[].macAddress)"])
        #expect(InstanceCopy.cloneExpressions(sourceConfig: "networks:\n- vzNAT: true\n").isEmpty)
    }
}
