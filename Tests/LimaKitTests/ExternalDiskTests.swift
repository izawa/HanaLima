import Foundation
import Testing
@testable import LimaKit

@Suite struct ExternalDiskTests {
    /// A 64 MiB sparse "disk" with 1 MiB of data, in a fake instance folder.
    private func makeInstance(_ root: URL) throws -> URL {
        let dir = root.appending(path: "lima/vm1")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let disk = dir.appending(path: "disk")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 64 << 20)
        try handle.seek(toOffset: 8 << 20)
        try handle.write(contentsOf: Data(repeating: 7, count: 1 << 20))
        try handle.close()
        return dir
    }

    @Test func movesOutAndBack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-extdisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeInstance(root)
        let original = try Data(contentsOf: dir.appending(path: "disk"))
        #expect(ExternalDisk.placement(instanceDir: dir) == .local)

        let target = ExternalDisk.target(in: root.appending(path: "drive"), name: "vm1")
        try await ExternalDisk.moveOut(instanceDir: dir, name: "vm1", to: target) { _ in }
        #expect(ExternalDisk.placement(instanceDir: dir) == .external(target))
        let allocated = StorageReport.allocatedSize(of: target)
        #expect(allocated >= 1 << 20 && allocated < 16 << 20)  // the 1 MiB of data, still sparse
        #expect(try Data(contentsOf: dir.appending(path: "disk")) == original)  // read through the link
        #expect(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appending(path: "hanalima.json").path))

        try await ExternalDisk.moveBack(instanceDir: dir) { _ in }
        #expect(ExternalDisk.placement(instanceDir: dir) == .local)
        #expect(try Data(contentsOf: dir.appending(path: "disk")) == original)
        #expect(!FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
    }

    @Test func missingTargetAndRefusals() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-extdisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeInstance(root)
        let target = ExternalDisk.target(in: root.appending(path: "drive"), name: "vm1")
        try await ExternalDisk.moveOut(instanceDir: dir, name: "vm1", to: target) { _ in }

        // The drive goes away.
        let drive = root.appending(path: "drive")
        try FileManager.default.moveItem(at: drive, to: root.appending(path: "unplugged"))
        #expect(ExternalDisk.placement(instanceDir: dir) == .missing(target))
        await #expect(throws: ExternalDisk.Failure.self) { try await ExternalDisk.moveBack(instanceDir: dir) { _ in } }

        // Only folders HanaLima made are deleted.
        let foreign = root.appending(path: "foreign/disk")
        try FileManager.default.createDirectory(at: foreign.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: foreign.path, contents: Data())
        #expect(!ExternalDisk.removeExternalFolder(of: foreign))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func checksDestination() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-extdisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try makeInstance(root)
        // Same volume as the instance: refused, whatever else holds.
        let check = ExternalDisk.check(folder: root, instanceDir: dir, name: "vm1", required: 1 << 20)
        #expect(check.problems.contains(.sameVolume))
        #expect(check.target.path.hasSuffix("HanaLima Disks/vm1/disk"))
    }
}
