import Foundation
import LimaKit

extension AppModel {
    // MARK: - Hibernate (docs/11, stage 2)

    /// Stopped to Lima, with a saved state the next start resumes from (see `SavedState`).
    func isHibernated(_ name: String) -> Bool { hibernatedInstances.contains(name) }

    /// Why `name` can't be hibernated now, or nil. Like a pause: HanaLima's driver only, and only
    /// once ready (the driver refuses earlier anyway). A paused VM can be hibernated.
    func hibernateBlocker(_ name: String) -> String? {
        guard let instance = instance(named: name), instance.isRunning else { return String(localized: "実行中ではありません。") }
        if !instance.usesHanaLimaDriver { return String(localized: "休止できるのは、HanaLima のドライバーで動く仮想マシンだけです。") }
        if !isReady(name) { return String(localized: "起動の完了を待っています。") }
        if isBusy(name) { return String(localized: "処理中は休止できません。") }
        return nil
    }

    /// Saves the guest's RAM next to its disk and powers it off; the next start resumes there.
    func hibernate(_ name: String) {
        guard hibernateBlocker(name) == nil, let instance = instance(named: name) else { return }
        let dir = instance.instanceDir
        // About a second per GiB on an internal SSD; generous for slow drives.
        let timeout = 60 + Double((instance.memory ?? 0) >> 30) * 10
        operations[name] = Operation(kind: .hibernate)
        pauseEpochs[name, default: 0] += 1
        Task {
            do {
                _ = try await Task.detached {
                    try DriverControl.send(DriverControl.Request(op: .hibernate), instanceDir: dir, timeout: timeout)
                }.value
                pausedInstances.remove(name)
                operations[name] = nil
            } catch {
                operations[name]?.isRunning = false
                operations[name]?.error = "\(error)"
                alert = AlertMessage(title: String(localized: "\(name) の休止に失敗しました"), message: Self.describeHibernateFailure(error))
            }
            pauseEpochs[name, default: 0] += 1
            await refresh()
        }
    }

    /// The driver's reasons are English; the common one (the Mac locked) gets a sentence.
    private static func describeHibernateFailure(_ error: Error) -> String {
        let text = "\(error)"
        if text.contains("must be unlocked") {
            return String(localized: "保存を断られました。この Mac で初めて休止するときは、保存に使う鍵を作るため、Mac の画面のロックを解除しておく必要があります。ロックを解除してから、もう一度休止してください。")
                + "\n\n" + text
        }
        return text
    }

    /// Hibernated VMs among `list`: stopped, with a saved state in their folder.
    func updateHibernatedInstances(_ list: [LimaInstance]) {
        let found = Set(list.filter { !$0.isRunning && SavedState.exists(instanceDir: $0.instanceDir) }.map(\.name))
        if found != hibernatedInstances { hibernatedInstances = found }
    }

    /// Throws the saved state of `name` away; with `thenStart`, boots it afresh.
    func discardSavedState(_ name: String, thenStart: Bool = false) {
        guard let instance = instance(named: name), !instance.isRunning, !isBusy(name) else { return }
        do {
            try SavedState.discard(instanceDir: instance.instanceDir)
        } catch {
            alert = AlertMessage(title: String(localized: "保存した状態を削除できませんでした"), message: error.localizedDescription)
            return
        }
        hibernatedInstances.remove(name)
        if thenStart { start(name) }
        Task { await refresh() }
    }

    /// After a start of a hibernated VM failed with its state still there: the driver refused to
    /// restore it (the VM changed) or VZ couldn't. Asks whether to boot afresh instead.
    func offerDiscardAfterFailedResume(_ name: String) {
        guard let instance = instance(named: name), SavedState.exists(instanceDir: instance.instanceDir) else { return }
        let reason = Self.lastResumeFailure(instanceDir: instance.instanceDir)
        alert = nil
        operations[name] = nil
        pendingDiscard = DiscardPrompt(
            name: name, thenStart: true,
            message: String(localized: "保存した状態から再開できませんでした。休止したあとに設定やディスクを変えた場合は、元に戻すと再開できることがあります。保存した状態を捨てて起動すると、休止したときのメモリの内容（動いていたプログラムなど）は失われます。")
                + (reason.map { "\n\n" + $0 } ?? ""))
    }

    /// Asks before throwing the saved state away (from the banner and the menus).
    func confirmDiscardSavedState(_ name: String) {
        pendingDiscard = DiscardPrompt(
            name: name, thenStart: false,
            message: String(localized: "休止したときのメモリの内容（動いていたプログラムなど）は失われます。ディスクはそのままで、次の起動は電源を切ったあとの起動と同じになります。"))
    }

    /// The driver's last word on why it didn't restore (its log in the instance folder).
    private static func lastResumeFailure(instanceDir: URL) -> String? {
        guard let text = try? String(contentsOf: instanceDir.appending(path: "driver.stderr.log"), encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").last(where: {
            $0.contains("can't resume the hibernated VM") || $0.contains("restoring the hibernated state failed")
                || $0.contains("hibernated state has no readable record") || $0.contains("didn't resume")
        }) else { return nil }
        // "2026-…Z Start failed: can't resume …": the part after the time stamp.
        return line.split(separator: " ", maxSplits: 1).last.map(String.init)
    }
}
