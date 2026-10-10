import LimaKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showCreate = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.availability {
            case .checking:
                ProgressView("limactl を確認しています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                SetupView()
            case .failed(let message):
                SetupView(errorMessage: message)
            case .ready:
                NavigationSplitView {
                    SidebarView(showCreate: $showCreate)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250)
                        // On its own view: SwiftUI shows only one .alert per view.
                        .alert("削除したネットワークを指す NIC があります",
                               isPresented: Binding(get: { model.pendingDeletedNetworkStart != nil },
                                                    set: { if !$0 { model.pendingDeletedNetworkStart = nil } }),
                               presenting: model.pendingDeletedNetworkStart) { prompt in
                            Button(prompt.restart ? "NIC を外して再起動" : "NIC を外して起動") {
                                model.removeDeletedNICs(prompt.name, thenStart: true)
                            }
                            Button("キャンセル", role: .cancel) {}
                        } message: { prompt in
                            Text(prompt.message)
                        }
                } detail: {
                    switch model.selection {
                    case .instance(let name):
                        InstanceDetailView(name: name)
                            .id(name)
                    case .disks:
                        DiskListView()
                    case .storage:
                        StorageView()
                    case .networks:
                        NetworkListView()
                    case nil:
                        ContentUnavailableView {
                            Label("仮想マシンがありません", systemImage: "server.rack")
                        } description: {
                            Text("左下の ＋ から新しい仮想マシンを作成できます。")
                        } actions: {
                            Button("新規仮想マシン…") { showCreate = true }
                        }
                    }
                }
                // Kept on a different view than the error alert below: SwiftUI shows only one of
                // several .alert modifiers attached to the same view.
                .alert("socket_vmnet と HanaLima の仮想ネットワークを同時に使います",
                       isPresented: Binding(get: { model.pendingConflictStart != nil },
                                            set: { if !$0 { model.pendingConflictStart = nil } }),
                       presenting: model.pendingConflictStart) { prompt in
                    Button(prompt.restart ? "このまま再起動" : "このまま起動") {
                        model.confirmConflictStart(prompt)
                    }
                    Button("キャンセル", role: .cancel) {}
                } message: { prompt in
                    Text(prompt.message)
                }
            }
        }
        .sheet(isPresented: $showCreate) {
            CreateInstanceSheet()
        }
        // A request made before limactl was found waits until it is.
        .onChange(of: model.createRequested && model.client != nil, initial: true) { _, ready in
            guard ready else { return }
            model.createRequested = false
            showCreate = true
        }
        #if DEBUG
        .task {
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_CREATE"] == "1" { model.createRequested = true }
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_SETTINGS"] == "1" { openSettings() }
        }
        #endif
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
    }
}

/// Shown when limactl can't be found or doesn't run.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    var errorMessage: String?

    var body: some View {
        ContentUnavailableView {
            Label("limactl が見つかりません", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 8) {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("Lima をインストールしてください。")
                }
                Text("brew install lima lima-additional-guestagents")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
        } actions: {
            Button("再確認") { Task { await model.retryBootstrap() } }
        }
    }
}
