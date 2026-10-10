import LimaKit
import SwiftUI

struct InstanceDetailView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case overview = "概要"
        case console = "コンソール"
        case config = "設定"
        case log = "ログ"
        var id: String { rawValue }
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
            }
            Group {
                if let instance {
                    switch tab {
                    case .overview: OverviewTab(instance: instance)
                    case .console: ConsoleTab(instance: instance)
                    case .config: ConfigTab(instance: instance)
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
        .navigationSubtitle(instance?.status.label ?? "作成中")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("表示", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
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
            Text("仮想マシンのディスクを含むすべてのデータが削除されます。この操作は取り消せません。")
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
            ? "実行中の「\(name)」を強制停止して削除しますか？"
            : "「\(name)」を削除しますか？"
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
                Text("\(operation.kind.label)中")
                    .fontWeight(.medium)
                if let dl = operation.download {
                    DownloadProgressView(progress: dl)
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

private struct DownloadProgressView: View {
    let progress: DownloadProgress

    var body: some View {
        HStack(spacing: 8) {
            Text("ダウンロード中: \(progress.fileName)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: 160)
            }
            Text(sizeText).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private var sizeText: String {
        let received = Formatting.bytes(progress.received)
        guard let total = progress.total else { return received }
        return "\(received) / \(Formatting.bytes(total))"
    }
}
