import AgentKit
import LimaKit
import NetworkKit
import SwiftUI

/// The network map (docs/16): networks as vertical buses, the Mac and each VM as a row wired to
/// the buses it has a NIC on. Read-only and drawn from the configuration and the leases.
struct NetworkMapView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: Selection?

    enum Selection: Hashable { case row(String), bus(String) }

    var body: some View {
        let map = model.networkMap
        let layout = MapLayout(busCount: map.buses.count)
        HStack(spacing: 0) {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(map.rows) { row in
                            MapRowView(row: row, map: map, layout: layout, emphasis: emphasis(of: row, in: map), selection: $selection)
                        }
                        if map.rows.isEmpty {
                            Text("仮想マシンはまだありません。").foregroundStyle(.secondary).padding(layout.margin)
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 0) {
                            busHeaders(map, layout)
                            MapRowView(row: map.mac, map: map, layout: layout, emphasis: emphasis(of: map.mac, in: map), selection: $selection)
                        }
                        .background(.background)
                    }
                }
                .frame(width: layout.width, alignment: .leading)
                .padding(.bottom, layout.margin)
            }
            .contentShape(Rectangle())
            .onTapGesture { selection = nil }
            if selection != nil {
                Divider()
                MapInspector(map: map, selection: selection)
                    .frame(width: 260)
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("縦の線がネットワークで、点のある所でつながっています。設定とリースから描いた図で、通信が届くかは確かめていません。")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal).padding(.vertical, 6)
                .background(.bar)
        }
        #if DEBUG
        .task {
            if let name = DebugSnapshot.env["HANALIMA_SNAPSHOT_MAPSELECT"] {
                selection = map.buses.contains { $0.name == name } ? .bus(map.buses.first { $0.name == name }!.id) : .row(name)
            }
        }
        #endif
    }

    private func busHeaders(_ map: NetworkMap, _ layout: MapLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(width: layout.width, height: layout.headerHeight)
            ForEach(Array(map.buses.enumerated()), id: \.element.id) { i, bus in
                VStack(spacing: 2) {
                    Text(bus.name).font(.headline).lineLimit(1)
                    Text(MapText.kind(bus.kind)).font(.caption)
                    Text(MapText.exit(bus.kind)).font(.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(width: layout.busSpacing - 8)
                .opacity(busEmphasis(bus.id, in: map) ? 1 : 0.35)
                .contentShape(Rectangle())
                .onTapGesture { selection = .bus(bus.id) }
                .position(x: layout.busX(i), y: layout.headerHeight / 2)
            }
        }
        .frame(width: layout.width, height: layout.headerHeight, alignment: .topLeading)
    }

    private func emphasis(of row: NetworkMap.Row, in map: NetworkMap) -> Bool {
        switch selection {
        case nil: true
        case .row(let id): row.id == id
        case .bus(let id): row.ports.contains { $0.bus == id }
        }
    }

    private func busEmphasis(_ bus: String, in map: NetworkMap) -> Bool {
        switch selection {
        case nil: true
        case .bus(let id): id == bus
        case .row(let id): ([map.mac] + map.rows).first { $0.id == id }?.ports.contains { $0.bus == bus } == true
        }
    }
}

/// Fixed sizes; the buses' x positions follow from their order.
struct MapLayout {
    let busCount: Int
    let margin: CGFloat = 16
    let boxWidth: CGFloat = 150
    let badgeWidth: CGFloat = 96
    let busSpacing: CGFloat = 160
    let rowHeight: CGFloat = 58
    let headerHeight: CGFloat = 64

    /// Where a VM's wire starts: after its NIC 0 / vzNAT badges.
    var wireStartX: CGFloat { margin + boxWidth + 12 + badgeWidth + 4 }
    var firstBusX: CGFloat { wireStartX + 36 }
    func busX(_ i: Int) -> CGFloat { firstBusX + CGFloat(i) * busSpacing }
    var width: CGFloat { firstBusX + CGFloat(max(busCount, 1)) * busSpacing }
}

private struct MapRowView: View {
    @Environment(AppModel.self) private var model
    let row: NetworkMap.Row
    let map: NetworkMap
    let layout: MapLayout
    let emphasis: Bool
    @Binding var selection: NetworkMapView.Selection?

