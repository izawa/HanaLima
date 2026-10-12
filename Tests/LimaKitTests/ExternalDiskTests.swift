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
        #expect(!ExternalDisk.removeExternalFolder(of: foreign, for: dir))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    /// `limactl clone` copies the link, not the disk: the copy must not delete or write the
    /// original's disk, and can get its own.
    @Test func cloneSharingTheLink() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-extdisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let dir = try makeInstance(root)
        let original = try Data(contentsOf: dir.appending(path: "disk"))
        let target = ExternalDisk.target(in: root.appending(path: "drive"), name: "vm1")
        try await ExternalDisk.moveOut(instanceDir: dir, name: "vm1", to: target) { _ in }

        let copy = root.appending(path: "lima/vm2", directoryHint: .isDirectory)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: copy.appending(path: "disk"), withDestinationURL: target)
        #expect(ExternalDisk.owner(sharingWith: copy).map { ExternalDisk.samePath($0, dir) } == true)
        #expect(ExternalDisk.owner(sharingWith: dir) == nil)
        ExternalDisk.claimIfOrphaned(instanceDir: copy, name: "vm2")  // the owner still links there
        #expect(ExternalDisk.owner(sharingWith: copy) != nil)
        #expect(!ExternalDisk.removeExternalFolder(of: target, for: copy))
        #expect(fm.fileExists(atPath: target.path))

        try await ExternalDisk.separate(instanceDir: copy, name: "vm2") { _ in }
        let own = try #require(ExternalDisk.placement(instanceDir: copy).externalURL)
        #expect(own.path.hasSuffix("HanaLima Disks/vm2/disk"))
        #expect(ExternalDisk.owner(sharingWith: copy) == nil)
        #expect(try Data(contentsOf: copy.appending(path: "disk")) == original)
        #expect(ExternalDisk.removeExternalFolder(of: own, for: copy))
        #expect(try Data(contentsOf: dir.appending(path: "disk")) == original)
    }

    /// A VM renamed outside HanaLima takes over the marker, so a later clone of it is caught.
    @Test func renamedOwnerClaimsMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hanalima-extdisk-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let dir = try makeInstance(root)
        let target = ExternalDisk.target(in: root.appending(path: "drive"), name: "vm1")
        try await ExternalDisk.moveOut(instanceDir: dir, name: "vm1", to: target) { _ in }
        let renamed = root.appending(path: "lima/renamed", directoryHint: .isDirectory)
        try fm.moveItem(at: dir, to: renamed)
        #expect(ExternalDisk.owner(sharingWith: renamed) == nil)
        ExternalDisk.claimIfOrphaned(instanceDir: renamed, name: "renamed")

        let copy = root.appending(path: "lima/copy", directoryHint: .isDirectory)
        try fm.createDirectory(at: copy, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: copy.appending(path: "disk"), withDestinationURL: target)
        ExternalDisk.claimIfOrphaned(instanceDir: copy, name: "copy")  // must not steal it
        #expect(ExternalDisk.owner(sharingWith: copy).map { ExternalDisk.samePath($0, renamed) } == true)
        #expect(ExternalDisk.removeExternalFolder(of: target, for: renamed))
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

@Suite struct ExternalDiskCopyTests {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hanalima-copy-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 4 KiB written every 1 MiB of a 512 MiB file: data scattered like a VM disk's. rsync --sparse
    /// copied this to about twice its size; the copy must take what the original takes.
    private func scatteredFile(_ url: URL) {
        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o644)
        ftruncate(fd, 512 << 20)
        var block = [UInt8](repeating: 7, count: 4096)
        var offset = 0
        while offset < 512 << 20 { _ = pwrite(fd, &block, 4096, off_t(offset)); offset += 1 << 20 }
        close(fd)
    }

    @Test func copyTakesTheSameSpace() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "src"), copy = dir.appending(path: "copy")
        scatteredFile(source)
        try await ExternalDisk.copySparse(from: source, to: copy) { _ in }
        #expect(StorageReport.allocatedSize(of: copy) == StorageReport.allocatedSize(of: source))
        #expect(FileManager.default.contentsEqual(atPath: source.path, andPath: copy.path))
    }

    @Test func cancelledCopyLeavesNothing() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appending(path: "src"), copy = dir.appending(path: "copy")
        scatteredFile(source)
        let task = Task { try await ExternalDisk.copySparse(from: source, to: copy) { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: copy.path))
    }

    @Test func noSecondDisksFolderAndEmptyOneIsRemoved() async throws {
        let dir = try temp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chosen = dir.appending(path: "HanaLimaDisks")
        #expect(ExternalDisk.target(in: chosen, name: "vm").path.hasSuffix("HanaLimaDisks/vm/disk"))
        #expect(ExternalDisk.target(in: dir, name: "vm").path.hasSuffix("HanaLima Disks/vm/disk"))

        // Removing the last VM's folder also removes the emptied "HanaLima Disks".
        let target = ExternalDisk.target(in: dir, name: "vm")
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let instanceDir = dir.appending(path: "lima/vm")
        let marker = try JSONSerialization.data(withJSONObject: ["instanceDir": instanceDir.path])
        FileManager.default.createFile(atPath: target.deletingLastPathComponent().appending(path: "hanalima.json").path, contents: marker)
        #expect(!ExternalDisk.removeExternalFolder(of: target, for: dir.appending(path: "lima/other")))
        #expect(ExternalDisk.removeExternalFolder(of: target, for: instanceDir))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "HanaLima Disks").path))
    }
}
