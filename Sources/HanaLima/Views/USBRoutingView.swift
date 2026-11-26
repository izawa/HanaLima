import LimaKit
import SwiftUI

/// Which VM receives each USB accessory assigned to HanaLima (docs/19): the default route and
/// a rule per device, with what the drivers report. One page for every VM, so a device can't
/// be switched on for two of them.
struct USBRoutingView: View {
    @Environment(AppModel.self) private var model

    private var routes: USBRoutes? { try? model.usbRoutes.get() }
    private var vms: [(name: String, target: USBTarget)] {
        model.usbTargets.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        let blocker = model.usbRoutesBlocker
        Form {
            Section {
                Picker("規則の無い機器の受け取り先", selection: Binding(
                    get: { routes?.defaultRoute },
                    set: { target in model.changeUSBRoutes { $0.defaultRoute = target } })) {
                    Text("なし（保留）").tag(USBTarget?.none)
                    destinationOptions(current: routes?.defaultRoute)
                }
                if let blocker {
                    Text(blocker).font(.caption).foregroundStyle(.red)
                } else if model.usbApplying {
                    Text("設定を反映中です。").font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(blocker != nil)

            Section("HanaLima に割り当てられた機器") {
                let devices = model.usbDevices
                if devices.isEmpty {
                    Text(model.usbReports.isEmpty
                         ? "HanaLima のドライバーの仮想マシンを起動し、メニューバーの「仮想マシンアクセサリ」で機器を「HanaLima で使用」にすると、ここに出ます。"
                         : "メニューバーの「仮想マシンアクセサリ」で「HanaLima で使用」にした機器が、ここに出ます。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(devices) { row in
                        DeviceRow(row: row, routes: routes, vms: vms)
                    }
                }
            }
            .disabled(blocker != nil)

            if !model.usbAbsentRules.isEmpty {
                Section("いまつながっていない機器の規則") {
                    ForEach(model.usbAbsentRules, id: \.match) { rule in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(Self.label(rule.match))
                                Text(String(localized: "受け取り先: \(model.usbName(of: rule.destination) ?? String(localized: "見つからない仮想マシン"))"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("削除") { model.changeUSBRoutes { $0.rules.removeAll { $0.match == rule.match } } }
                        }
                    }
                }
                .disabled(blocker != nil)
            }

            Section {
                Text("受け取れるのは、HanaLima のドライバーの仮想マシンが動いている間に、メニューバーの「仮想マシンアクセサリ」で「HanaLima で使用」にした機器です（ターミナルやログイン時の自動起動で起動した仮想マシンでは「不明なアプリケーション」と出ます）。受け取り先が止まっている機器は、ほかの仮想マシンには回さずに保留します。保留中の機器も Mac からは使えません。Mac で使うときは、メニューバーで「“このMac” で使用」にしてください。使用中のストレージの受け取り先を変えるときは、先に元の仮想マシンの中でアンマウントしてください。最初の 1 回は、リムーバブルボリュームへのアクセスの許可を求められます。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("USB 機器")
        .task {
            while !Task.isCancelled {
                model.updateUSBRoutes()
                await model.refreshUSBReports()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func destinationOptions(current: USBTarget?) -> some View {
        ForEach(vms, id: \.name) { vm in
            Text(vm.name).tag(USBTarget?.some(vm.target))
        }
        if let current, model.usbName(of: current) == nil {
            Text("見つからない仮想マシン（選び直してください）").tag(USBTarget?.some(current))
        }
    }

    /// "8564:1000 シリアル番号 …1OXI" or "8564:1000 ポート 0x03214000".
    static func label(_ match: USBRoutes.Match) -> String {
        let ids = String(format: "%04x:%04x", match.vendor, match.product)
        if let serial = match.serial { return String(localized: "\(ids) シリアル番号 …\(String(serial.suffix(4)))") }
        return String(localized: "\(ids) ポート \(String(format: "0x%08x", match.locationID ?? 0))")
    }

    private struct DeviceRow: View {
        @Environment(AppModel.self) private var model
        let row: USBDeviceRow
        let routes: USBRoutes?
        let vms: [(name: String, target: USBTarget)]

        private var identity: USBDeviceIdentity { row.device.identity }
        /// The device's own rule: by serial number first, as the routes try it.
        private var rule: USBRoutes.Rule? {
            [identity.serialMatch, identity.portMatch].compactMap { $0 }.lazy
                .compactMap { match in routes?.rules.first { $0.match == match } }.first
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(identity.name ?? identity.ids).fontWeight(.medium)
                    Text([identity.manufacturer, identity.ids].compactMap { $0 }.joined(separator: " ")).foregroundStyle(.secondary)
                }
                Picker("受け取り先", selection: Binding(
                    get: { rule?.destination },
                    set: { model.setUSBRoute(for: identity, to: $0, bySerial: bySerial) })) {
                    Text("規則の無い機器の受け取り先に従う").tag(USBTarget?.none)
                    ForEach(vms, id: \.name) { vm in Text(vm.name).tag(USBTarget?.some(vm.target)) }
                    if let destination = rule?.destination, model.usbName(of: destination) == nil {
                        Text("見つからない仮想マシン（選び直してください）").tag(USBTarget?.some(destination))
                    }
                }
                if identity.serial != nil, identity.locationID != nil {
                    Picker("見分け方", selection: Binding(
                        get: { bySerial },
                        set: { model.setUSBRoute(for: identity, to: rule?.destination, bySerial: $0) })) {
                        Text("シリアル番号（…\(String(identity.serial!.suffix(4)))）").tag(true)
                        Text("挿したポート").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .disabled(rule == nil)
                }
                Text(state).font(.caption).foregroundStyle(row.device.hold == nil ? Color.secondary : Color.orange)
                ForEach(row.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.red) }
            }
            .padding(.vertical, 2)
        }

        /// The rule's key, or for a device without one, the serial number unless it can't tell
        /// the device apart.
        private var bySerial: Bool {
            if let rule { return rule.match.isSerial }
            return identity.serial != nil && row.device.hold != .duplicate
        }

        private var state: String {
            let device = row.device
            if let vm = row.holder {
                switch device.state {
                case .attached: return String(localized: "\(vm) で使用中")
                case .attaching: return String(localized: "\(vm) に接続中")
                case .detaching: return String(localized: "\(vm) から取り外し中")
                default: return String(localized: "\(vm) への接続を待っています")
                }
            }
            switch device.hold {
            case .noDefault: return String(localized: "保留中（規則の無い機器の受け取り先が「なし」）")
            case .duplicate: return String(localized: "保留中（同じ規則に当たる機器がほかにもあります。見分け方を「挿したポート」にしてください）")
            case .unreadable: return String(localized: "保留中（機器の識別情報を読めません）")
            case nil: break
            }
            if let destination = device.destination {
                guard let name = model.usbName(of: destination) else { return String(localized: "保留中（受け取り先の仮想マシンが見つかりません）") }
                if model.instance(named: name)?.isRunning != true { return String(localized: "保留中（\(name) の起動待ち）") }
                return String(localized: "\(name) への接続を待っています")
            }
            return String(localized: "状態を確認できません")
        }
    }
}
