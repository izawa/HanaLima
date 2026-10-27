import AppKit
import LimaKit
import NetworkKit
import SwiftUI
import UniformTypeIdentifiers

/// Ansible from the host (docs/08): choose a playbook for the VM and run it. Nothing here
/// touches lima.yaml, so the section stays editable while the VM runs.
struct AnsibleSection: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance
    @State private var extraArguments = ""

    private var record: InstanceMetadata.AnsibleRecord? { model.metadata[instance.name]?.ansible }

    /// Why 「実行」 is disabled, or the explanation of what it does.
    private var runHelp: String {
        if model.ansibleState.probing { return String(localized: "ansible-playbook を探しています。") }
        if model.ansibleTool == nil { return String(localized: "ansible-playbook が見つかりません。") }
        if record == nil { return String(localized: "Playbook を選んでください。") }
        if !instance.isRunning { return String(localized: "起動すると実行できます。") }
        if !model.isReady(instance.name) { return String(localized: "起動の完了を待っています。") }
        if model.isBusy(instance.name) { return String(localized: "処理中は実行できません。") }
        return String(localized: "この仮想マシンに対して Playbook を実行し、出力を表示します。")
    }

    private var canRun: Bool {
        !model.ansibleState.probing && model.ansibleTool != nil && record != nil
            && instance.isRunning && model.isReady(instance.name) && !model.isBusy(instance.name)
    }

    private var inventoryPath: String {
        (Ansible.inventoryURL(supportDirectory: NetworkPaths.supportDirectory).path(percentEncoded: false) as NSString)
            .abbreviatingWithTildeInPath
    }

    var body: some View {
        Section {
            toolRow
            playbookRow
            TextField("追加の引数", text: $extraArguments, prompt: Text(verbatim: "-e key=value --tags …"))
                .font(.body.monospaced())
                .disabled(record == nil)
                .onChange(of: extraArguments) { _, text in
                    guard let record, record.extraArguments != text else { return }
                    model.setAnsible(playbook: record.playbookURL, extraArguments: text, of: instance.name)
                }
            HStack {
                Button("実行") { model.runAnsible(in: instance.name) }
                    .disabled(!canRun)
                    .help(runHelp)
                if let record, let at = record.lastRunAt {
                    if let status = record.lastExitStatus {
                        if status == 0 {
                            Text("前回: \(at, format: .relative(presentation: .named)) · 成功")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("前回: \(at, format: .relative(presentation: .named)) · 失敗（終了コード \(status)）")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("前回: \(at, format: .relative(presentation: .named)) · 中止")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Ansible")
        } footer: {
            Text("HanaLima はインベントリ \(inventoryPath)（グループ [hanalima]、ホスト lima-<名前>）を書き、ssh を Lima の ssh.config に向けます。実行は Playbook のあるフォルダで ansible-playbook -i … --limit lima-<名前> <Playbook> を行うので、隣の roles/、group_vars/、ansible.cfg が使われます。同じインベントリはターミナルから -i で使えます。Lima のユーザーはパスワードなしで sudo できるので、become: true は設定なしで動きます。Playbook は Ansible の流儀で冪等に書いてください（HanaLima は「一度だけ」の印を付けません）。pyenv の shim を使っている場合、Playbook のフォルダの .python-version が指す Python に ansible が入っている必要があります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            if !model.ansibleState.probed && !model.ansibleState.probing { await model.locateAnsible() }
            #if DEBUG
            // Runs the recorded playbook now (the VM must be ready) and shows the output sheet.
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_ANSIBLE_RUN"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                model.runAnsible(in: instance.name)
            }
            #endif
        }
        // Follows the record (another VM selected, the record reconciled, or cleared), not just the name.
        .onChange(of: record?.extraArguments, initial: true) { _, saved in
            extraArguments = saved ?? ""
        }
    }

    // MARK: - The tool

    @ViewBuilder
    private var toolRow: some View {
        let state = model.ansibleState
        if state.probing {
            HStack {
                ProgressView().controlSize(.small)
                Text("ansible-playbook を探しています…").foregroundStyle(.secondary)
            }
        } else if let tool = state.tool {
            if let chosen = AppSettings.ansiblePath, chosen != tool.url.path(percentEncoded: false) {
                Label("設定で指定した場所（\(chosen)）は動かなかったので、見つかったものを使います。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            LabeledContent("ansible-playbook") {
                HStack {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: tool.version).font(.caption)
                        Text(verbatim: (tool.url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    AnsibleToolButtons()
                }
            }
        } else if state.probed {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("ansible-playbook が見つかりません。")
                    Spacer()
                    // A way back when a chosen path is what failed.
                    AnsibleToolButtons(showReset: !(AppSettings.ansiblePath ?? "").isEmpty)
                }
                Text("brew install ansible か pip install ansible で入れてください。別の場所にあるときは「場所を指定…」で選べます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - The playbook

    private var playbookRow: some View {
        LabeledContent("Playbook") {
            HStack {
                if let record {
                    Text(verbatim: (record.playbook as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .lineLimit(1).truncationMode(.middle)
                        .help(record.playbook)
                } else {
                    Text("未選択").foregroundStyle(.secondary)
                }
                Button("選択…") { choosePlaybook() }
                RemoveButton { model.setAnsible(playbook: nil, extraArguments: "", of: instance.name) }
                    .disabled(record == nil)
                    .help("Playbook の選択を外します（記録した引数と前回の結果も消えます）。")
            }
        }
    }

    private func choosePlaybook() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.yaml]
        panel.prompt = String(localized: "選択")
        panel.message = String(localized: "この仮想マシンで実行する Playbook（.yml / .yaml）を選んでください。")
        panel.directoryURL = record?.playbookURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.setAnsible(playbook: url, extraArguments: extraArguments, of: instance.name)
    }
}

/// 「場所を指定…」 and 「既定に戻す」 for `ansible-playbook`, shared by the section and Settings.
/// The chosen path goes to UserDefaults (`AppSettings.ansiblePathKey`); the probe runs again after.
struct AnsibleToolButtons: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.ansiblePathKey) private var ansiblePath = ""
    var showReset = true
    var chooseTitle: LocalizedStringKey = "場所を指定…"

    var body: some View {
        Button(chooseTitle) { choose() }
        if showReset {
            Button("既定に戻す") {
                ansiblePath = ""
                Task { await model.locateAnsible() }
            }
            .disabled(ansiblePath.isEmpty)
            .help("Homebrew、pyenv、~/.local/bin などの通常の場所から探し直します。")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        // The usual places are hidden folders (~/.pyenv/shims, ~/.local/bin); shims and Homebrew's
        // symlink are scripts, so no type filter.
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = String(localized: "選択")
        panel.message = String(localized: "ansible-playbook の実行ファイルを選んでください。")
        panel.directoryURL = ansiblePath.isEmpty ? nil : URL(filePath: ansiblePath).deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ansiblePath = url.path(percentEncoded: false)
        Task { await model.locateAnsible() }
    }
}
