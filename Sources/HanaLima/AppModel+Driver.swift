import AppKit
import LimaKit

extension AppModel {
    // MARK: - Pause (docs/11, stage 1)

    func isPaused(_ name: String) -> Bool { pausedInstances.contains(name) }

    /// Why a VM can't be paused now, or nil. Only `hanalima` VMs (Lima's vz has no way to
    /// pause), and only once ready: the driver refuses before SSH is set up anyway.
    func pauseBlocker(_ name: String) -> String? {
        guard let instance = instance(named: name), instance.isRunning else { return String(localized: "実行中ではありません。") }
        if !instance.usesHanaLimaDriver { return String(localized: "一時停止できるのは、HanaLima のドライバーで動く仮想マシンだけです。") }
        if !isReady(name) { return String(localized: "起動の完了を待っています。") }
        if isBusy(name) { return String(localized: "処理中は一時停止できません。") }
        return nil
    }

    func pause(_ name: String) { Task { await sendPauseOpShowingErrors(.pause, kind: .pause, to: name) } }
    func resume(_ name: String) { Task { await sendPauseOpShowingErrors(.resume, kind: .resume, to: name) } }

    private func sendPauseOpShowingErrors(_ op: DriverControl.Op, kind: Operation.Kind, to name: String) async {
        if let error = await sendPauseOp(op, kind: kind, to: name) {
            alert = AlertMessage(title: String(localized: "\(name) の\(kind.label)に失敗しました"), message: error)
        }
    }

    /// Asks the driver to pause or resume; returns the error, or nil.
    func sendPauseOp(_ op: DriverControl.Op, kind: Operation.Kind, to name: String) async -> String? {
        guard let instance = instance(named: name), instance.usesHanaLimaDriver else { return "not a hanalima VM" }
        guard !isBusy(name) else { return "busy with another operation" }
        let dir = instance.instanceDir
        operations[name] = Operation(kind: kind)
        pauseEpochs[name, default: 0] += 1
        var failure: String?
        do {
            let response = try await Task.detached { try DriverControl.send(DriverControl.Request(op: op), instanceDir: dir) }.value
            if ["paused", "pausing"].contains(response.state) { pausedInstances.insert(name) } else { pausedInstances.remove(name) }
        } catch {
            failure = "\(error)"
        }
        // Pause and resume take milliseconds; nothing to keep on screen.
        operations[name] = nil
        pauseEpochs[name, default: 0] += 1
        return failure
    }

    /// Asks each running `hanalima` VM's driver whether it's paused (also after a relaunch:
    /// the driver keeps the VM, and its pause, when the app quits).
    func refreshPausedInstances(_ list: [LimaInstance]) async {
        let targets = list.filter { $0.isRunning && $0.usesHanaLimaDriver }.map { ($0.name, $0.instanceDir) }
        let epochs = pauseEpochs
        let answers = await Task.detached {
            await withTaskGroup(of: (String, Bool?).self) { group in
                for (name, dir) in targets {
                    group.addTask {
                        // nil: no answer (a timeout, the driver restarting); keeps what we knew.
                        let state = try? DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 2).state
                        // Pausing and resuming last milliseconds; neither answers the guest.
                        return (name, state.map { ["paused", "pausing", "resuming"].contains($0) })
                    }
                }
                var answers: [String: Bool?] = [:]
                for await (name, paused) in group { answers[name] = paused }
                return answers
            }
        }.value
        var updated = pausedInstances.intersection(targets.map(\.0))
        for (name, paused) in answers {
            // A pause or resume started or finished meanwhile knows better than this answer.
            guard let paused, pauseEpochs[name, default: 0] == epochs[name, default: 0],
                  operations[name]?.isRunning != true else { continue }
            if paused { updated.insert(name) } else { updated.remove(name) }
        }
        if updated != pausedInstances { pausedInstances = updated }
    }

    /// Shows the window of a VM on HanaLima's own driver (`vmType: hanalima`), which the driver
    /// process keeps even when it's been closed. Lima's vz can't reopen its window.
    func openScreen(_ instance: LimaInstance) {
        let dir = instance.instanceDir
        let pid = instance.driverPID
        Task {
            do {
                _ = try await Task.detached { try DriverControl.send(DriverControl.Request(op: .openScreen), instanceDir: dir) }.value
                // The driver activates itself; from the active app this makes it reliable.
                if let pid { NSRunningApplication(processIdentifier: pid_t(pid))?.activate() }
            } catch {
                alert = AlertMessage(title: String(localized: "画面を開けませんでした"), message: "\(error)")
            }
        }
    }
}
