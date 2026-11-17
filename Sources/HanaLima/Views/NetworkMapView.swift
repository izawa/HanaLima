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
        .safeAreaInset(edge: .bottom) { footer }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.mapCheckRequest = MapCheckRequest(scope: .all) } label: {
                    Label("疎通を確かめる", systemImage: "dot.radiowaves.left.and.right")
                }
                .help("実行中の仮想マシンの中から ping して、つながりを確かめる")
                .disabled(model.mapCheckRun != nil)
            }
        }
        .sheet(item: Bindable(model).mapCheckRequest) { MapCheckSheet(request: $0) }
        .task {
            // Guest-only networks' counters (docs/17), only while the map shows.
            while !Task.isCancelled {
                #if DEBUG
                if DebugSnapshot.env["HANALIMA_SNAPSHOT_OBSERVE"] != nil { return }
                #endif
                model.pollObservations()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        #if DEBUG
        .task {
            if let name = DebugSnapshot.env["HANALIMA_SNAPSHOT_OBSERVE"] {
                while model.instances.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                model.fakeObservationForSnapshot(name)
            }
            if DebugSnapshot.env["HANALIMA_SNAPSHOT_MAPCHECKS"] == "1" {
                while model.instances.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
                model.fakeMapChecksForSnapshot()
            }
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
                    if let counts = checkCounts(bus.id, in: map) { Text(counts).font(.caption2).foregroundStyle(.secondary) }
                    if let capture = model.observations[bus.name]?.current.capture, capture.endedAt == nil {
                        Label("記録中", systemImage: "record.circle").font(.caption2).foregroundStyle(.red)
                    }
                    if let faults = model.observations[bus.name]?.current.faults, !faults.isEmpty {
                        Label("障害 \(faults.count)", systemImage: "bolt.horizontal.circle").font(.caption2).foregroundStyle(.orange)
                    }
                }
                .contextMenu {
                    Button("このネットワークを確かめる…") { model.mapCheckRequest = MapCheckRequest(scope: .bus(id: bus.id, name: bus.name)) }
                        .disabled(model.mapCheckRun != nil)
                }
                .lineLimit(1)
                .frame(width: layout.busSpacing - 8, height: layout.headerHeight - 12, alignment: .top)
                .opacity(busEmphasis(bus.id, in: map) ? 1 : 0.35)
                .contentShape(Rectangle())
                .onTapGesture { selection = .bus(bus.id) }
                .position(x: layout.busX(i), y: layout.headerHeight / 2)
            }
        }
        .frame(width: layout.width, height: layout.headerHeight, alignment: .topLeading)
    }

    @ViewBuilder private var footer: some View {
        HStack {
            if let run = model.mapCheckRun {
                ProgressView().controlSize(.small)
                Text(run.current.map { String(localized: "確かめています: \($0)（\(run.done + 1)/\(run.total)）") } ?? String(localized: "確かめています"))
                    .font(.caption)
                Spacer()
                Button("中止") { model.cancelMapChecks() }.controlSize(.small).disabled(run.cancelled)
            } else {
                Text("縦の線がネットワークで、点のある所でつながっています。点の印は、ゲストの中から ping した結果です（届いた・確かめられず）。確かめられなくても、届かないとは限りません。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal).padding(.vertical, 6)
        .background(.bar)
    }

    /// "届いた 2・確かめられず 1" for a bus's dots with results.
    private func checkCounts(_ bus: String, in map: NetworkMap) -> String? {
        var reached = 0, unverified = 0
        for row in map.members(of: bus) {
            switch MapChecks.state(bus: bus, in: model.mapChecks[row.name]?.record) {
            case .reached: reached += 1
            case .unverified, .partial: unverified += 1
            case .configOnly: break
            }
        }
        guard reached + unverified > 0 else { return nil }
        return String(localized: "届いた \(reached)・確かめられず \(unverified)")
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
    let headerHeight: CGFloat = 78

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
                if row.kind == .vm {
                    CheckMark(state: MapChecks.state(bus: map.buses[i].id, in: entry?.record), stale: stale, checking: checking)
                        .position(x: layout.busX(i) - 12, y: mid + 13)
                    if model.fault(on: map.buses[i].name, macs: port.macs) != nil {
                        Image(systemName: "bolt.horizontal.circle.fill").font(.caption).foregroundStyle(.orange)
                            .accessibilityLabel(String(localized: "障害"))
                            .position(x: layout.busX(i) + 12, y: mid + 13)
                    }
                }
                if let text = MapText.addresses(Array(port.addresses.prefix(1))).map({ port.addresses.count > 1 ? "\($0) +\(port.addresses.count - 1)" : $0 })
                    ?? reported(port).first {
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
        .contextMenu {
            if row.kind == .vm {
                Button("この VM を確かめる…") { model.mapCheckRequest = MapCheckRequest(scope: .vm(row.name)) }
                    .disabled(model.mapCheckRun != nil)
            }
        }
    }

    private var entry: MapCheckEntry? { model.mapChecks[row.name] }

    /// The addresses the guest reported on `port`'s NICs in the last check.
    private func reported(_ port: NetworkMap.Port) -> [String] {
        port.macs.flatMap { entry?.record.observed[$0] ?? [] }
    }
    private var stale: Bool { model.isMapCheckStale(row.name) }
    private var checking: Bool { model.mapCheckRun?.current == row.name }

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
                if row.usernet { exitBadge(String(localized: "NIC 0 → 外"), .nic0) }
                if row.vzNAT { exitBadge(String(localized: "vzNAT → 外"), .vzNAT) }
                if !row.usernet && !row.vzNAT { badge(String(localized: "NIC 0 なし"), dashed: true) }
            }
        }
    }

    private func exitBadge(_ text: String, _ exit: MapProbe.Exit) -> some View {
        HStack(spacing: 3) {
            badge(text, dashed: false)
            CheckMark(state: MapChecks.state(exit: exit, in: entry?.record), stale: stale, checking: false)
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
            checkResults(row.name, [], probes: { $0.exit != nil })
            if let entry = model.mapChecks[row.name] {
                Text(model.isMapCheckStale(row.name)
                     ? String(localized: "\(entry.record.at.formatted(date: .omitted, time: .shortened)) に確かめた結果（そのあと構成か状態が変わったので古い）")
                     : String(localized: "\(entry.record.at.formatted(date: .omitted, time: .shortened)) に確かめた結果"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        ForEach(row.ports, id: \.bus) { port in
            if let bus = map.buses.first(where: { $0.id == port.bus }) {
                Divider()
                Text(bus.name).font(.subheadline.weight(.semibold))
                Text(MapText.kind(bus.kind)).font(.caption).foregroundStyle(.secondary)
                if !port.macs.isEmpty { LabeledContent("MAC", value: port.macs.joined(separator: ", ")) }
                let reported = port.macs.flatMap { model.mapChecks[row.name]?.record.observed[$0] ?? [] }
                LabeledContent("IP", value: MapText.addresses(port.addresses)
                    ?? (reported.isEmpty ? MapText.unknownAddress(bus.kind, running: row.running)
                        : String(localized: "\(reported.joined(separator: ", "))（ゲストの答え）")))
                if case .guestOnly = bus.kind, row.kind == .vm {
                    LabeledContent("DNS の名前", value: "lima-\(row.name).hanalima")
                }
                if row.routerOf.contains(bus.id) { Text("このネットワークのルーターです。").font(.callout) }
                if row.kind == .vm { checkResults(row.name, port.macs, probes: { $0.bus == bus.id }) }
                if row.kind == .vm, case .guestOnly = bus.kind {
                    // Per NIC: its counters and its fault. Several NICs on one network get their MAC as a heading.
                    ForEach(port.macs, id: \.self) { mac in
                        // Several NICs on one network: each under the guest's name for it and its MAC.
                        let nic = port.nics.first { $0.mac == mac }?.interface.map { "\($0) (\(mac))" } ?? mac
                        if port.macs.count > 1 { Text(nic).font(.caption.monospaced().weight(.semibold)) }
                        if let sample = model.observations[bus.name] {
                            ForEach(ObservationText.ports(of: [mac], in: sample.current)) { counters in
                                PortCountersView(port: counters, sample: sample)
                            }
                        }
                        FaultControl(network: bus.name, target: mac, name: port.macs.count > 1 ? "\(row.name) \(nic)" : row.name)
                    }
                }
                let peers = map.members(of: bus.id).map(\.name).filter { $0 != row.name }
                if !peers.isEmpty { LabeledContent("同じネットワーク", value: peers.joined(separator: ", ")) }
            }
        }
        if row.ports.isEmpty { Text("HanaLima や Lima のネットワークにはつながっていません。").font(.callout).foregroundStyle(.secondary) }
    }

    /// The probes `filter` picks from `vm`'s last run, and the addresses the guest had on `macs`.
    @ViewBuilder private func checkResults(_ vm: String, _ macs: [String], probes filter: (MapProbe) -> Bool) -> some View {
        if let record = model.mapChecks[vm]?.record {
            let observed = macs.flatMap { record.observed[$0] ?? [] }
            if !observed.isEmpty { LabeledContent("ゲストのアドレス", value: observed.joined(separator: ", ")) }
            ForEach(record.probes.filter(filter), id: \.id) { probe in
                let outcome = record.outcomes[probe.id]
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: outcome?.reached == true ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundStyle(outcome?.reached == true ? .green : .yellow)
                        .accessibilityLabel(outcome?.reached == true ? String(localized: "届いた") : String(localized: "確かめられず"))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(MapText.probe(probe)).font(.callout)
                        if outcome?.reached != true, let reason = outcome?.reason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        if let at = outcome?.at, at != record.at {
                            Text("\(at.formatted(date: .omitted, time: .shortened)) に確かめた").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
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
        if case .guestOnly = bus.kind {
            Divider()
            SegmentObservationView(network: bus.name, map: map, bus: bus.id)
        }
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

    static func probe(_ probe: MapProbe) -> String {
        let exit: String = switch probe.exit {
        case .nic0: String(localized: "NIC 0 から")
        case .vzNAT: String(localized: "vzNAT から")
        case nil: ""
        }
        let target: String = switch probe.target {
        case .gateway(let ip): String(localized: "Mac（\(ip)）へ")
        case .router(let ip): String(localized: "ルーター（\(ip)）へ")
        case .peer(let vm, let ip): String(localized: "\(vm)（\(ip)）へ")
        case .outside(let ip): String(localized: "外（\(ip)）へ")
        }
        return exit.isEmpty ? target : exit + " " + target
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

/// A check's mark on a dot or badge (docs/16 §5.2): nothing when not checked.
private struct CheckMark: View {
    let state: MapChecks.State
    let stale: Bool
    let checking: Bool

    var body: some View {
        if checking {
            ProgressView().controlSize(.mini)
        } else {
            switch state {
            case .configOnly:
                EmptyView()
            case .reached:
                mark("checkmark.circle.fill", .green, String(localized: "届いた"))
            case .unverified:
                mark("questionmark.circle.fill", .yellow, String(localized: "確かめられず"))
            case .partial(let reached, let total):
                Text("\(reached)/\(total)").font(.caption2.monospacedDigit()).padding(.horizontal, 3)
                    .background(Capsule().fill(.yellow.opacity(stale ? 0.15 : 0.35)))
                    .accessibilityLabel(String(localized: "\(total) 個中 \(reached) 個の NIC で届いた"))
            }
        }
    }

    private func mark(_ symbol: String, _ color: Color, _ label: String) -> some View {
        Image(systemName: stale ? "clock.fill" : symbol)
            .font(.caption)
            .foregroundStyle(stale ? Color.secondary : color)
            .accessibilityLabel(stale ? String(localized: "\(label)（古い）") : label)
    }
}

/// What a check request will do, and the outside address to try (docs/16 §5.3).
private struct MapCheckSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: MapCheckRequest
    @State private var outside = ""

    var body: some View {
        let targets = model.mapCheckTargets(request)
        VStack(spacing: 0) {
            Form {
                Section {
                    Text(title).font(.headline)
                    Text("実行中の仮想マシンの中から、NIC ごとに ping します（Mac のアドレス、ルーター、同じネットワークの仮想マシン 1 台）。1 台ずつ順に実行し、その間はその仮想マシンの起動・停止はできません。届かなかった ping は「確かめられず」で、届かないことの証明ではありません。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("対象") {
                    if targets.run.isEmpty { Text("確かめられる仮想マシンがありません。").foregroundStyle(.secondary) }
                    ForEach(targets.run, id: \.self) { Text($0) }
                    ForEach(targets.skipped, id: \.vm) { item in
                        LabeledContent(item.vm, value: String(localized: "飛ばす（\(item.reason)）")).foregroundStyle(.secondary)
                    }
                }
                if case .bus = request.scope {} else {
                    Section {
                        TextField("外の IPv4 アドレス（任意）", text: $outside, prompt: Text("例: 1.1.1.1"))
                        if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                    } footer: {
                        Text("入れたときだけ、NIC 0・vzNAT とルーターの後ろから、このアドレスに ping します。HanaLima が外の宛先を決めることはしません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("確かめる") {
                    model.runMapChecks(request, outside: outside.isEmpty ? nil : outside)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(targets.run.isEmpty || problem != nil)
            }
            .padding()
        }
        .frame(width: 480, height: 460)
        .onAppear { outside = model.mapCheckOutside ?? "" }
    }

    private var title: String {
        switch request.scope {
        case .all: String(localized: "疎通を確かめる")
        case .vm(let name): String(localized: "「\(name)」の疎通を確かめる")
        case .bus(_, let name): String(localized: "ネットワーク「\(name)」の疎通を確かめる")
        }
    }

    private var problem: String? {
        guard !outside.isEmpty else { return nil }
        return IPv4(outside) == nil ? String(localized: "IPv4 アドレスを数字で入れてください（名前は使えません）。") : nil
    }
}

/// A guest-only segment's counters and its packet capture (docs/17).
private struct SegmentObservationView: View {
    @Environment(AppModel.self) private var model
    let network: String
    let map: NetworkMap
    let bus: String
    @State private var confirming = false

    var body: some View {
        Text("ネットワークの側から見た流れ").font(.subheadline.weight(.semibold))
        if let sample = model.observations[network] {
            let o = sample.current
            if sample.isStale { Text("ヘルパーから新しい数が届いていません（止まったか、応えていません）。").font(.caption).foregroundStyle(.orange) }
            LabeledContent("netd の応答", value: ObservationText.counter(o.answered))
            LabeledContent("全員へ送った", value: "\(o.flooded)")
            LabeledContent("届け先なし", value: "\(o.undelivered)")
            ForEach(o.ports.filter(\.connected)) { port in
                VStack(alignment: .leading, spacing: 2) {
                    Text(ObservationText.portName(port, map: map, bus: bus)).font(.callout.weight(.medium))
                    PortCountersView(port: port, sample: sample)
                }
            }
            if !o.ports.contains(where: \.connected) { Text("つながっている仮想マシンはありません。").font(.caption).foregroundStyle(.secondary) }
            let closed = o.ports.filter { !$0.connected }
            if !closed.isEmpty {
                DisclosureGroup("切断した接続（\(closed.count)）") {
                    ForEach(closed) { port in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ObservationText.portName(port, map: map, bus: bus)).font(.callout.weight(.medium))
                            PortCountersView(port: port, sample: sample)
                        }
                    }
                }
                .font(.caption)
            }
            Divider()
            SegmentFaultsView(network: network, map: map, bus: bus, sample: sample)
            Divider()
            capture(o.capture)
        } else if model.olderHelpers.contains(network) {
            Text("このネットワークのヘルパーは古い版で、数を出せません。つながっている仮想マシンをすべて止めると、新しい版に入れ替わります。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Text("ヘルパーは動いていません。仮想マシンがつながると数え始めます。").font(.caption).foregroundStyle(.secondary)
            Divider()
            SegmentFaultsView(network: network, map: map, bus: bus, sample: nil)
            Divider()
            capture(nil)
        }
    }

    @ViewBuilder private func capture(_ capture: NetworkObservation.Capture?) -> some View {
        if let capture, capture.endedAt == nil {
            Label("パケットを記録中", systemImage: "record.circle").foregroundStyle(.red)
            Text("\(Int(capture.frames)) フレーム・\(Formatting.bytes(Int64(capture.bytes)))・記録から落とした \(Int(capture.lost))")
                .font(.caption).foregroundStyle(.secondary)
            Button("記録を止める") { model.stopCapture(network, id: capture.id) }
        } else if !FileManager.default.fileExists(atPath: NetworkPaths.control(for: network).path) {
            // Registered by an older helper: no control socket until it is replaced.
            Text("パケットの記録には、ヘルパーの新しい版が要ります。つながっている仮想マシンをすべて止めると入れ替わります。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            Button("パケットを記録…") { confirming = true }
                .confirmationDialog("ネットワーク「\(network)」のパケットを記録しますか？", isPresented: $confirming) {
                    Button("記録を始める") { model.startCapture(network) }
                } message: {
                    Text("このネットワークを流れるすべてのフレームを、中身ごと pcap のファイルに残します。パスワードなどが含まれることがあります。64 MiB か 5 分で止まります。ファイルは ~/Library/Application Support/HanaLima/Captures に、あなただけが読める形で置きます。")
                }
            if let capture {
                Text("前の記録: \(Int(capture.frames)) フレーム・\(Formatting.bytes(Int64(capture.bytes)))（\(ObservationText.reason(capture.reason))）")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("開く") { model.openCapture(capture) }
                    Button("Finder で表示") { model.revealCapture(capture) }
                }
                .controlSize(.small)
            }
        }
    }
}

/// What a fault does, its time left, and how to remove it (docs/18).
private struct FaultLine: View {
    @Environment(AppModel.self) private var model
    let network: String
    let fault: NetworkFault
    let target: String
    let stale: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                // The target, what the fault does, and its time left: a line each, so none breaks.
                Text(target).font(.callout)
                Text(FaultText.describe(fault.spec)).font(.caption)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(stale ? String(localized: "ヘルパーから更新が届かず、確かめられません")
                         : FaultText.remaining(fault.expiresAt.timeIntervalSince(context.date)))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            Button("外す") { model.stopFault(network, id: fault.id) }.controlSize(.small)
        }
    }
}

/// A VM's NIC on a guest-only network: its fault, or the button to start one.
private struct FaultControl: View {
    @Environment(AppModel.self) private var model
    let network: String
    let target: String
    let name: String
    @State private var showing = false

    var body: some View {
        let sample = model.observations[network]
        if let fault = model.fault(on: network, macs: [target]) {
            FaultLine(network: network, fault: fault,
                      target: fault.spec.isSegment ? String(localized: "セグメント全体") : name, stale: sample?.isStale == true)
        } else if model.canStartFault(network) {
            Button("障害を入れる…") { showing = true }
                .sheet(isPresented: $showing) { FaultSheet(network: network, target: target, name: name) }
        }
    }
}

/// The faults of a guest-only segment, and the button for one on the whole segment.
private struct SegmentFaultsView: View {
    @Environment(AppModel.self) private var model
    let network: String
    let map: NetworkMap
    let bus: String
    let sample: ObservationSample?
    @State private var showing = false

    var body: some View {
        Text("障害").font(.subheadline.weight(.semibold))
        if !model.canStartFault(network), (sample?.current.faults ?? []).isEmpty {
            Text("障害を入れるには、ヘルパーの新しい版が要ります。つながっている仮想マシンをすべて止めると入れ替わります。")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            let faults = sample?.current.faults ?? []
            ForEach(faults) { fault in
                FaultLine(network: network, fault: fault, target: name(of: fault), stale: sample?.isStale == true)
            }
            if faults.count > 1 { Button("すべて外す") { model.stopFault(network, id: nil) }.controlSize(.small) }
            if faults.isEmpty {
                Button("セグメント全体に障害を入れる…") { showing = true }
                    .sheet(isPresented: $showing) { FaultSheet(network: network, target: NetworkFault.Spec.everyone, name: network) }
                Text("仮想マシンひとつに入れるときは、その仮想マシンを選びます。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func name(of fault: NetworkFault) -> String {
        if fault.spec.isSegment { return String(localized: "セグメント全体") }
        return map.rows.first { $0.ports.contains { $0.bus == bus && $0.macs.contains(fault.spec.target) } }?.name ?? fault.spec.target
    }
}

/// Choosing a fault for a VM's NIC or the whole segment.
private struct FaultSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let network: String
    let target: String
    let name: String
    @State private var block = false
    @State private var delayMs = 100
    @State private var lossPercent = 0.0
    @State private var seconds = 300

    private var isSegment: Bool { target == NetworkFault.Spec.everyone }
    private var spec: NetworkFault.Spec {
        block ? .init(target: target, block: true, seconds: seconds)
            : .init(target: target, delayMs: delayMs, lossPercent: lossPercent, seconds: seconds)
    }
    private var valid: Bool { (try? spec.validated()) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSegment ? String(localized: "ネットワーク「\(network)」全体に障害を入れる")
                 : String(localized: "「\(name)」の NIC（\(network)）に障害を入れる")).font(.headline)
            Form {
                Picker("種類", selection: $block) {
                    Text("遅延と損失").tag(false)
                    Text(FaultText.block).tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: block) { seconds = block ? 30 : 300 }
                if !block {
                    TextField("遅延（ミリ秒、0〜5000）", value: $delayMs, format: .number)
                    TextField("損失（パーセント、0〜100）", value: $lossPercent, format: .number.precision(.fractionLength(0...1)))
                }
                Picker("期限", selection: $seconds) {
                    ForEach([10, 30, 60, 300, 600, 1800], id: \.self) { Text(FaultText.duration($0)).tag($0) }
                }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("障害を入れる") { model.startFault(network, spec); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }
        .padding()
        .frame(width: 440)
    }

    private var explanation: String {
        let scope = block
            ? (isSegment ? String(localized: "すべての仮想マシンの通信を、両方向とも止めます。拒否の応答は返さず、黙って捨てます。")
               : String(localized: "「\(name)」の通信を、両方向とも止めます。拒否の応答は返さず、黙って捨てます。"))
            : (isSegment ? String(localized: "すべての仮想マシンへ届くフレームにかかります。行きも帰りも遅れるので、ping の往復は遅延の 2 倍延びます。")
               : String(localized: "「\(name)」へ届くフレームにかかります（ping の往復は遅延の分だけ延びます）。"))
        return scope + String(localized: "netd の DHCP・ARP・DNS の応答も対象です。遮断でもゲストのリンクは上がったままです。期限が来ると外れ、アプリを終了しても期限までは続きます。パケットの記録には障害の前のフレームが残るので、落としたフレームも記録にあり、遅延は時刻に出ません。")
    }
}

enum FaultText {
    /// A fault that passes nothing (not the "Disconnect" of a button).
    static var block: String { String(localized: "fault-block", defaultValue: "遮断") }

    static func describe(_ spec: NetworkFault.Spec) -> String {
        if spec.block { return block }
        var parts: [String] = []
        if spec.delayMs > 0 { parts.append(String(localized: "遅延 \(spec.delayMs) ms")) }
        if spec.lossPercent > 0 { parts.append(String(localized: "損失 \(spec.lossPercent.formatted(.number.precision(.fractionLength(0...1)))) %")) }
        return parts.joined(separator: String(localized: "・", comment: "Between the parts of a fault, as in delay 100 ms, loss 1 %"))
    }

    static func remaining(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.up)))
        return String(localized: "残り \(s / 60):\(String(format: "%02d", s % 60))")
    }

    static func duration(_ seconds: Int) -> String {
        seconds < 60 ? String(localized: "\(seconds) 秒") : String(localized: "\(seconds / 60) 分")
    }
}

/// One connection's counters, with per-second rates when there are two samples.
private struct PortCountersView: View {
    let port: NetworkObservation.Port
    let sample: ObservationSample

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if !port.connected { Text("切断した接続").foregroundStyle(.secondary) }
            if sample.isStale { Text("古い数（ヘルパーから更新が届いていません）").foregroundStyle(.orange) }
            // Rates only for a live port with fresh samples.
            let live = port.connected && !sample.isStale
            line(String(localized: "ゲストから"), port.fromGuest, live ? sample.rate(\.fromGuest, port: port.id) : nil)
            line(String(localized: "ゲストへ"), port.toGuest, live ? sample.rate(\.toGuest, port: port.id) : nil)
            if port.droppedFull.frames > 0 { Text("落とした（キューが満杯）\(Int(port.droppedFull.frames))").font(.caption).foregroundStyle(.orange) }
            if port.droppedClosed.frames > 0 { Text("落とした（切断）\(Int(port.droppedClosed.frames))").font(.caption).foregroundStyle(.secondary) }
            if port.malformed > 0 { Text("壊れたフレーム \(Int(port.malformed))").font(.caption).foregroundStyle(.orange) }
            if port.droppedLoss.frames > 0 { Text("落とした（損失）\(Int(port.droppedLoss.frames))").font(.caption).foregroundStyle(.orange) }
            if port.droppedBlocked.frames > 0 { Text("落とした（障害の遮断）\(Int(port.droppedBlocked.frames))").font(.caption).foregroundStyle(.orange) }
            if port.droppedOverflow.frames > 0 { Text("落とした（遅延の列があふれた）\(Int(port.droppedOverflow.frames))").font(.caption).foregroundStyle(.orange) }
            if port.delayed.frames > 0 { Text("遅延の列 \(Int(port.delayed.frames)) フレーム・\(Formatting.bytes(Int64(port.delayed.bytes)))").font(.caption).foregroundStyle(.secondary) }
        }
        .font(.caption.monospacedDigit())
    }

    private func line(_ label: String, _ c: NetworkObservation.Counter, _ rate: (frames: Double, bytes: Double)?) -> some View {
        let perSecond = rate.map { String(localized: "（毎秒 \(Int($0.frames.rounded())) フレーム・\(Formatting.bytes(Int64($0.bytes)))）") } ?? ""
        return Text("\(label) \(Int(c.frames)) フレーム・\(Formatting.bytes(Int64(c.bytes)))\(perSecond)")
    }
}

enum ObservationText {
    static func counter(_ c: NetworkObservation.Counter) -> String {
        String(localized: "\(Int(c.frames)) フレーム・\(Formatting.bytes(Int64(c.bytes)))")
    }

    /// The VM whose NIC on `bus` has one of the port's MACs, or the MACs themselves.
    static func portName(_ port: NetworkObservation.Port, map: NetworkMap, bus: String) -> String {
        let owner = map.rows.first { row in row.ports.contains { $0.bus == bus && !Set($0.macs).isDisjoint(with: port.macs) } }
        if let owner { return owner.name }
        return port.macs.isEmpty ? String(localized: "接続 \(port.id)") : port.macs.joined(separator: ", ")
    }

    /// The ports (live first, then disconnected) whose learned MACs include one of `macs`.
    static func ports(of macs: [String], in o: NetworkObservation) -> [NetworkObservation.Port] {
        o.ports.filter { !Set($0.macs).isDisjoint(with: macs) }
    }

    static func reason(_ reason: String?) -> String {
        switch reason {
        case "stopped": String(localized: "止めた")
        case "size limit": String(localized: "大きさの上限")
        case "time limit": String(localized: "時間の上限")
        case "helper exited": String(localized: "ヘルパーが終了した")
        case let r?: r
        case nil: "—"
        }
    }
}