    var body: some View {
        let mid = layout.rowHeight / 2
        let attached = map.buses.indices.filter { i in row.ports.contains { $0.bus == map.buses[i].id } }
        ZStack(alignment: .topLeading) {
            // The buses run through every row.
            ForEach(map.buses.indices, id: \.self) { i in
                let picked = selection == .bus(map.buses[i].id)
                Path { p in
                    p.move(to: CGPoint(x: layout.busX(i), y: 0))
                    p.addLine(to: CGPoint(x: layout.busX(i), y: layout.rowHeight))
                }
                .stroke(picked ? Color.accentColor : Color.secondary.opacity(0.6), lineWidth: picked ? 3.5 : 2.5)
            }
            if let last = attached.last {
                Path { p in
                    p.move(to: CGPoint(x: row.kind == .mac ? layout.margin + layout.boxWidth : layout.wireStartX, y: mid))
                    p.addLine(to: CGPoint(x: layout.busX(last), y: mid))
                }
                .stroke(emphasis ? Color.primary : Color.secondary.opacity(0.3), lineWidth: emphasis ? 1.5 : 1)
            }
            ForEach(attached, id: \.self) { i in
                let port = row.ports.first { $0.bus == map.buses[i].id }!
                Circle()
                    .fill(dotColor(bus: map.buses[i].id))
                    .frame(width: 11, height: 11)
                    .position(x: layout.busX(i), y: mid)
                if let text = MapText.addresses(Array(port.addresses.prefix(1))).map({ port.addresses.count > 1 ? "\($0) +\(port.addresses.count - 1)" : $0 }) {
                    Text(text).font(.caption).monospacedDigit().lineLimit(1)
                        .fixedSize()
                        .position(x: layout.busX(i) + 8 + textWidth(text) / 2, y: mid - 12)
                        .opacity(emphasis ? 1 : 0.35)
                }
            }
            Group {
                box.frame(width: layout.boxWidth, height: layout.rowHeight - 12)
                    .position(x: layout.margin + layout.boxWidth / 2, y: mid)
                badges.frame(width: layout.badgeWidth, alignment: .leading)
                    .position(x: layout.margin + layout.boxWidth + 12 + layout.badgeWidth / 2, y: mid)
            }
            .opacity(emphasis ? 1 : 0.45)
        }
        .frame(width: layout.width, height: layout.rowHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { selection = .row(row.id) }
    }

    private var status: String { row.kind == .mac ? "" : model.statusText(of: row.name) }

    private var box: some View {
        let isRouter = !row.routerOf.isEmpty
        let tint: Color = row.kind == .mac ? .teal : isRouter ? .purple : .gray
        return VStack(spacing: 2) {
            Text(row.kind == .mac ? String(localized: "この Mac") : row.name).font(.headline).lineLimit(1)
            Text(MapText.subtitle(row, status: status)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selection == .row(row.id) ? Color.accentColor : tint.opacity(0.5),
                                                                lineWidth: selection == .row(row.id) ? 2 : 0.5))
    }

    @ViewBuilder private var badges: some View {
        if row.kind == .vm {
            VStack(alignment: .leading, spacing: 3) {
                if row.usernet { badge(String(localized: "NIC 0 → 外"), dashed: false) }
                if row.vzNAT { badge(String(localized: "vzNAT → 外"), dashed: false) }
                if !row.usernet && !row.vzNAT { badge(String(localized: "NIC 0 なし"), dashed: true) }
            }
        }
    }

    private func badge(_ text: String, dashed: Bool) -> some View {
        Text(text).font(.caption2).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(dashed ? .secondary : .primary)
            .background(Capsule().strokeBorder(.secondary, style: StrokeStyle(lineWidth: 0.5, dash: dashed ? [3, 3] : [])))
    }

    private func dotColor(bus: String) -> Color {
        if row.kind == .mac { return .teal }
        if row.routerOf.contains(bus) { return .purple }
        return emphasis ? .primary : .secondary
    }

    private func textWidth(_ s: String) -> CGFloat { CGFloat(s.count) * 6.6 }
}

private struct MapInspector: View {
    @Environment(AppModel.self) private var model
    let map: NetworkMap
    let selection: NetworkMapView.Selection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch selection {
                case .row(let id):
                    if let row = ([map.mac] + map.rows).first(where: { $0.id == id }) { rowDetails(row) }
                case .bus(let id):
                    if let bus = map.buses.first(where: { $0.id == id }) { busDetails(bus) }
                case nil:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    @ViewBuilder private func rowDetails(_ row: NetworkMap.Row) -> some View {
        Text(row.kind == .mac ? String(localized: "この Mac") : row.name).font(.headline)
        if row.kind == .vm {
            Text(MapText.subtitle(row, status: model.statusText(of: row.name))).font(.callout).foregroundStyle(.secondary)
            LabeledContent("名前", value: "lima-\(row.name)")
            if row.usernet { Text("NIC 0（Lima のユーザーモード）: Mac の 127.0.0.1、LAN、インターネットに届きます。").font(.callout) }
            else { Text("NIC 0 なし（隔離）。").font(.callout) }
            if row.vzNAT { Text("vzNAT: Mac 経由でインターネットへ。").font(.callout) }
        }
        ForEach(row.ports, id: \.bus) { port in
            if let bus = map.buses.first(where: { $0.id == port.bus }) {
                Divider()
                Text(bus.name).font(.subheadline.weight(.semibold))
                Text(MapText.kind(bus.kind)).font(.caption).foregroundStyle(.secondary)
                if !port.macs.isEmpty { LabeledContent("MAC", value: port.macs.joined(separator: ", ")) }
                LabeledContent("IP", value: MapText.addresses(port.addresses) ?? MapText.unknownAddress(bus.kind, running: row.running))
                if case .guestOnly = bus.kind, row.kind == .vm {
                    LabeledContent("DNS の名前", value: "lima-\(row.name).hanalima")
                }
                if row.routerOf.contains(bus.id) { Text("このネットワークのルーターです。").font(.callout) }
                let peers = map.members(of: bus.id).map(\.name).filter { $0 != row.name }
                if !peers.isEmpty { LabeledContent("同じネットワーク", value: peers.joined(separator: ", ")) }
            }
        }
        if row.ports.isEmpty { Text("HanaLima や Lima のネットワークにはつながっていません。").font(.callout).foregroundStyle(.secondary) }
    }

    @ViewBuilder private func busDetails(_ bus: NetworkMap.Bus) -> some View {
        Text(bus.name).font(.headline)
        LabeledContent("種類", value: MapText.kind(bus.kind))
        LabeledContent("外へ", value: MapText.exit(bus.kind))
        if let subnet = bus.subnet { LabeledContent("サブネット", value: subnet) }
        if let gateway = bus.gateway {
            if case .guestOnly = bus.kind { LabeledContent("DHCP・DNS", value: gateway) }
            else { LabeledContent("Mac のアドレス", value: gateway) }
        }
        if case .guestOnly(let router?, let vm) = bus.kind { LabeledContent("ルーター", value: vm.map { String(localized: "\(router)（\($0)）") } ?? router) }
        LabeledContent("Mac", value: bus.macOnSegment ? String(localized: "参加している") : String(localized: "参加していない"))
        let members = map.members(of: bus.id).map(\.name)
        LabeledContent("仮想マシン", value: members.isEmpty ? "—" : members.joined(separator: ", "))
    }
}

enum MapText {
    static func kind(_ kind: NetworkMap.Bus.Kind) -> String {
        switch kind {
        case .nat: String(localized: "NAT")
        case .hostOnly: String(localized: "ホストオンリー")
        case .bridged(let iface): String(localized: "ブリッジ \(iface)")
        case .guestOnly: String(localized: "ゲスト専用")
        case .lima(let mode): "Lima (\(mode))"
        case .deleted: String(localized: "削除したネットワーク")
        case .socket: String(localized: "ソケット")
        }
    }

