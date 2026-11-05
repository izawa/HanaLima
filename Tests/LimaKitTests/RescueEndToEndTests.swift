import Foundation
import Testing
@testable import LimaKit

/// The rescue boot (docs/04): a VM with the console auto-login example is booted by the signed
/// app itself (`HANALIMA_E2E_RESCUE`, headless) until the guest is up (a login prompt on the
/// serial console, or a DHCP lease for Lima's MAC), then handed back to Lima, which must boot it
/// and reach it over SSH as before.
///
/// Needs `scripts/build-app.sh` first. `HANALIMA_E2E_TEMPLATE` picks the guest (default alpine).
/// Run with `HANALIMA_E2E=1 swift test --filter RescueEndToEnd` (a few minutes).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct RescueEndToEndTests {
    let vm = "hanalima-e2e-rescue"
    let client = LimaClient(limactlURL: LimaClient.locate()!)
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"
    static let app = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/MacOS/HanaLima")

    @Test(.timeLimit(.minutes(15)))
    func rescueBootsAndLimaBootsAgain() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.app.path), "run scripts/build-app.sh first")
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm]) }
        let entries = ProvisionExamples.consoleLogin.entries.map(\.json)
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: Self.template, cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .vz, mountNone: true,
            setExpressions: [".provision = \(JSONValue.array(entries).jsonText)"])))
        _ = try await drain(client.start(vm))
        let user = try await sh("id -un")
        #expect(!user.isEmpty)
        #expect(try await sh("stat -c %U /dev/tty1") == user)  // agetty logged the user in on tty1
        _ = try await drain(client.stop(vm))
        let inst = try #require(try await client.list().first { $0.name == vm })
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)

        // The rescue: HanaLima's own VZ on the instance's files, until "login:" on the serial console.
        let started = Date.now
        let rescue = Process()
        rescue.executableURL = Self.app
        rescue.environment = ProcessInfo.processInfo.environment.merging(["HANALIMA_E2E_RESCUE": vm]) { $1 }
        rescue.standardOutput = FileHandle.nullDevice
        try rescue.run()
        while rescue.isRunning { try await Task.sleep(for: .seconds(2)) }
        print("rescue: \(Int(Date.now.timeIntervalSince(started))) s, exit \(rescue.terminationStatus)")
        #expect(rescue.terminationStatus == 0)
        // Ubuntu prints its login prompt on the virtio console; Alpine prints nothing there, and
        // the app then went by the DHCP lease (see e2eRescue).
        let serial = (try? String(contentsOf: dir.appending(path: "hanalima-rescue-serial.log"), encoding: .utf8)) ?? ""
        if !Self.template.hasPrefix("alpine") { #expect(serial.contains("login:")) }

        // Back under Lima: boots and answers over SSH, with the same user and the NIC it had.
        _ = try await drain(client.start(vm))
        #expect(try await sh("id -un") == user)
        #expect(try await sh("ip -o link show eth0 | grep -c 52:55:55") == "1")
        _ = try await drain(client.stop(vm))
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
