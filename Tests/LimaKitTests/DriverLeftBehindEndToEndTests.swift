import Darwin
import Foundation
import Testing
@testable import LimaKit

/// A driver process left behind at a `hanalima` VM's folder (its VM stopped, the host agent's
/// SIGTERM never came) exits after the next driver took over the same socket paths: the new
/// driver must keep its control socket (`hanalima-ctl.sock`) and Lima's (`hanalima.drv.sock`).
/// On 2026-11-18 a lab VM, hibernated and resumed within seconds, lost its control socket this
/// way and refused to hibernate again. Here the left-behind driver is one started by hand for the
/// stopped VM (as `limactl snapshot` starts one). `HANALIMA_E2E_DRIVERS` picks the drivers'
/// folder (default: `build/HanaLima.app/Contents/Helpers`, so `scripts/build-app.sh` first).
/// Alpine, one boot.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverLeftBehindEndToEndTests {
    let vm = "hanalima-e2e-leftbehind"
    static let helpers = URL(filePath: ProcessInfo.processInfo.environment["HANALIMA_E2E_DRIVERS"]
                             ?? FileManager.default.currentDirectoryPath + "/build/HanaLima.app/Contents/Helpers/HanaLimaDriver.app/Contents/MacOS")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(10)))
    func aLaterDriverKeepsItsSockets() async throws {
        let driver = Self.helpers.appending(path: "lima-driver-hanalima")
        try #require(FileManager.default.isExecutableFile(atPath: driver.path), "no driver at \(driver.path)")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10,
                                                        vmType: .hanalima, mountNone: true)))
        let dir = URL(filePath: try #require(try await client.list().first { $0.name == vm }).dir, directoryHint: .isDirectory)
        let control = dir.appending(path: DriverControl.socketName).path
        let grpc = dir.appending(path: "hanalima.drv.sock").path

        // The driver left behind: serving at the VM's folder with no VM.
        let old = Process()
        old.executableURL = driver
        old.arguments = ["--inst-dir", dir.path]
        old.standardError = FileHandle.nullDevice
        try old.run()
        defer { if old.isRunning { old.terminate() } }
        let serving = { [control, grpc] in FileManager.default.fileExists(atPath: control) && FileManager.default.fileExists(atPath: grpc) }
        for _ in 0..<100 where !serving() { try await Task.sleep(for: .milliseconds(100)) }
        try #require(serving(), "the old driver serves")
        // So Lima starts a new driver rather than reuse this one (as it would after the old
        // one's VM stopped and the host agent let go of it).
        unlink(grpc)

        _ = try await drain(client.start(vm))
        let pid = try #require(try await client.list().first { $0.name == vm }?.driverPID, "the new driver's pid")
        #expect(pid != Int(old.processIdentifier))

        #expect(FileManager.default.fileExists(atPath: grpc), "before the old driver goes, Lima's socket is there")
        // The old driver goes now, after the new one bound the same paths.
        old.terminate()
        // Not waitUntilExit(): it spins the run loop, which can miss the exit on a
        // cooperative thread and hang the test (it did, for an hour).
        for _ in 0..<100 where old.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        try #require(!old.isRunning, "the old driver exits")
        #expect(FileManager.default.fileExists(atPath: control), "the new driver's control socket stays")
        #expect(FileManager.default.fileExists(atPath: grpc), "Lima's socket to the new driver stays")
        let status = try DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 5)
        #expect(status.state == "running")

        _ = try await drain(client.stop(vm))
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
