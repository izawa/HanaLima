import LimaKit
import SwiftUI

/// Copying a stopped VM: a new name, a note, and what the copy keeps and doesn't.
struct CopyInstanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let source: String
    var snapshot: SnapshotRef? = nil
    @State private var name = ""
    @State private var note = ""
    @State private var startAfterCopy = false

    var body: some View {
        let instance = model.instance(named: source)
        VStack(spacing: 0) {
            Form {
                Section {
                    if let snapshot {
                        Text("「\(source)」のスナップショット「\(snapshot.label)」から新しい仮想マシンを作成").font(.headline)
                        Text("「\(source)」を複製し、ディスクをこのスナップショットの状態にします。「\(source)」自体は今の状態のままです。設定（CPU、メモリ、ネットワークなど）は今の「\(source)」のものです。")
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("「\(source)」を複製").font(.headline)
                        Text("ディスクを含む仮想マシン全体をコピーし、新しい仮想マシンとしてサイドバーに追加します。コピー元とコピーは、それぞれ独立して動きます。同じ仮想マシンをあとで今の状態に戻したいだけなら、「スナップショット」タブを使います。")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Section {
                    TextField("名前", text: $name, prompt: Text(suggestedName))
                    if let nameError {
                        Text(nameError).font(.caption).foregroundStyle(.red)
                    }
                    TextField("メモ", text: $note, prompt: Text("例: 検証用のクリーンな状態"))
                    Toggle("複製後すぐに起動", isOn: $startAfterCopy)
                }
                Section("コピーで変わること") {
                    Label("名前、ホスト名（lima-\(effectiveName)）、MAC アドレス、SSH の鍵は新しくなります。ディスクの中身（インストールしたソフトやファイル）はそのままです。",
                          systemImage: "person.2")
                    Label("固定 IP（DHCP の予約）とログイン時の自動起動は引き継ぎません。必要ならコピーに設定し直してください。",
                          systemImage: "network")
                    Label(diskText(instance), systemImage: "internaldrive")
                    if instance?.vmType?.lowercased() == "qemu" {
                        Label("スナップショットもコピーに含まれます。", systemImage: "camera")
                    } else {
                        Label("スナップショットはコピーに含まれません（コピー元に残ります）。", systemImage: "camera")
                    }
                }
                .font(.callout)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("複製") {
                    model.copy(source, as: effectiveName, note: note, thenStart: startAfterCopy, snapshot: snapshot)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameError != nil || model.copyBlocker(source) != nil)
            }
            .padding()
        }
        .frame(width: 540, height: 520)
    }

    private var suggestedName: String { model.suggestedCopyName(of: source) }
    private var effectiveName: String { name.isEmpty ? suggestedName : name }

    private var nameError: String? {
        let n = effectiveName
        if !CreateOptions.isValidName(n) {
            return String(localized: "英数字と . _ - が使えます（記号は連続不可、先頭と末尾は英数字）。")
        }
        if model.sidebarNames.contains(n) { return String(localized: "「\(n)」は既に存在します。") }
        if let blocker = model.copyBlocker(source) { return blocker }
        return nil
    }

    private func diskText(_ instance: LimaInstance?) -> String {
        let used = instance.map { Formatting.bytes(model.diskAllocatedSize(of: $0)) } ?? "—"
        if let instance, case .external(let url) = model.diskPlacement(of: instance) {
            return String(localized: "ディスク（今 \(used)）は、同じ外付けドライブ（\(DiskLocationText.describe(url))）の上にコピーします。APFS のクローンなので、すぐに終わり、最初は容量をほとんど使いません（どちらかが書き込んだ分だけ増えます）。")
        }
        return String(localized: "ディスク（今 \(used)）は APFS のクローンでコピーするので、すぐに終わり、最初は容量をほとんど使いません（どちらかが書き込んだ分だけ増えます）。")
    }
}
