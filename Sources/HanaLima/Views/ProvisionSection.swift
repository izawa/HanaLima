import LimaKit
import SwiftUI

extension ProvisionConfig.Mode {
    var label: String {
        switch self {
        case .system: "システム（root で実行）"
        case .user: "ユーザー（一般ユーザーで実行）"
        case .boot: "起動初期（boot）"
        case .dependency: "依存パッケージ（dependency）"
        case .data: "ファイルの配置（data）"
        case .yq: "ファイルの編集（yq）"
        case .ansible: "Ansible（非推奨）"
        }
    }

    var icon: String {
        switch self {
        case .system: "terminal.fill"
        case .user: "terminal"
        case .boot: "power"
        case .dependency: "shippingbox"
        case .data: "doc"
        case .yq: "doc.badge.gearshape"
        case .ansible: "list.bullet.rectangle"
        }
    }

    /// Modes HanaLima can create and edit.
    static let editable: [Self] = [.system, .user, .boot, .dependency, .data]

    /// Starting point for a new entry. /bin/sh rather than bash: Alpine has no bash by default.
    var template: ProvisionConfig {
        switch self {
        case .data:
            ProvisionConfig(mode: .data, path: "/etc/example.conf", content: "")
        case .boot:
            ProvisionConfig(mode: .boot, script: "# /bin/sh で実行されます（#! は不要）\n")
        default:
            ProvisionConfig(mode: self, script: "#!/bin/sh\nset -eux\n\n")
        }
    }
}

/// `provision:` entries of lima.yaml.
struct ProvisionSection: View {
    @Binding var provision: [ProvisionConfig]
    @State private var editing: ProvisionConfig?

    var body: some View {
        Section {
            if provision.isEmpty {
                Text("プロビジョニングはありません").foregroundStyle(.secondary)
            }
            ForEach(provision) { entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.mode.icon)
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.mode.label)
                        Text(entry.summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    if entry.isEditable {
                        Button("編集…") { editing = entry }
                    } else {
                        Text("YAML で編集")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("この項目は YAML モードで編集してください")
                    }
                    RemoveButton { provision.removeAll { $0.id == entry.id } }
                }
            }
            Menu("プロビジョニングを追加", systemImage: "plus") {
                ForEach(ProvisionConfig.Mode.editable) { mode in
                    Button(mode.label) { editing = mode.template }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("プロビジョニング")
        } footer: {
            Text("仮想マシンを起動するたびに実行されます（初回だけではありません）。何度実行しても同じ結果になるように書いてください。変更は次回の起動から反映されます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if DEBUG
        .task {
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_PROVISION"] == "1" { editing = provision.first }
        }
        #endif
        .sheet(item: $editing) { entry in
            ProvisionEditorSheet(entry: entry, isNew: !provision.contains { $0.id == entry.id }) { saved in
                if let i = provision.firstIndex(where: { $0.id == saved.id }) {
                    provision[i] = saved
                } else {
                    provision.append(saved)
                }
            }
        }
    }
}

private struct ProvisionEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: ProvisionConfig
    let isNew: Bool
    let onSave: (ProvisionConfig) -> Void

    init(entry: ProvisionConfig, isNew: Bool, onSave: @escaping (ProvisionConfig) -> Void) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.onSave = onSave
    }

    private var error: String? {
        if entry.mode == .data {
            if !entry.path.hasPrefix("/") && !entry.path.hasPrefix("{{") { return "ゲスト内の絶対パスを指定してください。" }
        } else if entry.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "スクリプトを入力してください。"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("種類", selection: $entry.mode) {
                ForEach(ProvisionConfig.Mode.editable) { Text($0.label).tag($0) }
            }
            .fixedSize()
            Text(description)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if entry.mode == .data {
                TextField("パス", text: $entry.path, prompt: Text("/etc/example.conf"))
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                Text("内容").font(.callout)
                CodeEditor(text: $entry.content)
                    .border(.separator)
            } else {
                CodeEditor(text: $entry.script)
                    .border(.separator)
                if entry.mode == .dependency {
                    Toggle("Lima 標準のパッケージ導入を行わない（skipDefaultDependencyResolution）",
                           isOn: $entry.skipDefaultDependencyResolution)
                }
            }
            Text("使えるテンプレート変数: {{.Home}}  {{.Name}}  {{.Hostname}}  {{.UID}}  {{.User}}  {{.Param.キー}}")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "追加" : "完了") {
                    onSave(entry)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(error != nil)
            }
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }

    private var description: String {
        switch entry.mode {
        case .system: "root 権限で実行されるスクリプトです。パッケージのインストールや設定ファイルの変更に使います。"
        case .user: "一般ユーザー（Mac と同じユーザー名）で実行されるスクリプトです。"
        case .boot: "起動のごく初期（cloud-init の bootcmd）に /bin/sh で実行されます。"
        case .dependency: "Lima が依存パッケージを導入する前に実行されます。リポジトリの追加などに使います。"
        case .data: "ゲストにファイルを書き込みます（実行はしません）。所有者は root:root、権限は 644 が既定です。"
        case .yq, .ansible: ""
        }
    }
}
