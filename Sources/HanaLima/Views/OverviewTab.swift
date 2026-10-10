import AppKit
import LimaKit
import SwiftUI

struct OverviewTab: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    private func nicLabel(_ net: NetworkAttachment) -> String {
        if let path = net.socket, let vn = model.virtualNetwork(forSocket: path) {
            return vn.menuDescription
        }
        return net.kindDescription
    }

    /// Address on a HanaLima virtual network: the reservation if any, else the DHCP lease.
    private func nicAddress(_ net: NetworkAttachment) -> String? {
        guard let path = net.socket, let vn = model.virtualNetwork(forSocket: path) else { return nil }
        if let r = model.reservation(of: instance, on: vn) { return "\(r.ip)（固定）" }
        return model.address(of: instance, on: vn)
    }

    var body: some View {
        Form {
            Section("状態") {
                LabeledContent("状態") {
                    HStack(spacing: 6) {
                        StatusDot(color: instance.status.color)
                        Text(instance.status.label)
                    }
                }
                if let message = instance.message, !message.isEmpty {
                    LabeledContent("メッセージ") { Text(message).textSelection(.enabled) }
                }
                if instance.protected == true {
                    LabeledContent("保護") { Text("削除禁止 (limactl protect)") }
                }
                AutostartToggle(name: instance.name, title: "ログイン時に自動で起動")
            }

            Section("ハードウェア") {
                LabeledContent("仮想 CPU") { Text(instance.cpus.map { "\($0) コア" } ?? "—") }
                LabeledContent("メモリ") { Text(Formatting.bytes(instance.memory)) }
                LabeledContent("ディスク") { Text(Formatting.bytes(instance.disk)) }
                if let disks = instance.additionalDisks, !disks.isEmpty {
                    LabeledContent("追加ディスク") { Text(disks.map(\.name).joined(separator: ", ")) }
                }
                LabeledContent("仮想化方式") { Text(instance.vmType?.uppercased() ?? "—") }
                LabeledContent("アーキテクチャ") { Text(instance.arch ?? "—") }
            }

            Section("ネットワーク") {
                LabeledContent("ユーザーモード") { Text("192.168.5.0/24 (標準)") }
                ForEach(Array((instance.networks ?? []).enumerated()), id: \.offset) { index, net in
                    LabeledContent("NIC \(index + 1)") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(nicLabel(net))
                            if let iface = net.interface, !iface.isEmpty {
                                Text("インターフェース: \(iface)").font(.caption).foregroundStyle(.secondary)
                            }
                            if let ip = nicAddress(net) {
                                Text("IP: \(ip)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            if let mac = net.macAddress, !mac.isEmpty {
                                Text("MAC: \(mac)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("接続") {
                LabeledContent("ホスト名") { Text(instance.hostname ?? "—") }
                if let port = instance.sshLocalPort, port != 0 {
                    LabeledContent("SSH") {
                        CopyableText(text: "ssh -F \(instance.sshConfigFile ?? "~/.lima/\(instance.name)/ssh.config") lima-\(instance.name)")
                    }
                    LabeledContent("SSH ポート") { Text(verbatim: "\(instance.sshAddress ?? "127.0.0.1"):\(port)") }
                }
                LabeledContent("シェル") { CopyableText(text: "limactl shell \(instance.name)") }
            }

            Section("その他") {
                LabeledContent("ディレクトリ") {
                    Button(instance.dir) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: instance.dir)])
                    }
                    .buttonStyle(.link)
                }
                LabeledContent("Lima バージョン") { Text(instance.limaVersion ?? "—") }
            }
        }
        .formStyle(.grouped)
    }
}

/// Monospaced text with a copy button.
struct CopyableText: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("コピー")
        }
    }
}
