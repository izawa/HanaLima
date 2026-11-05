import Foundation
import Testing
@testable import LimaKit

/// The rescue boot (docs/04): a VM with the console auto-login example is booted outside Lima
/// by the driver's hosted mode (`lima-driver-hanalima --hosted`, headless here) until the guest
/// is up (a login prompt on the serial console, or usernet's DHCP lease for Lima's MAC), then
/// handed back to Lima, which must boot it and reach it over SSH as before.
///
/// Needs `scripts/build-app.sh` first. `HANALIMA_E2E_TEMPLATE` picks the guest (default alpine).
/// Run with `HANALIMA_E2E=1 swift test --filter RescueEndToEnd` (a few minutes).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct RescueEndToEndTests {
    let vm = "hanalima-e2e-rescue"
    let client = LimaClient(limactlURL: LimaClient.locate()!)
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "alpine"

    @Test(.timeLimit(.minutes(15)))
    func rescueBootsAndLimaBootsAgain() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: HostedBoot.driver.path), "run scripts/build-app.sh first")
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

        // The rescue: the driver boots the instance's files outside Lima, until "login:" on the
        // serial console (Ubuntu) or sshd answering through usernet (Alpine prints no prompt there).
        let started = Date.now
        let serialLog = "hanalima-rescue-serial.log"
        let rescue = try HostedBoot(dir: dir, cpus: 2, memoryGiB: 2, options: ["--serial-log", serialLog])
        #expect(await rescue.waitUntilRunning(), "the hosted boot came up: \(rescue.logText.suffix(300))")
        var up = ""
        let deadline = Date.now.addingTimeInterval(180)
        while Date.now < deadline, rescue.isRunning {
            try await Task.sleep(for: .seconds(2))
            if let text = try? String(contentsOf: dir.appending(path: serialLog), encoding: .utf8), text.contains("login:") { up = "login prompt"; break }
            if rescue.usernetPortOpen(22) { up = "sshd reachable through usernet"; break }
        }
        print("rescue: \(up.isEmpty ? "not up after 180 s" : up) after \(Int(Date.now.timeIntervalSince(started))) s")
        #expect(!up.isEmpty)
        rescue.stop()
        let exit = await rescue.waitForExit(timeout: 40)
        print("rescue: driver exit \(exit), \(Int(Date.now.timeIntervalSince(started))) s in all")
        #expect(exit == 0)
        for name in [DriverControl.hostedPIDName, DriverControl.socketName, "hanalima-usernet.pid", "default_ep.sock"] {
            #expect(!FileManager.default.fileExists(atPath: dir.appending(path: name).path), Comment(rawValue: name))
        }
        // Ubuntu prints its login prompt on the virtio console; Alpine prints nothing there.
        let serial = (try? String(contentsOf: dir.appending(path: serialLog), encoding: .utf8)) ?? ""
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
