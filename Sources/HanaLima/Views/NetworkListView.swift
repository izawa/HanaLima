import AppKit
import LimaKit
import NetworkKit
import SwiftUI

/// Virtual network editor: HanaLima networks plus the built-in ones for reference.
struct NetworkListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?
    @State private var editing: VirtualNetwork?
    @State private var isCreating = false
    @State private var deleting: VirtualNetwork?
    @State private var showSocketVMNetSetup = false

    private var selected: VirtualNetwork? { model.virtualNetworks.first { $0.name == selection } }

    var body: some View {
        List(selection: $selection) {
            Section {
                if model.virtualNetworks.isEmpty {
                    Text("仮想ネットワークはまだありません。＋ で作成できます。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.virtualNetworks) { network in
                    NetworkRow(network: network)
                        .tag(network.name)
                        .contextMenu { menu(for: network) }
                }
            } header: {
                Text("HanaLima 仮想ネットワーク")
            } footer: {
                Text("macOS の vmnet を使い、ブリッジも含めて管理者権限なしで動作します。仮想マシンの「設定 → ネットワーク」で NIC を追加して接続します。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                BuiltinRow(name: String(localized: "ユーザーモード NAT"), detail: String(localized: "192.168.5.0/24・全 VM に常に存在・ホストからゲスト IP へは届かない"),
                           icon: "network")
                BuiltinRow(name: "vzNAT", detail: String(localized: "VZ 専用の NAT・サブネット指定不可（通常 192.168.64.0/24）"),
                           icon: "network")
                ForEach(model.networks.networks) { net in
                    BuiltinRow(name: "lima:\(net.name)",
                               detail: limaDetail(net),
                               icon: net.mode == "bridged" ? "cable.connector" : "network",
                               warning: net.needsSocketVMNet && !model.networks.socketVMNetInstalled
                                   ? String(localized: "socket_vmnet が未インストール") : nil)
                }
            } header: {
                HStack {
                    Text("組み込みのネットワーク（参考）")
                    Spacer()
                    Button("socket_vmnet（従来方式）の設定…") { showSocketVMNetSetup = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("ネットワーク")
        .navigationSubtitle("\(model.virtualNetworks.count) 個の仮想ネットワーク")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { isCreating = true } label: { Label("新規ネットワーク", systemImage: "plus") }
                    .help("新規ネットワーク")
                Button { editing = selected } label: { Label("編集", systemImage: "slider.horizontal.3") }
                    .help("編集")
                    .disabled(selected == nil)
                Button(role: .destructive) { deleting = selected } label: { Label("削除", systemImage: "trash") }
                    .help("削除")
                    .disabled(selected == nil)
            }
        }
        .sheet(isPresented: $isCreating) { NetworkEditorSheet(original: nil) }
        .sheet(isPresented: $showSocketVMNetSetup) { SocketVMNetSetupSheet() }
        .sheet(item: $editing) { NetworkEditorSheet(original: $0) }
        .confirmationDialog("ネットワーク「\(deleting?.name ?? "")」を削除しますか？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("削除", role: .destructive) {
                if let n = deleting { Task { await model.deleteVirtualNetwork(n.name) } }
            }
        } message: {
            if let n = deleting, !model.instances(using: n).isEmpty {
                Text("次の仮想マシンがこのネットワークを使っています: \(model.instances(using: n).map(\.name).joined(separator: ", "))。削除すると、実行中のものはこのネットワークで通信できなくなり、次の起動前にこの NIC を外すことになります（起動するときに外すかどうかを尋ねます）。")
            } else {
                Text("この操作は取り消せません。")
            }
        }
        .task {
            await model.refreshNetworkStates()
            #if DEBUG
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_SOCKETVMNET"] == "1" { showSocketVMNetSetup = true }
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_NEWNET"] != nil { isCreating = true }
            if let name = DebugSnapshot.env["HANALIMA_SNAPSHOT_EDITNET"] {
                editing = model.virtualNetworks.first { $0.name == name }
            }
            #endif
        }
    }

    @ViewBuilder
    private func menu(for network: VirtualNetwork) -> some View {
        Button("編集…") { editing = network }
        Button("ログを表示") {
            NSWorkspace.shared.open(NetworkPaths.log(for: network.name))
        }
        Divider()
        Button("削除…", role: .destructive) { deleting = network }
    }

    private func limaDetail(_ net: LimaNetworks.Network) -> String {
        switch net.mode {
        case "shared": String(localized: "socket_vmnet の NAT・\(net.gateway ?? "")")
        case "host": String(localized: "socket_vmnet のホストオンリー・\(net.gateway ?? "")")
        case "bridged": String(localized: "socket_vmnet のブリッジ・\(net.interface ?? "")")
        case "user-v2": String(localized: "VM 間ネットワーク（root 不要）・\(net.gateway ?? "")")
        default: net.mode
        }
    }
}

private struct NetworkRow: View {
    @Environment(AppModel.self) private var model
    let network: VirtualNetwork

    private var failureText: String {
        let detail = LaunchAgentManager().lastError(of: network.name) ?? String(localized: "詳細はログを確認してください")
        if detail.contains("vmnet_network_create: 1001") {
            return String(localized: "macOS がこのサブネットを使用中として扱っているため、ネットワークを作成できません。サブネットを変更するか、Mac を再起動してください。（\(detail)）")
        }
        return detail
    }

    var body: some View {
        let users = model.instances(using: network)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: network.isBridged ? "cable.connector" : network.mode == .shared ? "globe" : "house")
                .frame(width: 20)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(network.name).fontWeight(.medium)
                    Text(network.kindLabel)
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Group {
                    if network.isBridged {
                        Text("\(network.bridgedInterface) の LAN に接続・IP は LAN の DHCP から")
                    } else {
                        Text("\(network.subnet?.description ?? "—")・ゲートウェイ \(network.gateway)")
                    }
                }
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                ForEach(users) { inst in
                    HStack(spacing: 6) {
                        StatusDot(color: inst.status.color)
                        Text(inst.name)
                        if let r = model.reservation(of: inst, on: network) {
                            Text("\(r.ip)（固定）").monospaced()
                        } else if let ip = model.address(of: inst, on: network) {
                            Text(ip).monospaced()
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if !network.comment.isEmpty {
                    Text(network.comment).font(.caption).foregroundStyle(.secondary)
                }
                if case .failed = model.networkStates[network.name] {
                    Label(failureText, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            StateBadge(state: model.networkStates[network.name],
                       clients: model.networkStatuses[network.name]?.clients.count ?? 0)
        }
        .padding(.vertical, 4)
    }
}

private struct StateBadge: View {
    let state: LaunchAgentManager.State?
    let clients: Int

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var label: String {
        switch state {
        case .running: clients > 0 ? String(localized: "稼働中（\(clients) 台接続）") : String(localized: "稼働中")
        case .failed: String(localized: "エラー")
        case .waiting: String(localized: "待機中")
        case .notLoaded: String(localized: "未登録")
        case nil: "—"
        }
    }

    private var color: Color {
        switch state {
        case .running: .green
        case .failed: .red
        case .waiting: .secondary
        case .notLoaded: .orange
        case nil: .gray
        }
    }
}

private struct BuiltinRow: View {
    let name: String
    let detail: String
    let icon: String
    var warning: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .selectionDisabled()
    }
}

struct NetworkEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// nil when creating.
    let original: VirtualNetwork?

    @State private var draft = VirtualNetwork(name: "")
    @State private var isSaving = false
    @State private var interfaces: [SocketVMNetSetup.HostInterface] = []

    private var isNew: Bool { original == nil }

    /// VMs attached to this network that don't have a reservation yet.
    private var reservationCandidates: [(name: String, mac: String)] {
        guard let original else { return [] }
        let reserved = Set(draft.reservations.compactMap { DHCPReservation.normalizedMAC($0.mac) })
        return model.instances(using: original).compactMap { inst in
            guard let mac = model.macAddress(of: inst, on: original), !reserved.contains(mac) else { return nil }
            return (inst.name, mac)
        }
    }

    /// First address from .10 up that isn't the gateway, reserved, or currently leased.
    private var nextFreeAddress: String {
        guard let subnet = draft.subnet else { return "" }
        let taken = Set(draft.reservations.map(\.ip) + model.dhcpLeases.map(\.ip) + [draft.gateway])
        var candidate = subnet.network.value + 10
        while candidate < subnet.broadcast.value {
            let ip = IPv4(candidate).description
            if !taken.contains(ip) { return ip }
            candidate += 1
        }
        return ""
    }

    private var reservationSection: some View {
        Section {
            if draft.reservations.isEmpty {
                Text("固定 IP はありません").foregroundStyle(.secondary)
            }
            ForEach(Array(draft.reservations.indices), id: \.self) { i in
                HStack {
                    TextField("MAC アドレス", text: $draft.reservations[i].mac, prompt: Text("52:55:55:xx:xx:xx"))
                        .font(.callout.monospaced())
                        .frame(width: 170)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("IP アドレス", text: $draft.reservations[i].ip)
                        .font(.callout.monospaced())
                        .frame(width: 130)
                    TextField("メモ", text: $draft.reservations[i].comment, prompt: Text("VM 名など"))
                    RemoveButton { draft.reservations.remove(at: i) }
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            Menu("固定 IP を追加", systemImage: "plus") {
                ForEach(reservationCandidates, id: \.mac) { c in
                    Button("\(c.name)（\(c.mac)）") {
                        draft.reservations.append(DHCPReservation(mac: c.mac, ip: nextFreeAddress, comment: c.name))
                    }
                }
                if !reservationCandidates.isEmpty { Divider() }
                Button("MAC アドレスを手動で入力") {
                    draft.reservations.append(DHCPReservation(mac: "", ip: nextFreeAddress))
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        } header: {
            Text("固定 IP（DHCP 予約）")
        } footer: {
            Text("指定した MAC アドレスの NIC に常に同じ IP を割り当てます。VM の一覧には、このネットワークに接続している VM が表示されます。反映には VM の再起動が必要です。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var addressSection: some View {
        Section("アドレス") {
            TextField("ゲートウェイ（ホスト側）", text: $draft.gateway)
                .font(.body.monospaced())
            Picker("プレフィックス長", selection: $draft.prefixLength) {
                ForEach(VirtualNetwork.prefixLengths, id: \.self) { len in
                    Text("/\(len)（\(IPv4.mask(prefixLength: len).description)）").tag(len)
                }
            }
            if let subnet = draft.subnet {
                LabeledContent("サブネット", value: subnet.description)
                LabeledContent("DHCP") { Text("ゲートウェイ以外のアドレスを VM に自動で割り当てます") }
            }
        }
    }

    private var others: [VirtualNetwork] { model.virtualNetworks.filter { $0.name != original?.name } }
    private var errors: [VirtualNetwork.ValidationError] { draft.validate(against: others) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("名前", text: $draft.name, prompt: Text("dev"))
                        .disabled(!isNew)
                    if !isNew {
                        Text("名前は VM の設定から参照されるため変更できません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("種類", selection: $draft.mode) {
                        Text("NAT（外部に接続できる）").tag(VirtualNetwork.Mode.shared)
                        Text("ホストオンリー（ホストと VM のみ）").tag(VirtualNetwork.Mode.host)
                        Text("ブリッジ（LAN に直接接続）").tag(VirtualNetwork.Mode.bridged)
                    }
                    TextField("説明", text: $draft.comment, prompt: Text("任意"))
                }
                if draft.isBridged {
                    bridgeSection
                } else {
                    addressSection
                    reservationSection
                }
                if !errors.isEmpty && !(isNew && draft.name.isEmpty) {
                    Section {
                        ForEach(Array(errors.enumerated()), id: \.offset) { _, e in
                            Label(e.localizedDescription, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red).font(.callout)
                        }
                    }
                }
                if let original, draft != original {
                    let users = model.instances(using: original)
                    let running = users.filter(\.isRunning).map(\.name)
                    let stopped = users.filter { !$0.isRunning }.map(\.name)
                    if !running.isEmpty {
                        Section {
                            Label("保存するとネットワークが作り直されます。実行中の仮想マシン（\(running.joined(separator: ", "))）は、再起動するまでこのネットワークで通信できなくなります。保存したあと、再起動を案内します。",
                                  systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        }
                    } else if !stopped.isEmpty {
                        Section {
                            Label("このネットワークを使う仮想マシン（\(stopped.joined(separator: ", "))）は、次の起動から新しい設定を使います。",
                                  systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "作成" : "保存") {
                    isSaving = true
                    Task {
                        let ok = await model.saveVirtualNetwork(draft)
                        isSaving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!errors.isEmpty || isSaving || draft == original)
            }
            .padding()
        }
        .frame(width: 620, height: 640)
        .onAppear {
            draft = original ?? VirtualNetwork(
                name: "", gateway: VirtualNetwork.suggestedGateway(avoiding: model.virtualNetworks))
            #if DEBUG
            if isNew, let mode = DebugSnapshot.env["HANALIMA_SNAPSHOT_NEWNET"].flatMap(VirtualNetwork.Mode.init) {
                draft.name = "lan"
                draft.mode = mode
            }
            #endif
        }
        .task { interfaces = await SocketVMNetSetup.bridgeableInterfaces() }
    }

    /// Interfaces vmnet can bridge to, plus the saved one if it's currently missing (e.g. unplugged).
    private var interfaceChoices: [SocketVMNetSetup.HostInterface] {
        var list = interfaces
        if !draft.bridgedInterface.isEmpty, !list.contains(where: { $0.device == draft.bridgedInterface }) {
            list.append(.init(device: draft.bridgedInterface, displayName: String(localized: "\(draft.bridgedInterface)（現在は見つかりません）")))
        }
        return list
    }

    private var bridgeSection: some View {
        Section {
            Picker("接続先", selection: $draft.bridgedInterface) {
                ForEach(interfaceChoices, id: \.device) { i in
                    Text(i.displayName == i.device ? i.device : String(localized: "\(i.displayName)（\(i.device)）")).tag(i.device)
                }
            }
            LabeledContent("IP アドレス") { Text("LAN の DHCP サーバーから取得します") }
        } header: {
            Text("ブリッジ")
        } footer: {
            Text("VM は Mac と同じ LAN に、別の機器として参加します。固定 IP は LAN のルーターか VM の中で設定してください。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
