import LimaKit
import SwiftUI

struct InstanceDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "概要"
        case console = "コンソール"
        case config = "設定"
        case snapshots = "スナップ"   // segments are equal width; a long label overflows the toolbar
        case log = "ログ"
        var id: String { rawValue }

        /// rawValue stays Japanese: it's the identifier (also used by HANALIMA_SNAPSHOT_TAB).
        var title: String {
            switch self {
            case .overview: String(localized: "概要")
            case .console: String(localized: "コンソール")
            case .config: String(localized: "設定")
            case .snapshots: String(localized: "スナップ")
            case .log: String(localized: "ログ")
            }
        }
    }

    @Environment(AppModel.self) private var model
    let name: String
    @State private var tab: Tab = Self.initialTab

    private static var initialTab: Tab {
        #if DEBUG
        if let name = DebugSnapshot.requestedTab, let t = Tab(rawValue: name) { return t }
        #endif
        return .overview
    }
    @State private var confirmDelete = false

    var body: some View {
        let instance = model.instance(named: name)
        VStack(spacing: 0) {
            if let op = model.operations[name], op.isRunning || op.error != nil {
                OperationBanner(name: name, operation: op)
            } else if let instance {
                InstanceNoticeBanner(instance: instance)
            }
            Group {
                if let instance {
                    switch tab {
                    case .overview: OverviewTab(instance: instance)
                    case .console: ConsoleTab(instance: instance)
                    case .config: ConfigTab(instance: instance)
                    case .snapshots: SnapshotTab(instance: instance)
                    case .log: LogTab(name: name)
                    }
                } else {
                    // Still being created: only the log is meaningful.
                    LogTab(name: name)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: model.consoleRequest, initial: true) { _, request in
            guard request == name else { return }
            tab = .console
            model.consoleRequest = nil
        }
        .navigationTitle(name)
        .navigationSubtitle(model.statusText(of: name))
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("表示", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()   // otherwise it fills the toolbar and pushes the actions into overflow
                .disabled(instance == nil)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarActions(instance)
            }
        }
        .confirmationDialog(deleteTitle(instance), isPresented: $confirmDelete) {
            Button(instance?.isRunning == true ? "強制停止して削除" : "削除", role: .destructive) {
                model.delete(name, force: instance?.isRunning == true)
            }
        } message: {
            if let owner = model.sharedDiskOwners[name] {
                Text("仮想マシンの設定などが削除されます。ディスクは「\(owner)」のものなので削除しません。この操作は取り消せません。")
            } else {
            switch instance.map({ model.diskPlacement(of: $0) }) ?? .local {
            case .local:
                Text("仮想マシンのディスクを含むすべてのデータが削除されます。この操作は取り消せません。")
            case .external(let url):
                Text("仮想マシンのディスクを含むすべてのデータが削除されます。外部の保存先 \(url.deletingLastPathComponent().path) にあるディスクも削除します。この操作は取り消せません。")
            case .missing(let url):
                Text("仮想マシンの設定などが削除されます。外付けドライブが接続されていないため、\(url.deletingLastPathComponent().path) にあるディスクは残ります（あとで手作業で削除してください）。この操作は取り消せません。")
            }
            }
        }
    }

    @ViewBuilder
    private func toolbarActions(_ instance: LimaInstance?) -> some View {
        let busy = model.isBusy(name)
        if instance?.isRunning == true {
            Button { model.stop(name) } label: { Label("停止", systemImage: "stop.fill") }
                .help("停止")
                .disabled(busy)
            Button { model.restart(name) } label: { Label("再起動", systemImage: "arrow.clockwise") }
                .help("再起動")
                .disabled(busy)
        } else {
            Button { model.start(name) } label: { Label("起動", systemImage: "play.fill") }
                .help("起動")
                .disabled(busy || instance == nil)
        }
        Button(role: .destructive) { confirmDelete = true } label: {
            Label("削除", systemImage: "trash")
        }
        .help("削除")
        .disabled(busy || instance == nil || instance?.protected == true)
    }

    private func deleteTitle(_ instance: LimaInstance?) -> String {
        instance?.isRunning == true
            ? String(localized: "実行中の「\(name)」を強制停止して削除しますか？")
            : String(localized: "「\(name)」を削除しますか？")
    }
}

