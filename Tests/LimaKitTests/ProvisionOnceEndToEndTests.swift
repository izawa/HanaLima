import Foundation
import Testing
@testable import LimaKit

/// A one-shot entry (ProvisionOnce) runs at the first boot only, and "run now" through
/// `limactl shell … sh -s` runs a plain entry and skips an already-stamped one.
/// Run with `HANALIMA_E2E=1 swift test --filter ProvisionOnceEndToEnd` (Alpine, a few minutes).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct ProvisionOnceEndToEndTests {
    let vm = "hanalima-e2e-once"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(15)))
    func runsOnceAcrossBoots() async throws {
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm]) }
        let system = ProvisionConfig(mode: .system, script: ProvisionOnce.wrap(
            body: "set -eu\ndate +%s > /var/lib/hanalima-once-system\n", mode: .system, id: "sys1"))
        let user = ProvisionConfig(mode: .user, script: ProvisionOnce.wrap(
            body: "set -eu\ndate +%s > \"$HOME/once-user\"\n", mode: .user, id: "usr1"))
        let entries = [system, user].map(\.json)
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 5, vmType: .vz, mountNone: true,
            setExpressions: [".provision = \(JSONValue.array(entries).jsonText)"])))
        _ = try await drain(client.start(vm))
        let systemFirst = try await sh("cat /var/lib/hanalima-once-system")
        let userFirst = try await sh("cat ~/once-user")
        #expect(!systemFirst.isEmpty && !userFirst.isEmpty)
        #expect(try await sh("ls /var/lib/hanalima/once ~/.local/state/hanalima/once | grep -c done") == "2")

        _ = try await drain(client.stop(vm))
        _ = try await drain(client.start(vm))
        #expect(try await sh("cat /var/lib/hanalima-once-system") == systemFirst)
        #expect(try await sh("cat ~/once-user") == userFirst)

        // Run now: a plain entry and the stamped one, in one combined script.
        var plain = ProvisionConfig(mode: .user)
        plain.script = "#!/bin/sh -eu\necho ran-now > \"$HOME/ran-now\"\n"  // the #! line picks the interpreter
        var data = ProvisionConfig(mode: .data, path: "{{.Home}}/data.txt", content: "hello", owner: "{{.User}}")
        data.extra["permissions"] = .string("0600")
        let combined = ProvisionScripts.combined([plain, system, data], instanceName: vm)
        var lines: [OutputLine] = []
        for try await line in client.runScript(in: vm, script: combined, asRoot: false) { lines.append(line) }
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("### 1/3 [user]") && text.contains("### 3/3 [data]"), "\(text)")
        #expect(try await sh("cat ~/ran-now") == "ran-now")
        #expect(try await sh("cat /var/lib/hanalima-once-system") == systemFirst)  // still stamped
        #expect(try await sh("stat -c '%U %a' ~/data.txt") == "\(try await sh("id -un")) 600")
        #expect(try await sh("cat ~/data.txt") == "hello")
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
