import LimaKit
import SwiftUI

/// Installs/configures socket_vmnet so `lima:bridged` (and lima:shared/host) networks work.
struct SocketVMNetSetupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var status: SocketVMNetSetup.Status?
    @State private var release: SocketVMNetSetup.Release?
    @State private var interfaces: [SocketVMNetSetup.HostInterface] = []
    @State private var selectedInterface = ""
    @State private var busy: String?
    @State private var errorMessage: String?
    @State private var confirmUninstall = false
    @State private var showScript = false

    private var setup: SocketVMNetSetup? { model.client.map(SocketVMNetSetup.init) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("ブリッジ接続（VM を LAN に直接参加させる）には socket_vmnet が必要です。macOS の新しい vmnet はブリッジに対応していないためです。インストールには管理者パスワードの入力が 1 回必要です。")
                        .font(.callout)
                }
                Section("状態") {
                    if let status {
                        CheckRow(ok: status.binaryInstalled && status.binarySecure,
                                 title: "socket_vmnet",
                                 detail: status.binaryInstalled
                                     ? (status.binarySecure ? status.binaryPath : "\(status.binaryPath) が root 所有になっていません")
                                     : "未インストール")
                        CheckRow(ok: status.sudoersUpToDate, title: "sudoers（\(SocketVMNetSetup.sudoersPath)）",
                                 detail: !status.sudoersInstalled ? "未設定"
                                     : status.sudoersUpToDate ? "設定済み"
                                     : !status.sudoersReadable ? "権限の都合で内容を確認できません。「sudoers を更新」で修正されます"
                                     : "networks.yaml と一致していません（更新が必要）")
                        CheckRow(ok: status.userInGroup, title: "グループ「\(status.group)」",
                                 detail: status.userInGroup ? "\(NSUserName()) は所属しています"
                                     : "\(NSUserName()) が所属していません。networks.yaml の group を変更するか、ユーザーをグループに追加してください")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }

                if let status, !(status.binaryInstalled && status.binarySecure) || !status.sudoersUpToDate {
                    installSection(status)
                }

                if status?.isReady == true {
                    Section {
                        Picker("ブリッジ先", selection: $selectedInterface) {
                            ForEach(interfaces) { i in
                                Text("\(i.displayName)（\(i.device)）").tag(i.device)
                            }
                            if !interfaces.contains(where: { $0.device == selectedInterface }) {
                                Text(selectedInterface).tag(selectedInterface)
                            }
                        }
                        if selectedInterface != (status?.bridgedInterface ?? "") {
                            Button("ブリッジ先を変更（管理者パスワードが必要）") { applyInterface() }
                                .disabled(busy != nil)
                        }
                    } header: {
                        Text("lima:bridged")
                    } footer: {
                        Text("VM の「設定 → ネットワーク」で「lima:bridged」を NIC として追加すると、LAN の DHCP から IP が割り当てられます。IP が付かない場合は、macOS のファイアウォールで bootpd を許可してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section {
                        Button("socket_vmnet をアンインストール…", role: .destructive) { confirmUninstall = true }
                            .disabled(busy != nil)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy != nil)
            }
            .padding()
        }
        .frame(width: 600, height: 640)
        .task { await reload() }
        .confirmationDialog("socket_vmnet をアンインストールしますか？", isPresented: $confirmUninstall) {
            Button("アンインストール", role: .destructive) { uninstall() }
        } message: {
            Text("\(SocketVMNetSetup.installDirectory) と \(SocketVMNetSetup.sudoersPath) を削除します。lima:shared / host / bridged を使う VM は起動できなくなります。")
        }
    }

    @ViewBuilder
    private func installSection(_ status: SocketVMNetSetup.Status) -> some View {
        Section {
            let needsBinary = !(status.binaryInstalled && status.binarySecure)
            if needsBinary {
                if let release {
                    LabeledContent("インストールする版", value: "socket_vmnet \(release.version)（\(SocketVMNetSetup.architecture)）")
                    LabeledContent("入手元") {
                        Text(release.tarballURL.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("SHA-256") {
                        Text(release.sha256).font(.caption.monospaced()).textSelection(.enabled)
                    }
                } else if busy == nil {
                    Text("最新版の情報を取得できませんでした。").foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("管理者として実行される処理", isExpanded: $showScript) {
                Text(needsBinary ? SocketVMNetSetup.installScript : SocketVMNetSetup.sudoersScript)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(needsBinary ? "ダウンロードしてインストール" : "sudoers を更新") {
                needsBinary ? install() : regenerate()
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy != nil || (needsBinary && release == nil))
        } header: {
            Text(status.binaryInstalled ? "設定" : "インストール")
        } footer: {
            Text("Lima の公式手順と同じく、公式リリースを /opt/socket_vmnet に展開し、`limactl sudoers` の出力を /etc/sudoers.d/lima に配置します（visudo で検査してから配置）。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func reload() async {
        guard let setup else { return }
        let st = await setup.status()
        status = st
        model.reloadNetworks()
        selectedInterface = st.bridgedInterface ?? "en0"
        if interfaces.isEmpty { interfaces = await SocketVMNetSetup.bridgeableInterfaces() }
        if !(st.binaryInstalled && st.binarySecure), release == nil {
            await perform("最新版を確認しています…") { release = try await setup.latestRelease() }
        }
    }

    private func install() {
        guard let setup, let release else { return }
        Task {
            await perform("ダウンロードしています…") {
                let tarball = try await setup.download(release)
                busy = "管理者パスワードの入力を待っています…"
                try await setup.install(tarball: tarball, release: release)
            }
            await reload()
        }
    }

    private func regenerate() {
        guard let setup else { return }
        Task {
            await perform("管理者パスワードの入力を待っています…") { try await setup.regenerateSudoers() }
            await reload()
        }
    }

    private func applyInterface() {
        guard let setup else { return }
        let iface = selectedInterface
        Task {
            await perform("管理者パスワードの入力を待っています…") {
                try SocketVMNetSetup.setBridgedInterface(iface)
                try await setup.regenerateSudoers()
            }
            await reload()
        }
    }

    private func uninstall() {
        guard let setup else { return }
        Task {
            await perform("管理者パスワードの入力を待っています…") { try await setup.uninstall() }
            await reload()
        }
    }

    private func perform(_ message: String, _ work: () async throws -> Void) async {
        busy = message
        errorMessage = nil
        defer { busy = nil }
        do {
            try await work()
        } catch let e as SetupError where e.canceled {
            // The user dismissed the password dialog; nothing to report.
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct CheckRow: View {
    let ok: Bool
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
