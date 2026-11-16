import LimaKit
import SwiftUI

/// Renaming a stopped VM (docs/15): the new name, and what changes with it.
struct RenameInstanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("「\(name)」の名前を変更").font(.headline)
                    TextField("新しい名前", text: $newName, prompt: Text(name))
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
                Section("名前の変更で変わること") {
                    Label("ホスト名は、次の起動で lima-\(newName.isEmpty ? name : newName) になります。ゲスト専用ネットワークの DNS、Ansible、スクリプトの中で古い名前を使っていれば、書き換えてください。",
                          systemImage: "character.cursor.ibeam")
                    Label("MAC アドレスを指定していない NIC には、今の MAC アドレスを書き込みます。固定 IP（DHCP の予約）はそのまま使えます。",
                          systemImage: "network")
                    Label("スナップショット、グループ、メモ、ログイン時の自動起動は引き継ぎます。",
                          systemImage: "checkmark.circle")
                }
                .font(.callout)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("名前を変更") {
                    model.rename(name, to: newName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newName.isEmpty || problem != nil)
            }
            .padding()
        }
        .frame(width: 500, height: 400)
    }

    private var problem: String? {
        if let blocker = model.renameBlocker(name) { return blocker }
        if newName.isEmpty { return nil }
        return model.renameNameProblem(newName, of: name)
    }
}

struct RenameRequest: Identifiable, Equatable {
    let name: String
    var id: String { name }
}
