import AppKit
import LimaKit
import SwiftUI

/// The menu bar item's menu: every VM with its state and actions, plus app-level commands.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch model.availability {
        case .ready:
            if model.instances.isEmpty {
                Text("仮想マシンはありません")
            }
            ForEach(model.instances) { instance in
                Menu {
                    actions(for: instance)
                } label: {
                    Label("\(instance.name)（\(statusText(instance))）",
                          systemImage: instance.isRunning ? "circle.fill" : "circle")
                }
            }
        case .checking:
            Text("limactl を確認しています…")
        case .missing, .failed:
            Text("limactl が見つかりません")
        }
        Divider()
        Button("HanaLima を開く") { showMainWindow() }
        Button("新規仮想マシン…") {
            model.createRequested = true
            showMainWindow()
        }
        .disabled(model.client == nil)
        Divider()
        Button("HanaLima について") {
            NSApp.orderFrontStandardAboutPanel(nil)
            NSApp.activate()
        }
        SettingsLink { Text("設定…") }
        Button("HanaLima を終了") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    @ViewBuilder
    private func actions(for instance: LimaInstance) -> some View {
        let name = instance.name
        let busy = model.isBusy(name)
        if instance.isRunning {
            Button("コンソールを開く") {
                model.openConsole(name)
                showMainWindow()
            }
            Divider()
            Button("停止") { model.stop(name) }.disabled(busy)
            Button("再起動") {
                model.restart(name)
                showWindowIfConfirming()
            }
            .disabled(busy)
        } else {
            Button("起動") {
                model.start(name)
                showWindowIfConfirming()
            }
            .disabled(busy)
        }
        Divider()
        Toggle("ログイン時に自動で起動", isOn: Binding(
            get: { model.autostartInstances.contains(name) },
            set: { enabled in Task { await model.setAutostart(name, enabled: enabled) } }))
        Button("詳細を表示") {
            model.selection = .instance(name)
            showMainWindow()
        }
    }

    private func statusText(_ instance: LimaInstance) -> String {
        if let op = model.operations[instance.name], op.isRunning { return op.kind.progressLabel }
        if instance.isRunning && !model.isReady(instance.name) { return String(localized: "起動処理中") }
        return instance.status.label
    }

    /// The socket_vmnet + virtual network confirmation is an alert in the main window.
    private func showWindowIfConfirming() {
        if model.pendingConflictStart != nil { showMainWindow() }
    }

    private func showMainWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// The menu bar icon. It exists for the whole life of the app, so it also takes care of launch.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            .task {
                // If the app last quit with its window closed, window restoration brings back
                // "no window" (and .defaultLaunchBehavior doesn't override that), leaving only
                // this icon. Open the main window on launch in that case.
                if !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                    openWindow(id: "main")
                }
                await model.bootstrap()
            }
    }
}
