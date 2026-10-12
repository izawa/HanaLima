import AppKit
import LimaKit
import SwiftUI

/// Where Lima keeps VMs, disks and downloaded images, and how much space they use.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var pruning: PruneKind?
    @State private var deletingLeftover: Leftover?

    private enum PruneKind: Identifiable {
        case unreferred, all
        var id: Self { self }
    }

    var body: some View {
        Group {
            if let report = model.storage {
                form(report)
            } else {
                ProgressView("容量を計算しています…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("使用量")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isMeasuringStorage || model.isPruningCache { ProgressView().controlSize(.small) }
                Button { Task { await model.measureStorage() } } label: {
                    Label("再計算", systemImage: "arrow.clockwise")
                }
                .help("再計算")
                .disabled(model.isMeasuringStorage || model.isPruningCache)
            }
        }
        .task { await model.measureStorage() }
        .confirmationDialog(pruning == .all ? "ダウンロードしたイメージをすべて削除しますか？" : "使われていないイメージを削除しますか？",
                            isPresented: Binding(get: { pruning != nil }, set: { if !$0 { pruning = nil } })) {
            Button("削除", role: .destructive) {
                let all = pruning == .all
                Task { all ? await model.pruneCache() : await model.deleteUnusedDownloads() }
            }
        } message: {
            if pruning == .all {
                Text("仮想マシンはそのまま使えます。次に仮想マシンを作るときや、containerd などの部品が必要になったときに、ダウンロードし直します。")
            } else {
                let unused = model.storage?.unusedDownloads ?? []
                Text("どの仮想マシンも使っていないイメージ \(unused.count) 個（\(Formatting.bytes(unused.reduce(0) { $0 + $1.size }))）を削除します。同じテンプレートで仮想マシンを作るときに、ダウンロードし直します。\n\n\(unused.map(\.fileName).joined(separator: "\n"))")
            }
        }
    }

    private var subtitle: String {
        guard let report = model.storage else { return "" }
        return String(localized: "合計 \(Formatting.bytes(report.limaTotal + report.cacheTotal))")
    }

    private func form(_ report: StorageReport) -> some View {
        Form {
            Section {
                LabeledContent("場所") { RevealButton(url: report.limaHome) }
                ForEach(rows(report)) { row in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(sizeText(row)).monospacedDigit()
                                .help(row.externalDisk?.path ?? row.url.path)
                            RevealIcon(url: row.externalDisk ?? row.url)
                        }
                    } label: {
                        if let instance = row.instance {
                            Button(instance) { model.selection = .instance(instance) }.buttonStyle(.link)
                        } else {
                            Text(row.title)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("仮想マシンとディスク")
                    Spacer()
                    Text(Formatting.bytes(report.limaTotal)).monospacedDigit()
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                Text(report.externalTotal > 0
                     ? "仮想マシンのディスクはスパースファイルなので、実際に使っている容量を表示しています。「外部」は、外付けドライブなどへ移したディスクで、Mac の空き容量は使いません。"
                     : "仮想マシンのディスクはスパースファイルなので、実際に使っている容量を表示しています。一時的な仮想マシンのディスクは、「設定」タブから外付けドライブなどへ移せます。")
                if report.limaItems.contains(where: { $0.snapshotSize > 0 }) {
                    Text("スナップショットは、ディスクと共有している部分も数えています。実際に使っているのは、その後にディスクが変わった分だけです。")
                }
                if model.metadata.values.contains(where: { $0.parent != nil }) {
                    Text("複製した仮想マシンは、コピー元と共有している部分も、それぞれの使用量に数えています（APFS のクローンの共有分は調べられないため）。実際の合計は、表示より少なくなります。")
                }
                }
                .font(.caption).foregroundStyle(.secondary)
            }

            if !report.leftovers.isEmpty {
                leftoversSection(report.leftovers)
            }

            Section {
                LabeledContent("場所") { RevealButton(url: report.cacheRoot) }
                if report.downloads.isEmpty {
                    Text("ダウンロードしたイメージはありません").foregroundStyle(.secondary)
                }
                ForEach(report.downloads) { item in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(Formatting.bytes(item.size)).monospacedDigit()
                            RevealIcon(url: item.directory)
                        }
                    } label: {
                        Text(verbatim: item.fileName)
                            .lineLimit(1).truncationMode(.middle)
                            .help(item.url)
                        HStack(spacing: 6) {
                            UsageBadge(usage: item.usage)
                            if let date = item.downloaded {
                                Text(date, format: .dateTime.year().month().day().hour().minute())
                            }
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("使われていないイメージを削除…") { pruning = .unreferred }
                        .disabled(report.unusedDownloads.isEmpty)
                    Button("すべて削除…") { pruning = .all }
                        .disabled(report.downloads.isEmpty)
                }
                .disabled(model.isPruningCache || model.isAnyOperationRunning)
            } header: {
                HStack {
                    Text("ダウンロードしたイメージ（キャッシュ）")
                    Spacer()
                    Text(Formatting.bytes(report.cacheTotal)).monospacedDigit()
                }
            } footer: {
                Text(model.isAnyOperationRunning
                     ? "仮想マシンの作成や起動が終わるまで、キャッシュは削除できません。"
                     : "OS のイメージなどは、最初に使うときにここへダウンロードされ、次からは再利用されます。削除しても仮想マシンには影響しません。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private struct Row: Identifiable {
        var id: String { url.path }
        var title: String
        var instance: String?
        var url: URL
        var size: Int64
        var externalDisk: URL? = nil
        var externalSize: Int64 = 0
        var snapshotSize: Int64 = 0
    }

    /// "1.2 GB", "1.2 GB ＋ 外部 300 MB", "… ＋ スナップショット 40 MB".
    private func sizeText(_ row: Row) -> String {
        var parts = [Formatting.bytes(row.size)]
        if row.externalDisk != nil { parts.append(String(localized: "外部 \(Formatting.bytes(row.externalSize))")) }
        if row.snapshotSize > 0 { parts.append(String(localized: "スナップショット \(Formatting.bytes(row.snapshotSize))")) }
        return parts.joined(separator: String(localized: " ＋ ", comment: "Between sizes, as in 1.2 GB + external 300 MB"))
    }

    /// Data of VMs deleted with limactl (HanaLima deletes it along with the VM).
    private func leftoversSection(_ leftovers: [Leftover]) -> some View {
        Section {
            ForEach(leftovers) { item in
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(Formatting.bytes(item.size)).monospacedDigit()
                        RevealIcon(url: item.url)
                        Button("削除…") { deletingLeftover = item }
                            .disabled(model.isMeasuringStorage)
                    }
                } label: {
                    Text(leftoverTitle(item))
                    Text(item.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        } header: {
            Text("どの仮想マシンのものでもないデータ")
        } footer: {
            Text("limactl で直接削除した仮想マシンの、スナップショットや外付けドライブ上のディスクです。HanaLima で仮想マシンを削除すると一緒に削除しますが、limactl はこれらを知らないため残ります。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog(deletingLeftover.map(leftoverTitle).map { String(localized: "「\($0)」を削除しますか？") } ?? "",
                            isPresented: Binding(get: { deletingLeftover != nil }, set: { if !$0 { deletingLeftover = nil } })) {
            Button("削除", role: .destructive) {
                if let item = deletingLeftover { Task { await model.deleteLeftover(item) } }
            }
        } message: {
            Text("\(deletingLeftover?.url.path ?? "")（\(Formatting.bytes(deletingLeftover?.size ?? 0))）を削除します。この操作は取り消せません。")
        }
    }

    private func leftoverTitle(_ item: Leftover) -> String {
        let vm = item.instance ?? String(localized: "不明")
        return switch item.kind {
        case .snapshots(let count): String(localized: "削除した仮想マシン「\(vm)」のスナップショット \(count) 個")
        case .externalDisk: String(localized: "削除した仮想マシン「\(vm)」の外付けのディスク")
        }
    }

    /// Instances by name, `_disks` as additional disks, and Lima's small `_config`/`_networks` as one row.
    private func rows(_ report: StorageReport) -> [Row] {
        var rows: [Row] = []
        var other: Int64 = 0
        for item in report.limaItems {
            if item.name == "_disks" {
                rows.append(Row(title: String(localized: "追加ディスク"), url: item.url, size: item.size))
            } else if item.name.hasPrefix("_") {
                other += item.size
            } else {
                rows.append(Row(title: item.name, instance: item.name, url: item.url, size: item.size,
                                externalDisk: item.externalDisk, externalSize: item.externalSize,
                                snapshotSize: item.snapshotSize))
            }
        }
        rows.append(Row(title: String(localized: "Lima の設定など"), url: report.limaHome.appending(path: "_config"), size: other))
        return rows
    }
}

/// Whether a cached file is still needed: by which VMs, by none, or by Lima itself.
private struct UsageBadge: View {
    let usage: CachedDownload.Usage

    var body: some View {
        switch usage {
        case .usedBy(let names):
            Text("使用中: \(names.joined(separator: ", "))").foregroundStyle(.green)
        case .unused:
            Text("未使用").foregroundStyle(.orange)
        case .component:
            Text("Lima の部品").foregroundStyle(.secondary)
                .help("Lima が仮想マシンの起動時に使うファイルです（containerd の nerdctl など）。")
        }
    }
}

/// The path as a link that shows it in the Finder.
private struct RevealButton: View {
    let url: URL
    var body: some View {
        Button(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .buttonStyle(.link)
        .help("Finder で表示")
    }
}

private struct RevealIcon: View {
    let url: URL
    var body: some View {
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } label: {
            Image(systemName: "magnifyingglass.circle")
        }
        .buttonStyle(.borderless)
        .help("Finder で表示")
    }
}
