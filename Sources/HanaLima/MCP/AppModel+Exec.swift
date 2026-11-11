import Foundation
import LimaKit

/// A script run in a guest for MCP (`exec`, and the traffic checks after `apply`): waited for,
/// with a time limit and only the end of its output kept.
struct GuestScriptResult {
    /// The script's exit status; nil when it didn't finish (timed out, cancelled, couldn't start).
    var exit: Int32?
    /// The last bytes of stdout and stderr, in order; stderr lines start with "2> ".
    var output: String
    var timedOut = false
    /// Why it couldn't run or finish, if not the script's own exit status.
    var error: String?
}

extension AppModel {
    /// Runs `script` with `sh -s` as the login user (`limactl shell`), marking the VM busy
    /// meanwhile so it doesn't overlap a start or stop. A busy VM is refused, not queued.
    /// On timeout the local `limactl` is terminated; whether the guest's processes ended is
    /// unknown (docs/14 §7).
    func runGuestScript(_ name: String, script: String, timeout: Duration, keepBytes: Int) async -> GuestScriptResult {
        guard let client else { return GuestScriptResult(output: "", error: "HanaLima has no limactl") }
        guard let inst = instance(named: name), inst.isRunning else { return GuestScriptResult(output: "", error: "not running") }
        guard !isBusy(name) else { return GuestScriptResult(output: "", error: "busy with another operation") }
        if isPaused(name) { return GuestScriptResult(output: "", error: "paused") }
        operations[name] = Operation(kind: .runScript)
        defer { operations[name] = nil }
        let stream = client.runScript(in: name, script: script, asRoot: false)
        let work = Task { () -> GuestScriptResult in
            var tail = OutputTail(limit: keepBytes)
            // A cancelled run (the timeout) stops limactl, which can end the stream without an
            // error or with SIGTERM's status: neither is the script's own result.
            do {
                for try await line in stream { tail.append(line) }
                return GuestScriptResult(exit: Task.isCancelled ? nil : 0, output: tail.text)
            } catch let error as CommandError {
                return GuestScriptResult(exit: Task.isCancelled ? nil : error.status, output: tail.text)
            } catch {
                return GuestScriptResult(output: tail.text, error: Task.isCancelled ? nil : error.localizedDescription)
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { work.cancel() }
        }
        var result = await work.value
        timer.cancel()
        if result.exit == nil && result.error == nil {
            result.timedOut = true
            result.error = "timed out after \(timeout.components.seconds) s; whether the guest's processes ended is unknown"
        }
        return result
    }
}

/// The last `limit` bytes of a command's output (kept whole lines where it can).
struct OutputTail {
    let limit: Int
    private(set) var text = ""
    private(set) var dropped = false

    init(limit: Int) { self.limit = max(limit, 0) }

    mutating func append(_ line: OutputLine) {
        switch line {
        case .stdout(let s): text += s + "\n"
        case .stderr(let s): text += "2> " + s + "\n"
        }
        guard text.utf8.count > limit else { return }
        dropped = true
        var cut = text.utf8.count - limit
        var index = text.startIndex
        while cut > 0, index < text.endIndex {
            cut -= String(text[index]).utf8.count
            index = text.index(after: index)
        }
        text = String(text[index...])
    }
}
