import LimaKit
import SwiftUI

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
                if session.isRunning {
                    HostedScreenPlaceholder(state: session.state, title: String(localized: "仮想マシンの画面は別のウインドウです")) { session.openScreen() }
                } else {
                    stoppedView
                }
            }
            .frame(minWidth: 640, minHeight: 360)
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
                Label("HanaLima のドライバーが画面付きで起動しています（Lima は関与しません）", systemImage: "cross.case")
                    .font(.callout)
                Spacer()
                if session.isRunning {
                    Button("電源を切る（要求）") { session.stop() }
                        .help("ゲストに終了を要求します。応答しないときは「強制停止」を使ってください。")
                    Button("強制停止") { session.stop(force: true) }
                }
            }
            Text("ゲストの画面のコンソール（tty1）にログインして直します。Lima はユーザーのパスワードをロックしているので、設定タブの「プロビジョニング」の「例から追加…」で「コンソールに自動ログイン（画面・シリアル）」を入れて一度 Lima で起動しておいた仮想マシンでないと、ログインできません。この画面にはクリップボードが届かないので、手で入力します。")
                .font(.caption).foregroundStyle(.secondary)
            Text("ここで使えるのは、ディスク、cidata、Lima と同じ MAC アドレスの NIC 1 つ（Lima のユーザーモードネットワーク。インターネットと名前解決は Lima で起動したときと同じ）です。追加ディスク、共有フォルダ、HanaLima のネットワーク、ポート転送は付きません。終わったら、ゲストの中で `sudo poweroff` か「電源を切る（要求）」で止めてください。仮想マシンの画面のウインドウを閉じると電源が切れます。HanaLima を終了しても仮想マシンは動き続け、次に開いたときにここに戻ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
