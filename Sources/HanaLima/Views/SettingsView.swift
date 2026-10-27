import LimaKit
import SwiftUI

/// The app's Settings window (⌘,).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.showMenuBarExtra) private var showMenuBarExtra = true
    @AppStorage(AppSettings.ansiblePathKey) private var ansiblePath = ""

    var body: some View {
        Form {
            Section {
                Toggle("メニューバーに表示", isOn: $showMenuBarExtra)
            } footer: {
                Text("表示している間は、ウィンドウを閉じても HanaLima はメニューバーで動き続けます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if model.instances.isEmpty {
                    Text("仮想マシンはありません").foregroundStyle(.secondary)
                }
                ForEach(model.instances) { instance in
                    AutostartToggle(name: instance.name)
                }
            } header: {
                Text("ログイン時に自動で起動する仮想マシン")
            } footer: {
                Text("Lima の自動起動（limactl autostart）を使います。HanaLima を起動していなくても、Mac にログインすると仮想マシンが起動します。登録した仮想マシンの起動と停止は launchd を経由します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("ansible-playbook の場所") {
                    HStack {
                        if ansiblePath.isEmpty {
                            Text("自動で探す").foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: (ansiblePath as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced())
                                .lineLimit(1).truncationMode(.middle)
                                .help(ansiblePath)
                        }
                        AnsibleToolButtons(chooseTitle: "変更…")
                    }
                }
            } header: {
                Text("Ansible")
            } footer: {
                Text("指定がなければ Homebrew、pyenv、~/.local/bin などの通常の場所から探します。仮想マシンの設定タブの「Ansible」で Playbook を選んで実行できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Switch for `limactl autostart enable/disable`, shared by Settings and the overview tab.
struct AutostartToggle: View {
    @Environment(AppModel.self) private var model
    let name: String
    var title: String?
    @State private var isUpdating = false

    var body: some View {
        HStack {
            Toggle(title ?? name, isOn: Binding(
                get: { model.autostartInstances.contains(name) },
                set: { enabled in
                    isUpdating = true
                    Task {
                        await model.setAutostart(name, enabled: enabled)
                        isUpdating = false
                    }
                }))
                .disabled(isUpdating)
            if isUpdating { ProgressView().controlSize(.small) }
        }
    }
}
