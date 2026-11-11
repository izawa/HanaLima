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
            // Groups as submenus with their group-wide actions (docs/12 4.5), then the other VMs.
            ForEach(model.sidebarGroups.filter { !$0.members.isEmpty }, id: \.name) { group in
                Menu {
                    let active = model.isGroupRunActive(group.name)
                    ForEach(GroupAction.allCases, id: \.self) { action in
                        if action != .hibernate || group.members.contains(where: { model.instance(named: $0)?.usesHanaLimaDriver == true }) {
                            Button(action.label + "…") {
                                model.requestGroupRun(action, group: group.name)
                                showMainWindow()
                            }
                            .disabled(active)
                        }
                    }
                    Divider()
                    ForEach(group.members.compactMap { model.instance(named: $0) }) { instance in
                        vmMenu(instance)
                    }
                } label: {
                    let counts = model.groupCounts(group)
                    Label("\(group.name)（\(counts.running)/\(counts.total)）", systemImage: "folder")
                }
            }
            ForEach(model.ungroupedNames.compactMap { model.instance(named: $0) }) { instance in
                vmMenu(instance)
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

    private func vmMenu(_ instance: LimaInstance) -> some View {
        Menu {
            actions(for: instance)
        } label: {
            Label("\(instance.name)（\(statusText(instance))）",
                  systemImage: instance.isRunning ? "circle.fill" : "circle")
        }
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
            if instance.usesHanaLimaDriver {
                if model.isPaused(name) {
                    Button("再開") { model.resume(name) }.disabled(busy)
                } else {
                    Button("一時停止") { model.pause(name) }.disabled(model.pauseBlocker(name) != nil)
                }
                Button("休止") { model.hibernate(name) }.disabled(model.hibernateBlocker(name) != nil)
            }
            Button("停止") { model.stop(name) }.disabled(busy)
            Button("再起動") {
                model.restart(name)
                showWindowIfConfirming()
            }
            .disabled(busy)
        } else {
            Button(model.isHibernated(name) ? "再開" : "起動") {
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
        if let op = model.operations[instance.name], op.isRunning {
            if let percent = op.download?.percent {
                return String(localized: "\(op.kind.progressLabel) · ダウンロード \(percent)%")
            }
            return op.kind.progressLabel
        }
        if model.isPaused(instance.name) { return String(localized: "一時停止中") }
        if model.isHibernated(instance.name) { return String(localized: "休止中") }
        if instance.isRunning && !model.isReady(instance.name) { return String(localized: "起動処理中") }
        return instance.status.label
    }

    /// The socket_vmnet + virtual network confirmation is an alert in the main window.
    private func showWindowIfConfirming() {
        if model.pendingConflictStart != nil || model.pendingDeletedNetworkStart != nil || model.pendingDiscard != nil { showMainWindow() }
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
                if AppSettings.opensWindowAtLaunch,
                   !NSApp.windows.contains(where: { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }) {
                    openWindow(id: "main")
                }
                await model.bootstrap()
            }
            // A hibernated VM that couldn't resume asks what to do in the main window. The start
            // may have come from the menu with the window closed, and the question comes later.
            // AI asks for an approval, which only the main window can give.
            .onChange(of: model.agentHost.vmJobs.awaitingApproval.first?.jobID) { _, id in
                guard id != nil else { return }
                openWindow(id: "main")
                NSApp.activate()
            }
            .onChange(of: model.pendingDiscard?.id) { _, id in
                guard id != nil else { return }
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}
