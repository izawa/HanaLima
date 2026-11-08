import LimaKit
import SwiftUI

/// A VM group, shown when its sidebar row is selected (docs/12 4.3). The group-wide start, stop
/// and hibernate come in stage 2.
struct GroupDetailView: View {
    @Environment(AppModel.self) private var model
    let name: String
    @State private var selection: String?

    private struct Member: Identifiable {
        let order: Int
        let name: String
        var id: String { name }
    }

    var body: some View {
        if let group = model.sidebarGroups.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            content(group)
        } else {
            ContentUnavailableView("グループが見つかりません", systemImage: "folder")
        }
    }

    @ViewBuilder
    private func content(_ group: AppModel.SidebarGroup) -> some View {
        let counts = model.groupCounts(group)
        VStack(spacing: 0) {
            if let run = model.groupRun(of: group.name) {
                GroupRunPanel(group: group.name, run: run)
            }
            members(group)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let active = model.isGroupRunActive(group.name) || group.members.isEmpty
                Button { model.requestGroupRun(.start, group: group.name) } label: {
                    Label("すべて起動", systemImage: "play.fill")
                }
                .help("すべて起動（グループの並び順に 1 台ずつ）")
                .disabled(active)
                Button { model.requestGroupRun(.stop, group: group.name) } label: {
                    Label("すべて停止", systemImage: "stop.fill")
                }
                .help("すべて停止（並び順の逆に 1 台ずつ）")
                .disabled(active)
                if group.members.contains(where: { model.instance(named: $0)?.usesHanaLimaDriver == true }) {
                    Button { model.requestGroupRun(.hibernate, group: group.name) } label: {
                        Label("すべて休止", systemImage: "moon.zzz.fill")
                    }
                    .help("すべて休止（HanaLima のドライバーで動く仮想マシンを、並び順の逆に 1 台ずつ）")
                    .disabled(active)
                }
            }
        }
        .navigationTitle(group.name)
        .navigationSubtitle(String(localized: "\(counts.total) 台、実行中 \(counts.running) 台"))
    }

    @ViewBuilder
    private func members(_ group: AppModel.SidebarGroup) -> some View {
        Group {
            if group.members.isEmpty {
                ContentUnavailableView {
                    Label("仮想マシンがありません", systemImage: "folder")
                } description: {
                    Text("サイドバーで仮想マシンをこのグループへドラッグするか、仮想マシンのメニューの「グループへ移動」で入れます。")
                }
            } else {
                let members = group.members.enumerated().map { Member(order: $0.offset + 1, name: $0.element) }
                Table(members, selection: $selection) {
                    TableColumn("順") { Text("\($0.order)").monospacedDigit().foregroundStyle(.secondary) }
                        .width(min: 24, ideal: 28, max: 40)
                    TableColumn("名前") { member in
                        HStack(spacing: 6) {
                            StatusDot(color: dotColor(member.name))
                            Text(member.name)
                        }
                    }
                    .width(min: 120, ideal: 240)
                    TableColumn("状態") { Text(model.statusText(of: $0.name)) }
                        .width(min: 60, ideal: 90)
                    TableColumn("仮想化方式") { Text(model.instance(named: $0.name)?.vmType?.uppercased() ?? "—") }
                        .width(min: 60, ideal: 90)
                    TableColumn("CPU") { Text(model.instance(named: $0.name)?.cpus.map { "\($0)" } ?? "—").monospacedDigit() }
                        .width(min: 36, ideal: 44)
                    TableColumn("メモリ") { Text(model.instance(named: $0.name)?.memory.map { Formatting.bytes($0) } ?? "—").monospacedDigit() }
                        .width(min: 60, ideal: 80)
                }
                .contextMenu(forSelectionType: String.self) { names in
                    if let vm = names.first { InstanceActionsMenu(name: vm) }
                } primaryAction: { names in
                    if let vm = names.first { model.selection = .instance(vm) }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("並び順は、サイドバーでドラッグして変えられます。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
    }

    private func dotColor(_ name: String) -> Color {
        model.isPaused(name) ? .yellow : model.isHibernated(name) ? .indigo : model.instance(named: name)?.status.color ?? .gray
    }
}
