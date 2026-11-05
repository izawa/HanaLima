import LimaKit
import SwiftUI
import Virtualization

/// The rescue window: the VM's screen, what the guest has and lacks here, and the way back to Lima.
struct RescueWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.rescueSession {
            RescueSessionView(session: session)
                .onChange(of: session.state, initial: true) { _, _ in model.rescueSessionChanged() }
                .onDisappear { model.closeRescueSession() }
        } else {
            ContentUnavailableView("救出起動中の仮想マシンはありません", systemImage: "cross.case")
                .frame(minWidth: 600, minHeight: 400)
        }
    }
}

private struct RescueSessionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let session: RescueSession

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
        .navigationTitle(String(localized: "救出起動 · \(session.name)"))
        .task { if session.vm == nil { session.boot() } }
    }

    private var stoppedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "cross.case").font(.system(size: 48)).foregroundStyle(.secondary)
            if let error = session.error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            } else if case .failed(let message) = session.state ?? .stopped {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.center)
            } else {
                Text("仮想マシンは停止しています。").font(.headline)
                Text("直し終わったら「Lima で起動」で、いつもの仮想マシンとして起動します。")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    .frame(maxWidth: 560)
            }
            HStack {
                Button("もう一度救出起動") { session.boot() }
                Button("Lima で起動") {
                    model.closeRescueSession()
                    model.start(session.name)
                    dismissWindow(id: "rescue")
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
                Label("HanaLima が画面付きで起動しています（Lima は関与しません）", systemImage: "cross.case")
                    .font(.callout)
                Spacer()
                if session.isRunning {
                    Button("電源を切る（要求）") { session.stop() }
                        .help("ゲストに終了を要求します。応答しないときは「強制停止」を使ってください。")
                    Button("強制停止") { session.stop(force: true) }
                }
            }
            Text("ゲストの画面のコンソール（tty1）にログインして直します。Lima はユーザーのパスワードをロックしているので、設定タブの「プロビジョニング」の「例から追加…」で「画面のコンソールに自動ログイン」を入れて一度 Lima で起動しておいた仮想マシンでないと、ログインできません。この画面にはクリップボードが届かないので、手で入力します。")
                .font(.caption).foregroundStyle(.secondary)
            Text("ここで使えるのは、ディスク、cidata、Lima と同じ MAC アドレスの NIC 1 つ（VZ の NAT。インターネットには届きますが、名前解決は Lima のネットワークに固定されているため通らないことがあります）です。追加ディスク、共有フォルダ、HanaLima のネットワーク、ポート転送は付きません。終わったら、ゲストの中で `sudo poweroff` か「電源を切る（要求）」で止めてください。ウインドウを閉じると電源が切れます（強制停止）。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
