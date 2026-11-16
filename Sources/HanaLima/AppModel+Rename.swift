import Foundation
import LimaKit

/// Renaming a stopped VM (docs/15, `InstanceRename`).
extension AppModel {
    /// `name`'s record is moving between folders (old or new name of a rename under way).
    func isRenaming(_ name: String) -> Bool { operations[name].map { $0.kind == .rename && $0.isRunning } == true }

    /// Why `name` can't be renamed now, or nil.
    func renameBlocker(_ name: String) -> String? {
        guard let inst = instance(named: name) else { return "" }
        if inst.isRunning { return String(localized: "停止すると名前を変更できます。") }
        if isBusy(name) { return String(localized: "処理中は名前を変更できません。") }
        // A copy reads its source's folder until it is done (`copy` marks only the copy busy).
        if autostartUpdating.contains(name) || operations.values.contains(where: { $0.kind == .clone && $0.isRunning }) {
            return String(localized: "処理中は名前を変更できません。")
        }
        if renameTask != nil { return String(localized: "ほかの仮想マシンの名前を変更しています。終わってからやり直してください。") }
        // Their windows hold the name and folder, even after the VM has stopped.
        if rescueSession?.name == name || installSession?.name == name {
            return String(localized: "救出起動かインストールのウインドウを閉じると名前を変更できます。")
        }
        if isHibernated(name) { return String(localized: "休止中は名前を変更できません。起動して再開するか、保存した状態を捨ててください。") }
        if DriverControl.hostedPID(instanceDir: inst.instanceDir) != nil {
            return String(localized: "救出起動かインストールで動いている間は名前を変更できません。")
        }
        if pendingInstall(name) != nil { return String(localized: "OS のインストールが終わると名前を変更できます。") }
        if case .missing = diskPlacement(of: inst) {
            return String(localized: "ディスクのある外付けドライブを接続すると名前を変更できます。")
        }
        switch InstanceRename.blocker(of: inst) {
        case .protected:
            return String(localized: "削除禁止（limactl protect）の仮想マシンは名前を変更できません。Lima が名前の変更で削除禁止を外すためです。ターミナルで limactl unprotect \(name) を実行してから変更してください。")
        case .subfolder(let folder):
            return String(localized: "仮想マシンのフォルダにサブフォルダ「\(folder)」があるため、名前を変更できません（Lima が途中で失敗します）。")
        case .hibernated:
            return String(localized: "休止中は名前を変更できません。起動して再開するか、保存した状態を捨ててください。")
        case .macOSGuest:
            return String(localized: "macOS のゲストは名前を変更できません。")
        case .networksOutsideConfig:
            return String(localized: "lima.yaml の外で定義したネットワークがあるため、名前を変更できません。")
        case nil:
            return nil
        }
    }

    /// Why `newName` can't be given to `name`, or nil.
    func renameNameProblem(_ newName: String, of name: String) -> String? {
        guard let inst = instance(named: name) else { return "" }
        switch InstanceRename.nameProblem(newName, for: inst) {
        case .invalid: return String(localized: "英数字と . _ - が使えます（記号は連続不可、先頭と末尾は英数字）。")
        case .caseOnly: return String(localized: "大文字と小文字だけを変える名前の変更はできません（Mac のディスクでは同じ名前です）。")
        case .taken(let n): return String(localized: "「\(n)」は既に存在します。")
        case .tooLong: return String(localized: "名前が長すぎます。")
        case nil: return nil
        }
    }

    /// Renames the stopped VM `name` to `newName`. Both names are busy meanwhile, and refreshes
    /// wait for it (`renameTask`): halfway, the VM's files are in two folders.
    func rename(_ name: String, to newName: String) {
        guard let client, let inst = instance(named: name), renameTask == nil, renameBlocker(name) == nil,
              renameNameProblem(newName, of: name) == nil, !isBusy(newName) else { return }
        operations[name] = Operation(kind: .rename)
        operations[newName] = Operation(kind: .rename)
        renameGeneration += 1
        let task = Task {
            do {
                try await InstanceRename.run(inst, to: newName, client: client) { entry in
                    await MainActor.run { self.appendLog(entry, to: name) }
                }
                operations[name] = nil
                operations[newName] = nil
                moveNameKeyedState(from: name, to: newName)
            } catch let error as InstanceRename.FinishError {
                // Renamed; only the rest failed (retried at the next launch).
                operations[name] = nil
                operations[newName] = nil
                moveNameKeyedState(from: name, to: newName)
                alert = AlertMessage(title: String(localized: "「\(name)」を「\(newName)」に変更しましたが、残りの処理に失敗しました"),
                                     message: error.localizedDescription)
            } catch {
                operations[name]?.isRunning = false
                operations[name]?.error = error.localizedDescription
                operations[newName] = nil
                alert = AlertMessage(title: String(localized: "「\(name)」の名前を変更できませんでした"),
                                     message: error.localizedDescription)
            }
        }
        renameTask = task
        Task {
            await task.value
            renameTask = nil
            await refresh()
        }
    }

    /// Finishes renames that a quit cut short (the start-at-login registration under the new
    /// name; see `InstanceRename.finish`): once per VM and launch, holding it busy meanwhile.
    func finishInterruptedRenames() {
        guard let client else { return }
        for inst in instances where !inst.isRunning && !isBusy(inst.name)
            && DriverControl.hostedPID(instanceDir: inst.instanceDir) == nil {
            guard let record = metadata[inst.name], record.autostartAfterRename == true,
                  renameRecoveryTried.insert(record.id).inserted else { continue }
            let name = inst.name
            operations[name] = Operation(kind: .rename)
            Task {
                try? await InstanceRename.finish(instanceDir: inst.instanceDir, name: name, client: client)
                // The flag is gone from the file: a later edit mustn't write the cached one back.
                metadata[name] = InstanceMetadata.load(instanceDir: inst.instanceDir) ?? metadata[name]
                if operations[name]?.kind == .rename { operations[name] = nil }
            }
        }
    }
}