    static func exit(_ kind: NetworkMap.Bus.Kind) -> String {
        switch kind {
        case .nat: String(localized: "Mac 経由で外へ")
        case .hostOnly: String(localized: "外へは出ない")
        case .bridged: String(localized: "LAN そのもの")
        case .guestOnly(let router, let vm):
            if let vm { String(localized: "ルーター \(vm) 経由") }
            else if let router { String(localized: "ルーター \(router)（VM なし）") }
            else { String(localized: "外へは出ない") }
        case .lima(let mode):
            switch mode {
            case "host": String(localized: "外へは出ない")
            case "bridged": String(localized: "LAN そのもの")
            default: String(localized: "Mac 経由で外へ")
            }
        case .deleted, .socket: "—"
        }
    }

    static func addresses(_ addresses: [NetworkMap.Address]) -> String? {
        guard !addresses.isEmpty else { return nil }
        return addresses.map { $0.source == .reservation ? String(localized: "\($0.ip) 固定") : $0.ip }.joined(separator: ", ")
    }

    static func unknownAddress(_ kind: NetworkMap.Bus.Kind, running: Bool) -> String {
        if case .bridged = kind { return String(localized: "LAN の DHCP が配る（HanaLima からは見えない）") }
        return running ? String(localized: "不明") : String(localized: "停止中")
    }

    /// `status`: the app's own wording (paused and hibernated VMs look running or stopped to Lima).
    static func subtitle(_ row: NetworkMap.Row, status: String) -> String {
        if row.kind == .mac { return String(localized: "ホスト") }
        var parts = [status]
        if let t = row.vmType { parts.append(t == "hanalima" ? String(localized: "ドライバー") : t) }
        if !row.routerOf.isEmpty { parts.append(String(localized: "ルーター")) }
        return parts.joined(separator: " · ")
    }
}
