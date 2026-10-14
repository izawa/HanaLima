import LimaKit
import SwiftUI

extension ProvisionConfig.Mode {
    var label: String {
        switch self {
        case .system: String(localized: "システム（root で実行）")
        case .user: String(localized: "ユーザー（一般ユーザーで実行）")
        case .boot: String(localized: "起動初期（boot）")
        case .dependency: String(localized: "依存パッケージ（dependency）")
        case .data: String(localized: "ファイルの配置（data）")
        case .yq: String(localized: "ファイルの編集（yq）")
        case .ansible: String(localized: "Ansible（非推奨）")
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
            ProvisionConfig(mode: .boot, script: String(localized: "# /bin/sh で実行されます（#! は不要）\n"))
        default:
            ProvisionConfig(mode: self, script: "#!/bin/sh\nset -eux\n\n")
        }
    }
}

/// `provision:` entries of lima.yaml.
struct ProvisionSection: View {
    @Binding var provision: [ProvisionConfig]
    var isLocked = false
    @State private var editing: ProvisionConfig?
    @State private var showExamples = false

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
                        Button(isLocked ? "表示…" : "編集…") { editing = entry }
                    } else {
                        Text("YAML で編集")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("この項目は YAML モードで編集してください")
                    }
                    RemoveButton { provision.removeAll { $0.id == entry.id } }
                        .disabled(isLocked)
                }
            }
            Menu("プロビジョニングを追加", systemImage: "plus") {
                ForEach(ProvisionConfig.Mode.editable) { mode in
                    Button(mode.label) { editing = mode.template }
                }
                Divider()
                Button("例から追加…") { showExamples = true }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isLocked)
        } header: {
            Text("プロビジョニング")
        } footer: {
            Text("仮想マシンを起動するたびに実行されます（初回だけではありません）。何度実行しても同じ結果になるように書いてください。変更は次回の起動から反映されます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if DEBUG
        .task {
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_PROVISION"] == "1" { editing = provision.first }
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_PROVISION_EXAMPLES"] == "1" { showExamples = true }
        }
        #endif
        .sheet(isPresented: $showExamples) {
            ProvisionExamplesSheet { entries in provision.append(contentsOf: entries) }
        }
        .sheet(item: $editing) { entry in
            ProvisionEditorSheet(entry: entry, isNew: !provision.contains { $0.id == entry.id },
                                 isReadOnly: isLocked) { saved in
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
    /// Viewing while the VM runs: everything shown, nothing editable, only a Close button.
    var isReadOnly = false
    let onSave: (ProvisionConfig) -> Void

    init(entry: ProvisionConfig, isNew: Bool, isReadOnly: Bool = false, onSave: @escaping (ProvisionConfig) -> Void) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.isReadOnly = isReadOnly
        self.onSave = onSave
    }

    private var error: String? {
        if entry.mode == .data {
            if !entry.path.hasPrefix("/") && !entry.path.hasPrefix("{{") { return String(localized: "ゲスト内の絶対パスを指定してください。") }
        } else if entry.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "スクリプトを入力してください。")
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("種類", selection: $entry.mode) {
                ForEach(ProvisionConfig.Mode.editable) { Text($0.label).tag($0) }
            }
            .fixedSize()
            .disabled(isReadOnly)
            Text(description)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if entry.mode == .data {
                TextField("パス", text: $entry.path, prompt: Text("/etc/example.conf"))
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .disabled(isReadOnly)
                Text("内容").font(.callout)
                CodeEditor(text: $entry.content, isEditable: !isReadOnly)
                    .border(.separator)
            } else {
                CodeEditor(text: $entry.script, isEditable: !isReadOnly)
                    .border(.separator)
                if entry.mode == .dependency {
                    Toggle("Lima 標準のパッケージ導入を行わない（skipDefaultDependencyResolution）",
                           isOn: $entry.skipDefaultDependencyResolution)
                        .disabled(isReadOnly)
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
                if isReadOnly {
                    Text("仮想マシンの実行中は変更できません。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("閉じる") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
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
        }
        .padding(20)
        .frame(width: 680, height: 560)
    }

    private var description: String {
        switch entry.mode {
        case .system: String(localized: "root 権限で実行されるスクリプトです。パッケージのインストールや設定ファイルの変更に使います。")
        case .user: String(localized: "一般ユーザー（Mac と同じユーザー名）で実行されるスクリプトです。")
        case .boot: String(localized: "起動のごく初期（cloud-init の bootcmd）に /bin/sh で実行されます。")
        case .dependency: String(localized: "Lima が依存パッケージを導入する前に実行されます。リポジトリの追加などに使います。")
        case .data: String(localized: "ゲストにファイルを書き込みます（実行はしません）。所有者は root:root、権限は 644 が既定です。")
        case .yq, .ansible: ""
        }
    }
}

extension ProvisionExample {
    var title: String {
        switch id {
        case .basicTools: String(localized: "基本ツール一式")
        case .dotfiles: String(localized: "自分の dotfiles・公開鍵")
        case .containerEngine: String(localized: "コンテナのエンジン（Docker Engine）")
        case .xdp: String(localized: "XDP の開発環境")
        }
    }

    var details: String {
        switch id {
        case .basicTools:
            String(localized: "git、curl、wget、jq、vim、htop、tmux、unzip を入れます。apt・dnf・apk を見分けます。")
        case .dotfiles:
            String(localized: "シェルの設定（~/.config/hanalima/shell.sh）を置き、~/.profile と ~/.bashrc から読み込みます。公開鍵（KEY）と dotfiles のリポジトリ（REPO）は、追加したあと「ユーザー」の項目を編集して書き入れてください。公開鍵は authorized_keys に追記するので、Lima の鍵は残ります。")
        case .containerEngine:
            String(localized: "Docker Engine を公式の手順で入れ、ユーザーを docker グループに入れます（root で動く構成。グループは次のログインから有効）。rootless で使うなら、作成時に Lima の docker テンプレートを選びます。")
        case .xdp:
            String(localized: "clang、llvm、libbpf、libxdp、xdp-tools、bpftool、カーネルのヘッダーを入れ、XDP のプログラムをビルドして読み込めるようにします（カーネルはそのまま）。VM のネットワークでは、汎用モード（xdpgeneric）から試してください。")
        }
    }
}

/// HanaLima's ready-made provisioning: pick one, and its entries are added for editing.
private struct ProvisionExamplesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onAdd: ([ProvisionConfig]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(ProvisionExamples.all) { example in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(example.title).font(.headline)
                                Text(example.details)
                                    .font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 10) {
                                    ForEach(Array(Set(example.entries.map(\.mode))).sorted { $0.rawValue < $1.rawValue }) { mode in
                                        Label(mode.label, systemImage: mode.icon)
                                    }
                                    Text(verbatim: example.distributions.joined(separator: " · "))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("追加") {
                                // Fresh ids: the same example may be added twice.
                                onAdd(example.entries.map { var e = $0; e.id = UUID(); return e })
                                dismiss()
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("プロビジョニングの例")
                } footer: {
                    Text("どれも起動のたびに実行され、済んでいれば何もしません。追加した項目は、そのまま編集できます。設定を保存すると、次の起動から実行されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("閉じる", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 620, height: 600)
    }
}
