import AppKit
import LimaKit
import NetworkKit
import SwiftUI

/// Settings editor: a form for common fields, or the raw lima.yaml. Changes go through
/// `limactl edit`, so Lima validates them; Lima only allows edits while the VM is stopped.
struct ConfigTab: View {
    enum Mode: String, CaseIterable, Identifiable {
        case form = "フォーム"
        case yaml = "YAML"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .form: String(localized: "フォーム")
            case .yaml: "YAML"
            }
        }
    }

    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    @State private var mode: Mode = .form
    @State private var original: InstanceConfig?
    @State private var draft: InstanceConfig?
    @State private var yamlOriginal = ""
    @State private var yamlDraft = ""
    @State private var loadError: String?

    private var isDirty: Bool {
        switch mode {
        case .form: draft != original
        case .yaml: yamlDraft != yamlOriginal
        }
    }

    private var isLocked: Bool { instance.status != .stopped || model.isBusy(instance.name) }

    private var pendingExpressions: [String] {
        guard let draft, let original else { return [] }
        return draft.setExpressions(comparedTo: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if instance.status != .stopped {
                LockedBanner(instance: instance)
            }
            if let loadError {
                ContentUnavailableView("読み込めませんでした", systemImage: "doc.badge.ellipsis",
                                       description: Text(loadError))
            } else {
                switch mode {
                case .form:
                    if let draftBinding = Binding($draft), let original {
                        ConfigForm(config: draftBinding, original: original, vmType: instance.vmType)
                            .disabled(isLocked)
                    }
                case .yaml:
                    CodeEditor(text: $yamlDraft, isEditable: !isLocked)
                        .padding(8)
                }
            }
            Divider()
            footer
        }
        .task(id: instance.name) { load() }
        .onChange(of: instance.config) { _, _ in
            // Picks up edits made elsewhere (or our own save) unless the user has pending changes.
            if !isDirty { load() }
        }
    }

    private var header: some View {
        HStack {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(isDirty)
            .help(isDirty ? "保存するか元に戻してから切り替えてください" : "")
            Spacer()
            Text(instance.configURL.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("再読み込み", systemImage: "arrow.clockwise") { load() }
                .disabled(isDirty)
            Button("Finder で表示", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([instance.configURL])
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if mode == .form, !pendingExpressions.isEmpty {
                Text((["limactl edit", instance.name] + pendingExpressions.map { "--set '\($0)'" }).joined(separator: " "))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            } else if isDirty {
                Text("未保存の変更があります").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("元に戻す") { revert() }
                .disabled(!isDirty)
            Button("保存") { save() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty || isLocked)
        }
        .padding(12)
    }

    private func load() {
        guard let client = model.client else { return }
        do {
            yamlOriginal = try client.configYAML(of: instance)
            yamlDraft = yamlOriginal
            let config = try client.config(of: instance)
            original = config
            draft = config
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func revert() {
        draft = original
        yamlDraft = yamlOriginal
    }

    private func save() {
        let done: @MainActor (Bool) -> Void = { ok in
            // On success, reload what Lima actually wrote; on failure keep the draft for fixing.
            if ok { load() }
        }
        switch mode {
        case .form: model.edit(instance.name, set: pendingExpressions, completion: done)
        case .yaml: model.replaceConfig(instance.name, yaml: yamlDraft, completion: done)
        }
    }
}

private struct LockedBanner: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text("仮想マシンの実行中は設定を変更できません。")
            Spacer()
            if instance.isRunning {
                Button("停止") { model.stop(instance.name) }
                    .disabled(model.isBusy(instance.name))
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.yellow.opacity(0.12))
    }
}

// MARK: - Form

private struct ConfigForm: View {
    @Environment(AppModel.self) private var model
    @Binding var config: InstanceConfig
    let original: InstanceConfig
    let vmType: String?

    var body: some View {
        Form {
            HardwareSection(config: $config, original: original, vmType: vmType)
            NetworkSection(networks: $config.networks, vmType: vmType)
            MountSection(mounts: $config.mounts)
            PortForwardSection(portForwards: $config.portForwards)
            DiskSection(disks: $config.additionalDisks)
            ProvisionSection(provision: $config.provision)
        }
        .formStyle(.grouped)
    }
}

private struct HardwareSection: View {
    @Binding var config: InstanceConfig
    let original: InstanceConfig
    let vmType: String?

    var body: some View {
        Section("ハードウェア") {
            Stepper(value: Binding(get: { config.cpus ?? 1 }, set: { config.cpus = $0 }),
                    in: 1...HostInfo.cpuCount) {
                LabeledContent("仮想 CPU") { Text("\(config.cpus ?? 1) コア") }
            }
            Stepper(value: gib(\.memory, fallback: 4), in: 1...HostInfo.memoryGiB) {
                LabeledContent("メモリ", value: "\(ByteSize.gibValue(config.memory) ?? 4) GiB")
            }
            Stepper(value: gib(\.disk, fallback: 100), in: minDisk...max(minDisk, 4096), step: 5) {
                LabeledContent("ディスク", value: "\(ByteSize.gibValue(config.disk) ?? 100) GiB")
            }
            Text("ディスクは拡張のみ可能です（縮小はできません）。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(isOn: Binding(get: { (config.videoDisplay ?? "none") != "none" },
                                 set: { config.videoDisplay = $0 ? "default" : "none" })) {
                Text("画面（ディスプレイ）")
                Text(isVZ
                     ? "起動すると仮想マシンの画面ウィンドウが開きます。概要タブに画面のサムネイルを表示します。"
                     : "起動すると仮想マシンの画面ウィンドウが開きます（QEMU ではサムネイルは表示できません）。")
            }
        }
    }

    private var isVZ: Bool { (vmType ?? "vz").lowercased() == "vz" }

    private var minDisk: Int { ByteSize.gibValue(original.disk) ?? 10 }

    private func gib(_ key: WritableKeyPath<InstanceConfig, String?>, fallback: Int) -> Binding<Int> {
        Binding(get: { ByteSize.gibValue(config[keyPath: key]) ?? fallback },
                set: { config[keyPath: key] = ByteSize.gib($0) })
    }
}

private struct NetworkSection: View {
    @Environment(AppModel.self) private var model
    @Binding var networks: [NetworkConfig]
    let vmType: String?
    @State private var showSocketVMNetSetup = false

    var body: some View {
        Section {
            LabeledContent("NIC 0") { Text("ユーザーモード NAT（常に有効）") }
            ForEach($networks) { $nic in
                let index = networks.firstIndex { $0.id == nic.id } ?? 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("NIC \(index + 1)", selection: $nic.kind) {
                            ForEach(kindOptions(including: nic.kind), id: \.self) { kind in
                                Text(label(for: kind)).tag(kind)
                            }
                        }
                        RemoveButton { networks.removeAll { $0.id == nic.id } }
                    }
                    TextField("MAC アドレス", text: $nic.macAddress, prompt: Text("自動"))
                        .font(.callout.monospaced())
                    if let warning = warning(for: nic.kind) {
                        HStack {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                            if case .lima = nic.kind, !model.networks.socketVMNetInstalled {
                                Button("セットアップ…") { showSocketVMNetSetup = true }
                                    .buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
            }
            if let conflict = NetworkConflict.check(
                vm: "", attachments: networks.map(attachment), running: []) {
                Label("socket_vmnet のネットワーク（\(conflict.legacyNetworks.map { "lima:\($0)" }.joined(separator: ", "))）と HanaLima の仮想ネットワーク（\(conflict.virtualNetworks.joined(separator: ", "))）を同時に使います。HanaLima では動作を確認済みですが、macOS の不具合（FB25122122）のため、起動時に確認を表示します。",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Menu("NIC を追加", systemImage: "plus") {
                ForEach(kindOptions(including: nil), id: \.self) { kind in
                    Button(label(for: kind)) { networks.append(NetworkConfig(kind: kind)) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("ネットワーク")
        } footer: {
            Text("HanaLima の仮想ネットワーク（NAT・ホストオンリー・ブリッジ）と vzNAT は管理者権限なしで使えます。lima:shared / host / bridged には socket_vmnet が必要です。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showSocketVMNetSetup) { SocketVMNetSetupSheet() }
    }

    private func attachment(_ nic: NetworkConfig) -> NetworkConflict.Attachment {
        switch nic.kind {
        case .lima(let name): model.conflictAttachment(lima: name, socket: nil)
        case .socket(let path): model.conflictAttachment(lima: nil, socket: path)
        case .vzNAT: .other
        }
    }

    private func kindOptions(including current: NetworkConfig.Kind?) -> [NetworkConfig.Kind] {
        var options: [NetworkConfig.Kind] = []
        options += model.virtualNetworks.map { .socket($0.socketPath) }
        if vmType == "vz" { options.append(.vzNAT) }
        options += model.networks.networks.map { .lima($0.name) }
        if let current, !options.contains(current) { options.append(current) }
        return options
    }

    private func label(for kind: NetworkConfig.Kind) -> String {
        switch kind {
        case .vzNAT: return String(localized: "vzNAT（NAT・高速）")
        case .lima(let name):
            guard let net = model.networks.network(named: name) else { return "lima:\(name)" }
            let detail = switch net.mode {
            case "shared": "NAT \(net.gateway ?? "")"
            case "host": String(localized: "ホストオンリー \(net.gateway ?? "")")
            case "bridged": String(localized: "ブリッジ \(net.interface ?? "")")
            case "user-v2": String(localized: "VM 間ネットワーク \(net.gateway ?? "")")
            default: net.mode
            }
            return String(localized: "lima:\(name)（\(detail.trimmingCharacters(in: .whitespaces))）")
        case .socket(let path):
            if let vn = model.virtualNetwork(forSocket: path) {
                return vn.menuDescription
            }
            return "socket:\(path)"
        }
    }

    private func warning(for kind: NetworkConfig.Kind) -> String? {
        switch kind {
        case .vzNAT where vmType != "vz":
            return String(localized: "vzNAT は VZ でのみ使えます。")
        case .lima(let name):
            guard let net = model.networks.network(named: name) else {
                return String(localized: "networks.yaml に「\(name)」が定義されていません。")
            }
            if net.needsSocketVMNet && !model.networks.socketVMNetInstalled {
                return String(localized: "socket_vmnet が未インストールのため、このままでは起動に失敗します。")
            }
            return nil
        case .socket(let path):
            if model.virtualNetwork(forSocket: path) == nil, !FileManager.default.fileExists(atPath: path) {
                return String(localized: "ソケット \(path) が見つかりません。")
            }
            return nil
        default:
            return nil
        }
    }
}

private struct MountSection: View {
    @Binding var mounts: [MountConfig]

    var body: some View {
        Section {
            if mounts.isEmpty {
                Text("共有フォルダはありません").foregroundStyle(.secondary)
            }
            ForEach($mounts) { $mount in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("ホストのフォルダ", text: $mount.location)
                            .font(.callout.monospaced())
                        Button("選択…") {
                            if let path = chooseFolder() { mount.location = path }
                        }
                        RemoveButton { mounts.removeAll { $0.id == mount.id } }
                    }
                    TextField("ゲスト側のパス", text: $mount.mountPoint, prompt: Text("ホストと同じパス"))
                        .font(.callout.monospaced())
                    Toggle("ゲストからの書き込みを許可", isOn: $mount.writable)
                }
            }
            Button("共有フォルダを追加", systemImage: "plus") {
                if let path = chooseFolder() { mounts.append(MountConfig(location: path)) }
            }
            .buttonStyle(.borderless)
        } header: {
            Text("共有フォルダ")
        }
    }

    private func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "選択")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // Keep paths under the home directory portable, as Lima's own templates do.
        let home = NSHomeDirectory()
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") { return "~" + url.path.dropFirst(home.count) }
        return url.path
    }
}

private struct PortForwardSection: View {
    @Binding var portForwards: [PortForwardConfig]

    var body: some View {
        Section {
            if portForwards.isEmpty {
                Text("明示的なポートフォワードはありません（ゲストで待ち受けたポートは自動で転送されます）")
                    .foregroundStyle(.secondary)
            }
            ForEach($portForwards) { $rule in
                HStack {
                    if rule.isAdvanced {
                        Text(rule.summary)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("この規則は YAML モードで編集してください")
                    } else {
                        TextField("ホスト IP", text: $rule.hostIP, prompt: Text("127.0.0.1"))
                            .frame(width: 110)
                        Text(":")
                        TextField("ホスト", value: $rule.hostPort, format: .number.grouping(.never),
                                  prompt: Text("同じ"))
                            .frame(width: 70)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        TextField("ゲスト", value: $rule.guestPort, format: .number.grouping(.never))
                            .frame(width: 70)
                        Picker("", selection: $rule.proto) {
                            Text("既定").tag(String?.none)
                            Text("TCP").tag(String?.some("tcp"))
                            Text("UDP").tag(String?.some("udp"))
                            Text("TCP+UDP").tag(String?.some("any"))
                        }
                        .frame(width: 110)
                    }
                    Spacer()
                    RemoveButton { portForwards.removeAll { $0.id == rule.id } }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            Button("ポートフォワードを追加", systemImage: "plus") {
                portForwards.append(PortForwardConfig(guestPort: 80, hostPort: 8080))
            }
            .buttonStyle(.borderless)
        } header: {
            Text("ポートフォワード（ホスト → ゲスト）")
        }
    }
}

private struct DiskSection: View {
    @Environment(AppModel.self) private var model
    @Binding var disks: [AdditionalDiskConfig]
    @State private var showCreate = false

    var body: some View {
        Section {
            if disks.isEmpty {
                Text("追加ディスクはありません").foregroundStyle(.secondary)
            }
            ForEach(disks) { disk in
                HStack {
                    Image(systemName: "externaldrive")
                    Text(disk.name)
                    if let info = model.disks.first(where: { $0.name == disk.name }) {
                        Text(Formatting.bytes(info.size)).foregroundStyle(.secondary)
                        if let mp = info.mountPoint, !mp.isEmpty {
                            Text(mp).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    } else {
                        Label("見つかりません", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    RemoveButton(help: String(localized: "取り外す")) { disks.removeAll { $0.id == disk.id } }
                }
            }
            Menu("ディスクを接続", systemImage: "plus") {
                let available = model.disks.filter { d in
                    d.attachedInstance == nil && !disks.contains { $0.name == d.name }
                }
                ForEach(available) { d in
                    Button("\(d.name)（\(Formatting.bytes(d.size))）") {
                        disks.append(AdditionalDiskConfig(name: d.name))
                    }
                }
                if !available.isEmpty { Divider() }
                Button("新しいディスクを作成…") { showCreate = true }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("追加ディスク")
        } footer: {
            Text("ゲストでは /mnt/lima-<ディスク名> に自動でマウントされます。取り外してもディスクのデータは残ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showCreate) {
            CreateDiskSheet { name in disks.append(AdditionalDiskConfig(name: name)) }
        }
    }
}

struct RemoveButton: View {
    var help = String(localized: "削除")
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}
