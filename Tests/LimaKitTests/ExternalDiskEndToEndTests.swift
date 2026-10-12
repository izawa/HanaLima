import Foundation
import Testing
@testable import LimaKit

/// Moves a real VM's disk to another APFS volume (a disk image mounted for the test) and back,
/// booting it at each step. Run with `HANALIMA_E2E=1 swift test --filter ExternalDiskEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct ExternalDiskEndToEndTests {
    let vm = "hanalima-e2e-extdisk"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(20)))
    func diskMovesOutAndBack() async throws {
        let work = FileManager.default.temporaryDirectory.appending(path: "hanalima-e2e-extdisk-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let apfs = try attach(image: work.appending(path: "apfs.sparseimage"), fs: "APFS", size: "8g",
                              mountPoint: work.appending(path: "apfs"))
        let exfat = try attach(image: work.appending(path: "exfat.dmg"), fs: "ExFAT", size: "100m",
                               mountPoint: work.appending(path: "exfat"))
        defer {
            detach(apfs)
            detach(exfat)
            try? FileManager.default.removeItem(at: work)
        }
        _ = try? await drain(client.delete(vm, force: true))
        let copy = "\(vm)-copy"
        _ = try? await drain(client.delete(copy, force: true))
        defer { Task { [client, vm] in _ = try? await drain(client.delete(vm, force: true)); _ = try? await drain(client.delete(copy, force: true)) } }

        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1,
                                                        diskGiB: 10, vmType: .vz)))
        let inst = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: inst.dir)
        let disk = StorageReport.allocatedSize(of: ExternalDisk.diskURL(instanceDir: dir))
        #expect(disk > 50 << 20)  // an Alpine image is a few hundred MB

        // The checks the move sheet shows.
        #expect(ExternalDisk.check(folder: exfat, instanceDir: dir, name: vm, required: disk).problems
            .contains { if case .notAPFS = $0 { true } else { false } })
        let check = ExternalDisk.check(folder: apfs, instanceDir: dir, name: vm, required: disk)
        #expect(check.isOK, "\(check.problems)")

        // Out: Lima still lists it, boots it, writes to it.
        try await ExternalDisk.moveOut(instanceDir: dir, name: vm, to: check.target) { _ in }
        #expect(ExternalDisk.placement(instanceDir: dir) == .external(check.target))
        #expect(StorageReport.allocatedSize(of: check.target) < disk * 2)  // stayed sparse
        #expect(try await client.list().contains { $0.name == vm })
        _ = try await drain(client.start(vm))
        _ = try await client.runner.run(["shell", vm, "sudo", "sh", "-c", "echo hanalima > /root/marker && sync"])
        _ = try await drain(client.stop(vm))

        // Resizing goes through the link and keeps it.
        _ = try await drain(client.edit(vm, set: [#".disk = "12GiB""#]))
        #expect(ExternalDisk.placement(instanceDir: dir) == .external(check.target))
        _ = try await drain(client.start(vm))
        #expect(try await marker(vm) == "hanalima")
        _ = try await drain(client.stop(vm))

        // `limactl clone` copies the link, so the copy shares the disk until it gets its own:
        // an APFS clone on the same volume. Writing in the copy leaves the original alone, and
        // deleting the copy keeps the original's disk.
        _ = try await client.runner.run(["clone", "--tty=false", vm, copy])
        let copyDir = dir.deletingLastPathComponent().appending(path: copy, directoryHint: .isDirectory)
        #expect(ExternalDisk.owner(sharingWith: copyDir).map { ExternalDisk.samePath($0, dir) } == true)
        #expect(!ExternalDisk.removeExternalFolder(of: check.target, for: copyDir))
        try await ExternalDisk.separate(instanceDir: copyDir, name: copy) { _ in }
        #expect(ExternalDisk.owner(sharingWith: copyDir) == nil)
        _ = try await drain(client.start(copy))
        #expect(try await marker(copy) == "hanalima")
        _ = try await client.runner.run(["shell", copy, "sudo", "sh", "-c", "echo copy > /root/marker && sync"])
        _ = try await drain(client.stop(copy))
        let copyDisk = try #require(ExternalDisk.placement(instanceDir: copyDir).externalURL)
        _ = try await drain(client.delete(copy))
        #expect(ExternalDisk.removeExternalFolder(of: copyDisk, for: copyDir))
        #expect(FileManager.default.fileExists(atPath: check.target.path))

        // Back: a real file again, data intact, external folder gone.
        try await ExternalDisk.moveBack(instanceDir: dir) { _ in }
        #expect(ExternalDisk.placement(instanceDir: dir) == .local)
        #expect(!FileManager.default.fileExists(atPath: check.target.deletingLastPathComponent().path))
        _ = try await drain(client.start(vm))
        #expect(try await marker(vm) == "hanalima")
        _ = try await drain(client.stop(vm))

        // Deleting removes only the link; the app then removes the external folder.
        try await ExternalDisk.moveOut(instanceDir: dir, name: vm, to: check.target) { _ in }
        _ = try await drain(client.delete(vm))
        #expect(FileManager.default.fileExists(atPath: check.target.path))
        #expect(ExternalDisk.removeExternalFolder(of: check.target, for: dir))
        #expect(!FileManager.default.fileExists(atPath: check.target.deletingLastPathComponent().path))
    }

    private func marker(_ name: String) async throws -> String {
        try await client.runner.run(["shell", name, "sudo", "cat", "/root/marker"]).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func attach(image: URL, fs: String, size: String, mountPoint: URL) throws -> URL {
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        var create = ["create", "-size", size, "-fs", fs, "-volname", "E2E\(fs)", image.path]
        if fs == "APFS" { create.insert(contentsOf: ["-type", "SPARSE"], at: 1) }
        try hdiutil(create)
        try hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mountPoint.path])
        return mountPoint
    }

    private func detach(_ mountPoint: URL) {
        try? hdiutil(["detach", mountPoint.path, "-force"])
    }

    private func hdiutil(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/hdiutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ExternalDisk.Failure(message: "hdiutil \(args.first ?? "") failed") }
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
