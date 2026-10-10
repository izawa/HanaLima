import LimaKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showCreate: Bool

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("仮想マシン") {
                ForEach(model.sidebarNames, id: \.self) { name in
                    SidebarRow(name: name)
                        .tag(SidebarItem.instance(name))
                        .contextMenu { InstanceActionsMenu(name: name) }
                }
            }
            Section("ストレージ") {
                Label {
                    HStack {
                        Text("ディスク")
                        Spacer()
                        if !model.disks.isEmpty {
                            Text("\(model.disks.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "externaldrive")
                }
                .tag(SidebarItem.disks)
                Label("使用量", systemImage: "chart.pie")
                    .tag(SidebarItem.storage)
            }
            Section("ネットワーク") {
                Label {
                    HStack {
                        Text("仮想ネットワーク")
                        Spacer()
                        if !model.virtualNetworks.isEmpty {
                            Text("\(model.virtualNetworks.count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                }
                .tag(SidebarItem.networks)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button { showCreate = true } label: {
                    Label("新規仮想マシン", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("新規仮想マシン (⇧⌘N)")
                Spacer()
                if case .ready(let version) = model.availability {
                    Text("Lima \(version)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
    }
}

private struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let instance = model.instance(named: name)
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(subtitle(instance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isBusy(name) {
                ProgressView().controlSize(.small)
            } else {
                StatusDot(color: instance?.status.color ?? .gray)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ instance: LimaInstance?) -> String {
        if let op = model.operations[name], op.isRunning {
            if let percent = op.download?.percent {
                return String(localized: "\(op.kind.progressLabel) · ダウンロード \(percent)%")
            }
            return op.kind.progressLabel + "…"
        }
        guard let instance else { return String(localized: "作成中…") }
        var parts = [instance.status.label]
        if !model.deletedNetworkSockets(of: instance).isEmpty {
            parts.append(String(localized: "NIC の接続先なし"))
        } else if instance.isRunning, !(model.restartNeeded[name] ?? []).isEmpty {
            parts.append(String(localized: "再起動が必要"))
        } else if let vm = instance.vmType {
            parts.append(vm.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}

/// Start/stop/delete actions shared by the context menu and the toolbar.
struct InstanceActionsMenu: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let instance = model.instance(named: name)
        let busy = model.isBusy(name)
        if instance?.isRunning == true {
            Button("停止") { model.stop(name) }.disabled(busy)
            Button("再起動") { model.restart(name) }.disabled(busy)
        } else {
            Button("起動") { model.start(name) }.disabled(busy || instance == nil)
        }
        Divider()
        if let instance {
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: instance.dir)])
            }
        }
    }
}
