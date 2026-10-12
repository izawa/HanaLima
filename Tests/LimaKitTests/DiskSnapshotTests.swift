import Foundation
import Testing
@testable import LimaKit

@Suite struct DiskSnapshotTests {
    /// A fake instance with a 64 MiB sparse disk holding `byte` at 8 MiB, and an EFI store.
    private func makeInstance(_ root: URL, _ name: String = "vm", byte: UInt8) throws -> URL {
        let dir = root.appending(path: "lima/\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = dir.appending(path: "disk")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let h = try FileHandle(forWritingTo: disk)
        try h.truncate(atOffset: 64 << 20)
        try h.close()
        try write(byte, to: dir)
        try Data("efi-\(byte)".utf8).write(to: dir.appending(path: "vz-efi"))
        return dir
    }

    private func write(_ byte: UInt8, to dir: URL) throws {
        let h = try FileHandle(forWritingTo: dir.appending(path: "disk"))
        try h.seek(toOffset: 8 << 20)
        try h.write(contentsOf: Data(repeating: byte, count: 4096))
        try h.close()
    }

    private func read(_ dir: URL) throws -> UInt8 {
        let h = try FileHandle(forReadingFrom: dir.appending(path: "disk"))
        defer { try? h.close() }
        try h.seek(toOffset: 8 << 20)
        return try h.read(upToCount: 1)?.first ?? 0
    }

    private func temp() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "hanalima-snap-\(UUID())", directoryHint: .isDirectory)
    }

    @Test func createRestoreDelete() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeInstance(root, byte: 1)
        let snap = try DiskSnapshot.create(instanceDir: dir, name: "before")
        #expect(DiskSnapshot.list(instanceDir: dir) == [snap])
        // Kept outside the instance folder (limactl clone fails on subfolders there).
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.contains("snapshot") })

        try write(2, to: dir)
        try Data("efi-2".utf8).write(to: dir.appending(path: "vz-efi"))
        // Enlarged since the snapshot: the restored disk keeps the larger length.
        let h = try FileHandle(forWritingTo: dir.appending(path: "disk"))
        try h.truncate(atOffset: 128 << 20)
        try h.close()

        try DiskSnapshot.restore(snap, of: dir, into: dir)
        #expect(try read(dir) == 1)
        #expect(try String(contentsOf: dir.appending(path: "vz-efi"), encoding: .utf8) == "efi-1")
        #expect((try FileManager.default.attributesOfItem(atPath: dir.appending(path: "disk").path)[.size] as? Int) == 128 << 20)
        // The snapshot stays and is itself unchanged by later writes.
        try write(3, to: dir)
        try DiskSnapshot.restore(snap, of: dir, into: dir)
        #expect(try read(dir) == 1)

        try DiskSnapshot.delete(snap, instanceDir: dir)
        #expect(DiskSnapshot.list(instanceDir: dir).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "lima/_hanalima-snapshots").path))
    }

    /// A moved disk keeps its snapshots next to it, and restoring goes through the link.
    @Test func externalDisk() async throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeInstance(root, byte: 1)
        let target = ExternalDisk.target(in: root.appending(path: "drive"), name: "vm")
        try await ExternalDisk.moveOut(instanceDir: dir, name: "vm", to: target) { _ in }
        let snap = try DiskSnapshot.create(instanceDir: dir, name: "x")
        #expect(DiskSnapshot.folder(instanceDir: dir)?.path.hasSuffix("HanaLima Disks/vm/snapshots") == true)
        try write(2, to: dir)
        try DiskSnapshot.restore(snap, of: dir, into: dir)
        #expect(try read(dir) == 1)
        #expect(ExternalDisk.placement(instanceDir: dir) == .external(target))  // still a link
    }

    /// A copy made from a snapshot: the source's snapshot restored into another instance.
    @Test func restoreIntoAnotherInstance() throws {
        let root = temp()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try makeInstance(root, "a", byte: 1)
        let snap = try DiskSnapshot.create(instanceDir: source, name: "s")
        try write(2, to: source)
        let copy = try makeInstance(root, "b", byte: 2)
        _ = InstanceMetadata.reconcile([("b", copy)])
        #expect(DiskSnapshot.list(instanceDir: copy).isEmpty)  // keyed by the VM's own id
        try DiskSnapshot.restore(snap, of: source, into: copy)
        #expect(try read(copy) == 1)
        #expect(try read(source) == 2)
    }
}
