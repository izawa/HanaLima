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
    @Environment(AppModel.self) private var model
    @Binding var provision: [ProvisionConfig]
    var isLocked = false
    /// The VM, for "run now" (needs it running and ready).
    var instance: LimaInstance?
    @State private var editing: ProvisionConfig?
    @State private var showExamples = false

    /// Running and ready (SSH up), with nothing else going on.
    private var canRunNow: Bool {
        guard let instance else { return false }
        return instance.isRunning && model.isReady(instance.name) && !model.isBusy(instance.name)
    }

    private var runNowHelp: String {
        guard let instance else { return "" }
        if !instance.isRunning { return String(localized: "起動すると実行できます。") }
        if !model.isReady(instance.name) { return String(localized: "起動の完了を待っています。") }
        if model.isBusy(instance.name) { return String(localized: "処理中は実行できません。") }
        return String(localized: "この項目を今すぐ一度だけ実行し、出力を表示します（保存はしません）。")
    }

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
                        HStack(spacing: 6) {
                            Text(entry.mode.label)
                            if entry.onceID != nil {
                                Text("1 回")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(.tint.opacity(0.15), in: Capsule())
                                    .help("一度だけ実行する項目です（印が残ると、以後の起動では何もしません）。")
                            }
                        }
                        Text(entry.summary)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    if entry.isEditable, let instance {
                        Button("今すぐ実行…") { model.runProvisionNow([entry], in: instance.name, title: entry.summary) }
                            .disabled(!canRunNow)
                            .help(runNowHelp)
                    }
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
            .disabled(isLocked)
            Text("「今すぐ実行」は、保存せずにその項目を実行中の仮想マシンで一度だけ実行し、出力を表示します。起動のたびに実行したいものは保存してください。")
                .font(.caption).foregroundStyle(.secondary)
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("プロビジョニング")
        } footer: {
            Text("仮想マシンを起動するたびに実行されます（初回だけではありません）。何度実行しても同じ結果になるように書くか、編集画面で「一度だけ実行する」を選んでください。変更は次回の起動から反映されます。")
                .font(.caption).foregroundStyle(.secondary)
        }
        #if DEBUG
        .task {
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_PROVISION"] == "1" { editing = provision.first }
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_PROVISION_EXAMPLES"] == "1" { showExamples = true }
            // Runs the named example now (the VM must be ready) and shows the output sheet.
            if let title = DebugSnapshot.env["HANALIMA_SNAPSHOT_RUNNOW"], let instance,
               let example = ProvisionExamples.all.first(where: { $0.id.rawValue == title }) {
                try? await Task.sleep(for: .seconds(1))
                model.runProvisionNow(example.entries, in: instance.name, title: example.title)
            }
        }
        #endif
        .sheet(isPresented: $showExamples) {
            ProvisionExamplesSheet(instance: instance, canRunNow: canRunNow) { entries in provision.append(contentsOf: entries) }
        }
        .sheet(item: Binding(get: { model.scriptRun }, set: { if $0 == nil { model.scriptRun = nil } })) { run in
            ScriptRunSheet(run: run)
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
    /// The script as written; for a one-shot entry, the wrapper is added on save.
    @State private var body_: String
    @State private var once: Bool
    @State private var onceID: String
    let isNew: Bool
    /// Viewing while the VM runs: everything shown, nothing editable, only a Close button.
    var isReadOnly = false
    let onSave: (ProvisionConfig) -> Void

    init(entry: ProvisionConfig, isNew: Bool, isReadOnly: Bool = false, onSave: @escaping (ProvisionConfig) -> Void) {
        _entry = State(initialValue: entry)
        let parsed = ProvisionOnce.parse(entry.script)
        _body_ = State(initialValue: parsed?.body ?? entry.script)
        _once = State(initialValue: parsed != nil)
        _onceID = State(initialValue: parsed?.id ?? ProvisionOnce.newID())
        self.isNew = isNew
        self.isReadOnly = isReadOnly
        self.onSave = onSave
    }

    private var canBeOnce: Bool { ProvisionOnce.supports(entry.mode) }

    private var saved: ProvisionConfig {
        var e = entry
        if e.mode.isScript {
            e.script = once && canBeOnce ? ProvisionOnce.wrap(body: body_, mode: e.mode, id: onceID) : body_
        }
        return e
    }

    private var error: String? {
        if entry.mode == .data {
            if !entry.path.hasPrefix("/") && !entry.path.hasPrefix("{{") { return String(localized: "ゲスト内の絶対パスを指定してください。") }
        } else if body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
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
                CodeEditor(text: $body_, isEditable: !isReadOnly)
                    .border(.separator)
                if canBeOnce {
                    HStack {
                        Toggle("一度だけ実行する（次の起動で 1 回）", isOn: $once)
                            .disabled(isReadOnly)
                        if once && !isNew && !isReadOnly {
                            Button("もう一度実行") { onceID = ProvisionOnce.newID() }
                                .help("次の起動でもう一度実行します（新しい印を付けます）。")
                        }
                    }
                    if once {
                        Text("成功すると印（\(ProvisionOnce.stampDirectory(for: entry.mode))/<id>.done）を残し、以後の起動では何もしません。失敗したときは印を残さず、次の起動で再試行します。「今すぐ実行」でも印を残します。")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
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
                        onSave(saved)
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
        case .japan: String(localized: "日本向けの設定")
        case .noAutoUpdates: String(localized: "自動更新の停止")
        case .swap: String(localized: "スワップファイル")
        case .devLanguages: String(localized: "開発言語（Go、Node.js、Python、Rust）")
        case .fullUpgrade: String(localized: "パッケージをすべて更新（一度だけ）")
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
        case .japan:
            String(localized: "タイムゾーンを Asia/Tokyo にし、ja_JP.UTF-8 のロケールを用意します（apt は locales と locale-gen、dnf は glibc-langpack-ja）。システムの既定の LANG は変えないので、使うときはシェルで LANG=ja_JP.UTF-8 を設定します。Alpine にはロケールが無いので、タイムゾーンだけを設定します。")
        case .noAutoUpdates:
            String(localized: "パッケージの自動更新を止めます（apt は apt-daily のタイマーと unattended-upgrades、dnf は dnf-automatic と makecache のタイマーを mask）。起動直後の更新に CPU やロックを取られなくなります。更新は自分の手で行います。")
        case .swap:
            String(localized: "2 GiB のスワップファイル /swapfile を作り、/etc/fstab に登録して毎回の起動で有効にします（Fedora の btrfs では copy-on-write を外し、Alpine では swap サービスを boot に加えます）。メモリの少ない VM でビルドが落ちるのを防ぎます。")
        case .fullUpgrade:
            String(localized: "次の起動で一度だけ、入っているパッケージをすべて更新します（apt は full-upgrade と autoremove、dnf は upgrade、apk は upgrade）。「一度だけ実行する」の例で、済むと印を残して以後は何もしません。もう一度更新したいときは、項目の編集画面で「もう一度実行」を押します。")
        case .devLanguages:
            String(localized: "システムには Go（go.dev の公式ビルド、/usr/local/go）と Node.js・npm（ディストリビューションのパッケージ）を、ユーザーのホームには uv（Python）と rustup（Rust、minimal プロファイル）を公式のインストーラーで入れます。uv と cargo の PATH は次のログインから有効です。")
        }
    }
}

/// HanaLima's ready-made provisioning: pick one, and its entries are added for editing.
private struct ProvisionExamplesSheet: View {
    /// A copy with its own id (the same example may be added twice) and, for a one-shot entry,
    /// its own stamp id.
    static func fresh(_ entry: ProvisionConfig) -> ProvisionConfig {
        var e = entry
        e.id = UUID()
        if let parsed = ProvisionOnce.parse(e.script) {
            e.script = ProvisionOnce.wrap(body: parsed.body, mode: e.mode, id: ProvisionOnce.newID())
        }
        return e
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var instance: LimaInstance?
    var canRunNow = false
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
                            VStack(spacing: 6) {
                                Button("追加") {
                                    // Fresh ids: the same example may be added twice.
                                    onAdd(example.entries.map(Self.fresh))
                                    dismiss()
                                }
                                if let instance {
                                    Button("今すぐ実行") {
                                        model.runProvisionNow(example.entries.map(Self.fresh), in: instance.name, title: example.title)
                                        dismiss()
                                    }
                                    .disabled(!canRunNow)
                                    .help(canRunNow ? String(localized: "保存せずに、実行中の仮想マシンで一度だけ実行します。")
                                                    : String(localized: "起動して準備ができると実行できます。"))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("プロビジョニングの例")
                } footer: {
                    Text("「追加」は起動のたびに実行する項目として入れます（済んでいれば何もしません。設定を保存すると次の起動から）。「今すぐ実行」は保存せずに一度だけ実行し、出力を表示します。")
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
