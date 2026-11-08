import Foundation
import Testing
@testable import LimaKit

/// Pausing a `hanalima` VM in memory (docs/11, stage 1): the control socket's `pause` and
/// `resume`. Lima keeps listing the VM as Running; after the resume the guest hasn't rebooted
/// and Lima's time sync corrects its clock. `limactl stop` on a paused VM finishes: the driver
/// closes the guest agent's bridge while paused (Lima's calls to it have no deadline) and
/// resumes the guest before the ACPI power button, so it shuts down rather than being cut off.
///
/// Needs `scripts/build-app.sh` first. Alpine by default (`HANALIMA_E2E_TEMPLATE` changes it:
/// Ubuntu LTS has SSH over vsock), one boot.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct DriverPauseEndToEndTests {
    let vm = "hanalima-e2e-pause"
    let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    @Test(.timeLimit(.minutes(15)))
    func pauseResumeAndStopWhilePaused() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm], environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        _ = try await drain(client.create(CreateOptions(name: vm, template: template, cpus: 2, memoryGiB: 2, diskGiB: 10,
                                                        vmType: .hanalima, mountNone: true)))
        let created = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: created.dir, directoryHint: .isDirectory)
        _ = try await drain(client.start(vm))
        let bootID = try await sh("cat /proc/sys/kernel/random/boot_id")
        #expect(!bootID.isEmpty)

        // Pause for 65 s (a pause of 60 s or more ends with a link down and up on the NICs).
        let haLog = dir.appending(path: "ha.stderr.log")
        let refusalsBefore = count("Failed to get guest agent connection", in: haLog)
        #expect(try control(.pause, dir).state == "paused")
        #expect(try control(.status, dir).state == "paused")
        #expect(try await client.list().first { $0.name == vm }?.status == .running, "Lima doesn't know about the pause")
        #expect(throws: DriverControl.Failure.self) { try control(.pause, dir) }
        try await Task.sleep(for: .seconds(65))
        // The driver closes guest agent connections rather than refusing GuestAgentConn, which
        // Lima would log as an error every 2 s or so.
        #expect(count("Failed to get guest agent connection", in: haLog) == refusalsBefore)
        #expect(try control(.resume, dir).state == "running")

        // Same boot; the clock (65 s behind) is corrected by Lima's time sync within ~20 s.
        #expect(try await sh("cat /proc/sys/kernel/random/boot_id") == bootID)
        var drift = Int.max
        let syncing = Date()
        while Date().timeIntervalSince(syncing) < 40 {
            if let guest = Int(try await sh("date +%s")) { drift = abs(Int(Date().timeIntervalSince1970) - guest) }
            if drift <= 2 { break }
            try await Task.sleep(for: .seconds(2))
        }
        print("clock: drift \(drift) s after \(Int(Date().timeIntervalSince(syncing))) s")
        #expect(drift <= 2)
        // The NICs went down and up, and the guest still (or again) has its address.
        let driverLog = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        #expect(driverLog.contains("relinked the NICs"))
        var address = ""
        let relinking = Date()
        while Date().timeIntervalSince(relinking) < 30 {
            address = try await sh("ip -4 -o addr show eth0 | awk '{print $4}'")
            if address.hasPrefix("192.168.5.") { break }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(address.hasPrefix("192.168.5."), "eth0 has its usernet address again")

        // Stop while paused: the driver resumes and the guest shuts down on the power button.
        #expect(try control(.pause, dir).state == "paused")
        let stopping = Date()
        _ = try await drain(client.stop(vm))
        let took = Date().timeIntervalSince(stopping)
        print("limactl stop while paused: \(String(format: "%.1f", took)) s")
        #expect(took < 60)
        let log = (try? String(contentsOf: dir.appending(path: "driver.stderr.log"), encoding: .utf8)) ?? ""
        #expect(log.contains("resuming the paused VM to stop it"))
        #expect(log.contains("guest stopped"))
        #expect(!log.contains("didn't stop in"), "the guest shut down rather than being cut off")
        #expect(try await client.list().first { $0.name == vm }?.status == .stopped)
    }

    @discardableResult
    private func control(_ op: DriverControl.Op, _ dir: URL) throws -> DriverControl.Response {
        try DriverControl.send(DriverControl.Request(op: op), instanceDir: dir)
    }

    private func count(_ text: String, in file: URL) -> Int {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: text).count - 1
    }

    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
