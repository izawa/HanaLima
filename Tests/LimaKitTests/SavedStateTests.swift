import Foundation
import Testing
@testable import LimaKit

@Suite struct SavedStateTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "savedstate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func record(_ dir: URL, configuration: String = "cpus=2", mac: String = "52:55:55:00:00:01") throws -> SavedState.Record {
        let files = try ["disk", "vz-efi"].map { name -> SavedState.FileStamp in
            try #require(SavedState.FileStamp(url: dir.appending(path: name), instanceDir: dir))
        }
        return SavedState.Record(machineIdentifier: "id", configuration: configuration, macAddress: mac, files: files, savedAt: Date(), size: 1)
    }

    @Test func matchesUntilADiskChanges() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("a".utf8).write(to: dir.appending(path: "disk"))
        try Data("e".utf8).write(to: dir.appending(path: "vz-efi"))
        let saved = try record(dir)
        #expect(SavedState.mismatch(saved: saved, current: try record(dir)) == nil)
        #expect(SavedState.mismatch(saved: saved, current: try record(dir, configuration: "cpus=4")) != nil)

        // Replaced by rename (a snapshot restored): a new inode.
        let other = dir.appending(path: "disk.new")
        try Data("a".utf8).write(to: other)
        _ = try FileManager.default.replaceItemAt(dir.appending(path: "disk"), withItemAt: other)
        #expect(SavedState.mismatch(saved: saved, current: try record(dir))?.contains("replaced") == true)
    }

    @Test func renamedDirectory() throws {
        let parent = try tempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appending(path: "a")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: dir.appending(path: "disk"))
        try Data("e".utf8).write(to: dir.appending(path: "vz-efi"))
        let saved = try record(dir)
        #expect(saved.files.map(\.path) == ["disk", "vz-efi"])
        let renamed = parent.appending(path: "b")
        try FileManager.default.moveItem(at: dir, to: renamed)
        // The files match where they are now; the MAC (derived from the folder) tells the rename.
        #expect(SavedState.mismatch(saved: saved, current: try record(renamed)) == nil)
        #expect(SavedState.mismatch(saved: saved, current: try record(renamed, mac: "52:55:55:00:00:02"))?.contains("renamed") == true)
    }

    @Test func writtenToOrResized() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let disk = dir.appending(path: "disk")
        try Data("a".utf8).write(to: disk)
        try Data("e".utf8).write(to: dir.appending(path: "vz-efi"))
        let saved = try record(dir)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 4096)
        try handle.close()
        #expect(SavedState.mismatch(saved: saved, current: try record(dir))?.contains("size") == true)
    }

    @Test func existsNeedsBothFilesAndDiscardRemovesThem() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: SavedState.stateURL(instanceDir: dir))
        #expect(!SavedState.exists(instanceDir: dir))
        try Data("a".utf8).write(to: dir.appending(path: "disk"))
        try Data("e".utf8).write(to: dir.appending(path: "vz-efi"))
        let saved = try record(dir)
        try SavedState.write(saved, instanceDir: dir)
        #expect(SavedState.exists(instanceDir: dir))
        #expect(SavedState.record(instanceDir: dir)?.files == saved.files)
        // Left mid-restore by a driver that died: still hibernated.
        try FileManager.default.moveItem(at: SavedState.stateURL(instanceDir: dir), to: dir.appending(path: SavedState.restoringName))
        #expect(SavedState.exists(instanceDir: dir))
        try SavedState.discard(instanceDir: dir)
        #expect(!SavedState.exists(instanceDir: dir))
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: SavedState.restoringName).path))
        #expect(!FileManager.default.fileExists(atPath: SavedState.recordURL(instanceDir: dir).path))
    }
}
