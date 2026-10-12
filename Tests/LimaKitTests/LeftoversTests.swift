import Foundation
import Testing
@testable import LimaKit

@Suite struct LeftoversTests {
    private let fm = FileManager.default

    private func instance(_ home: URL, _ name: String) throws -> URL {
        let dir = home.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("images: []\n".utf8).write(to: dir.appending(path: "lima.yaml"))
        try InstanceMetadata(instanceDir: dir).save()
        return dir
    }

    /// `<base>/<name>/disk` with HanaLima's marker naming `owner`.
    private func movedDisk(_ base: URL, _ name: String, owner: URL) throws -> URL {
        let folder = base.appending(path: name, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(count: 4096).write(to: folder.appending(path: "disk"))
        let marker = try JSONSerialization.data(withJSONObject: ["instance": owner.lastPathComponent, "instanceDir": owner.path])
        try marker.write(to: folder.appending(path: "hanalima.json"))
        return folder.appending(path: "disk")
    }

    private func link(_ dir: URL, to disk: URL) throws {
        try fm.createSymbolicLink(at: dir.appending(path: "disk"), withDestinationURL: disk)
    }

    @Test func findsOnlyDataOfDeletedVMs() throws {
        let root = fm.temporaryDirectory.appending(path: "hanalima-left-\(UUID())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }
        let home = root.appending(path: "lima", directoryHint: .isDirectory)
        let base = root.appending(path: "drive/HanaLima Disks", directoryHint: .isDirectory)

        // A live VM with a snapshot and a moved disk.
        let live = try instance(home, "live")
        try fm.createDirectory(at: home.appending(path: "_hanalima-snapshots/\(InstanceMetadata.load(instanceDir: live)!.id)/s1"),
                               withIntermediateDirectories: true)
        try link(live, to: try movedDisk(base, "live", owner: live))
        // Renamed outside HanaLima: the marker names a folder that is gone, but a VM links there.
        let renamed = try instance(home, "renamed")
        try link(renamed, to: try movedDisk(base, "old-name", owner: home.appending(path: "old-name")))

        // Deleted with limactl: its snapshots and its moved disk remain.
        let gone = UUID()
        let snapDir = home.appending(path: "_hanalima-snapshots/\(gone)/\(UUID())", directoryHint: .isDirectory)
        try fm.createDirectory(at: snapDir, withIntermediateDirectories: true)
        try JSONEncoder.iso.encode(DiskSnapshot(name: "x", instance: "gone")).write(to: snapDir.appending(path: "snapshot.json"))
        _ = try movedDisk(base, "gone", owner: home.appending(path: "gone"))
        // Not HanaLima's (no marker): never touched.
        try fm.createDirectory(at: base.appending(path: "mine"), withIntermediateDirectories: true)

        let found = Leftovers.find(limaHome: home, diskFolders: [base, base, root.appending(path: "unplugged")])
        #expect(Set(found.map(\.url.lastPathComponent)) == [gone.uuidString, "gone"])
        #expect(found.first { $0.kind == .externalDisk }?.instance == "gone")
        #expect(found.first { $0.kind == .snapshots(count: 1) }?.instance == "gone")

        for item in found { try Leftovers.remove(item) }
        #expect(Leftovers.find(limaHome: home, diskFolders: [base]).isEmpty)
        #expect(fm.fileExists(atPath: base.appending(path: "live/disk").path))
        #expect(fm.fileExists(atPath: base.appending(path: "mine").path))
        #expect(fm.fileExists(atPath: home.appending(path: "_hanalima-snapshots").path))  // still holds live's
    }

    @Test func reportCountsSnapshotsWithTheirVM() throws {
        let root = fm.temporaryDirectory.appending(path: "hanalima-left-\(UUID())", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }
        let home = root.appending(path: "lima", directoryHint: .isDirectory)
        let vm = try instance(home, "vm")
        let snap = home.appending(path: "_hanalima-snapshots/\(InstanceMetadata.load(instanceDir: vm)!.id)/s", directoryHint: .isDirectory)
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1 << 20).write(to: snap.appending(path: "disk"))
        let report = StorageReport.measure(limaHome: home, cacheRoot: root.appending(path: "cache"))
        #expect(!report.limaItems.contains { $0.name == "_hanalima-snapshots" })
        let item = try #require(report.limaItems.first { $0.name == "vm" })
        #expect(item.snapshotSize >= 1 << 20)
        #expect(report.limaTotal >= item.size + item.snapshotSize)
        #expect(report.leftovers.isEmpty)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}