/// Progress or failure of the current limactl command, with the latest log line.
private struct OperationBanner: View {
    @Environment(AppModel.self) private var model
    let name: String
    let operation: Operation

    var body: some View {
        HStack(spacing: 10) {
            if operation.isRunning {
                ProgressView().controlSize(.small)
                Text(operation.kind.progressLabel)
                    .fontWeight(.medium)
                if let dl = operation.download {
                    DownloadProgressView(progress: dl)
                } else if let fraction = operation.fraction {
                    ProgressView(value: fraction).frame(width: 180)
                    Text(verbatim: "\(Int(fraction * 100))%").monospacedDigit().fontWeight(.medium)
                    Spacer(minLength: 8)
                    Button("中止") { model.cancelDiskMove(name) }
                        .help("移動を中止します。元のディスクはそのまま残ります。")
                } else {
                    Text(operation.log.last?.displayText ?? "")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else if let error = operation.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("\(operation.kind.label)に失敗: \(error)")
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Button("閉じる") { model.clearOperation(name) }
                    .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// What the VM needs now (a missing disk drive, a changed or deleted network), with the fix.
private struct InstanceNoticeBanner: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    var body: some View {
        let deleted = model.deletedNetworkSockets(of: instance).map(AppModel.networkName(ofSocket:))
        let changed = (model.restartNeeded[instance.name] ?? []).subtracting(deleted).sorted()
        if let owner = model.sharedDiskOwners[instance.name] {
            banner(icon: "externaldrive.badge.exclamationmark", color: .red,
                   text: String(localized: "この仮想マシンのディスクは「\(owner)」と同じファイルです（limactl clone でコピーした仮想マシンなど）。起動すると「\(owner)」のディスクを書き換えるため、起動できません。")) {
                Button("ディスクを独立させる") { model.separateDisk(instance.name) }
                    .disabled(instance.isRunning || model.isBusy(instance.name))
            }
        } else if case .missing(let url) = model.diskPlacement(of: instance) {
            banner(icon: "externaldrive.badge.xmark", color: .red,
                   text: String(localized: "ディスクの保存先 \(url.deletingLastPathComponent().path) が見つかりません。外付けドライブを接続してください。")) {
                EmptyView()
            }
        } else if !deleted.isEmpty {
            banner(icon: "exclamationmark.triangle.fill", color: .red,
                   text: String(localized: "NIC が、削除したネットワーク \(quoted(deleted)) を指しています。このままでは起動できません。")) {
                Button(instance.isRunning ? "NIC を外して再起動" : "NIC を外す") {
                    model.removeDeletedNICs(instance.name, thenStart: instance.isRunning)
                }
            }
        } else if instance.isRunning, !changed.isEmpty {
            banner(icon: "arrow.triangle.2.circlepath", color: .orange,
                   text: String(localized: "ネットワーク \(quoted(changed)) の設定を変更しました。再起動すると新しい設定で通信します。")) {
                Button("再起動") { model.restart(instance.name) }
            }
        }
    }

    private func quoted(_ names: [String]) -> String { AppModel.quotedNames(names) }

    private func banner(icon: String, color: Color, text: String,
                        @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(text).lineLimit(2)
            Spacer(minLength: 8)
            action()
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct DownloadProgressView: View {
    let progress: DownloadProgress

    var body: some View {
        HStack(spacing: 8) {
            Text("ダウンロード中: \(progress.fileName)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(progress.remote.absoluteString)
                .layoutPriority(-1)  // the file name gives way first, the numbers stay whole
            if let fraction = progress.fraction, let percent = progress.percent {
                ProgressView(value: fraction).frame(width: 140)
                Text(verbatim: "\(percent)%").monospacedDigit().fontWeight(.medium)
            }
            Text(detailText).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
        }
    }

    /// "412 MB / 902 MB · 11.8 MB/秒 · 残り 約 42 秒"
    private var detailText: String {
        var parts = [Formatting.bytes(progress.received)]
        if let total = progress.total { parts[0] += " / " + Formatting.bytes(total) }
        if let speed = progress.bytesPerSecond, speed > 0 {
            parts.append(String(localized: "\(Formatting.bytes(Int64(speed)))/秒"))
        }
        if let seconds = progress.secondsRemaining {
            parts.append(String(localized: "残り 約 \(Formatting.remaining(seconds))"))
        }
        return parts.joined(separator: " · ")
    }
}
