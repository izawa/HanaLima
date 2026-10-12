import AppKit
import LimaKit
import SwiftUI

/// Where Lima keeps VMs, disks and downloaded images, and how much space they use.
struct StorageView: View {
    @Environment(AppModel.self) private var model
    @State private var pruning: PruneKind?

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
                            if let external = row.externalDisk {
                                Text("\(Formatting.bytes(row.size)) ＋ 外部 \(Formatting.bytes(row.externalSize))")
                                    .monospacedDigit()
                                    .help(external.path)
                                RevealIcon(url: external)
                            } else {
                                Text(Formatting.bytes(row.size)).monospacedDigit()
                                RevealIcon(url: row.url)
                            }
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
                if model.metadata.values.contains(where: { $0.parent != nil }) {
                    Text("複製した仮想マシンは、コピー元と共有している部分も、それぞれの使用量に数えています（APFS のクローンの共有分は調べられないため）。実際の合計は、表示より少なくなります。")
                }
                }
                .font(.caption).foregroundStyle(.secondary)
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
                                externalDisk: item.externalDisk, externalSize: item.externalSize))
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
