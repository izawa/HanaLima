import LimaKit
import SwiftUI
import Virtualization

/// The installer window: the VM's screen, the fix-up command to type, and the way back to Lima.
struct InstallerWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let session = model.installSession {
            InstallerSessionView(session: session)
                .onChange(of: session.state, initial: true) { _, _ in model.installSessionChanged() }
                .onDisappear { model.closeInstallSession() }
        } else {
            ContentUnavailableView("インストール中の仮想マシンはありません", systemImage: "opticaldisc")
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}

private struct InstallerSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let session: InstallSession

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let vm = session.vm, session.isRunning {
                    VirtualMachineScreen(machine: vm.machine)
                } else {
                    stoppedView
                }
            }
            .frame(minWidth: 1024, minHeight: 640)
            Divider()
            footer
        }
        .navigationTitle(String(localized: "インストール · \(session.name)"))
        .task { if session.vm == nil { session.boot(.installer) } }
    }

    private var stoppedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "opticaldisc").font(.system(size: 48)).foregroundStyle(.secondary)
            if let error = session.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            } else if case .failed(let message) = session.state ?? .stopped {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                Text("仮想マシンは停止しています。").font(.headline)
                Text("インストールと仕上げが済んでいれば「インストール完了」を押してください。Lima の仮想マシンとして起動します。\n仕上げがまだなら「ディスクから起動」で、インストールした OS を起動して仕上げのコマンドを実行してください。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 560)
            }
            HStack {
                Button("ISO から起動") { session.boot(.installer) }
                Button("ディスクから起動") { session.boot(.disk) }
                Button("インストール完了") {
                    model.finishInstall(session)
                    dismissWindow(id: "installer")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.03))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(session.phase == .installer
                      ? String(localized: "インストーラーの ISO から起動（\(session.iso.lastPathComponent)）")
                      : String(localized: "ディスクから起動"), systemImage: session.phase == .installer ? "opticaldisc" : "internaldrive")
                    .font(.callout)
                Spacer()
                if session.isRunning {
                    Button("電源を切る（要求）") { session.stop() }
                        .help("ゲストに終了を要求します。応答しないときは「強制停止」を使ってください。")
                    Button("強制停止") { session.stop(force: true) }
                }
            }
            Text("インストールが終わって再起動したら、インストールした OS にログインして次を実行し、`sudo poweroff` で電源を切ってください。この画面にはクリップボードが届かないので、手で入力します。")
                .font(.caption).foregroundStyle(.secondary)
            Text(InstallerFixup.command)
                .font(.title3.monospaced())
                .textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text("仕上げのスクリプトは cloud-init と sshd を用意します。次の起動から、Lima がユーザー・鍵・ゲストエージェント・共有フォルダ・プロビジョニングを設定します。ウインドウを閉じるとインストールは中断します（やり直せます）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// `VZVirtualMachineView` for SwiftUI. The machine must have been created on the main queue.
private struct VirtualMachineScreen: NSViewRepresentable {
    let machine: VZVirtualMachine

    func makeNSView(context: Context) -> VZVirtualMachineView {
        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        return view
    }

    func updateNSView(_ view: VZVirtualMachineView, context: Context) {
        if view.virtualMachine !== machine { view.virtualMachine = machine }
    }
}
