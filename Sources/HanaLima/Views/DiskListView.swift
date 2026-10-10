import AppKit
import LimaKit
import SwiftUI

/// All disks managed by `limactl disk`, like a virtual disk manager in desktop virtualization apps.
struct DiskListView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: LimaDisk.ID?
    @State private var showCreate = false
    @State private var resizing: LimaDisk?
    @State private var deleting: LimaDisk?

    private var selected: LimaDisk? { model.disks.first { $0.id == selection } }

    var body: some View {
        Group {
            if model.disks.isEmpty {
                ContentUnavailableView {
                    Label("ディスクがありません", systemImage: "externaldrive")
                } description: {
                    Text("追加ディスクを作成して、仮想マシンの「設定」から接続できます。")
                } actions: {
                    Button("新規ディスク…") { showCreate = true }
                }
            } else {
                Table(model.disks, selection: $selection) {
                    TableColumn("名前", value: \.name)
                    TableColumn("サイズ") { Text(Formatting.bytes($0.size)).monospacedDigit() }
                        .width(min: 70, ideal: 90)
                    TableColumn("形式") { Text($0.format ?? "—") }
                        .width(min: 50, ideal: 60)
                    TableColumn("接続先") { disk in
                        if let inst = disk.attachedInstance {
                            Button(inst) { model.selection = .instance(inst) }.buttonStyle(.link)
                        } else {
                            Text("未接続").foregroundStyle(.secondary)
                        }
                    }
                    TableColumn("ゲストでのマウント先") { Text($0.mountPoint ?? "—").font(.callout.monospaced()) }
                }
                .contextMenu(forSelectionType: LimaDisk.ID.self) { ids in
                    if let disk = model.disks.first(where: { ids.contains($0.id) }) {
                        Button("サイズを変更…") { resizing = disk }
                        Button("Finder で表示") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: disk.dir)])
                        }
                        Divider()
                        Button("削除…", role: .destructive) { deleting = disk }
                            .disabled(disk.attachedInstance != nil)
                    }
                }
            }
        }
        .navigationTitle("ディスク")
        .navigationSubtitle(model.isDiskBusy ? "処理中…" : "\(model.disks.count) 個")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if model.isDiskBusy { ProgressView().controlSize(.small) }
                Button { showCreate = true } label: { Label("新規ディスク", systemImage: "plus") }
                    .help("新規ディスク")
                Button { resizing = selected } label: { Label("サイズ変更", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("サイズ変更")
                    .disabled(selected == nil || model.isDiskBusy)
                Button(role: .destructive) { deleting = selected } label: { Label("削除", systemImage: "trash") }
                    .help(selected?.attachedInstance != nil ? "接続中のディスクは削除できません" : "削除")
                    .disabled(selected == nil || selected?.attachedInstance != nil || model.isDiskBusy)
            }
        }
        .sheet(isPresented: $showCreate) { CreateDiskSheet() }
        .sheet(item: $resizing) { ResizeDiskSheet(disk: $0) }
        .confirmationDialog("ディスク「\(deleting?.name ?? "")」を削除しますか？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("削除", role: .destructive) {
                if let disk = deleting { Task { _ = await model.deleteDisk(disk.name) } }
            }
        } message: {
            Text("ディスク上のデータはすべて失われます。この操作は取り消せません。")
        }
    }
}

struct CreateDiskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Called with the new disk's name after it's created.
    var onCreated: ((String) -> Void)?

    @State private var name = ""
    @State private var sizeGiB = 20
    @State private var format = "qcow2"
    @State private var isCreating = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名前", text: $name, prompt: Text("data"))
                if let nameError {
                    Text(nameError).font(.caption).foregroundStyle(.red)
                }
                Stepper(value: $sizeGiB, in: 1...4096, step: 5) {
                    LabeledContent("サイズ", value: "\(sizeGiB) GiB")
                }
                Picker("形式", selection: $format) {
                    Text("qcow2（スパース）").tag("qcow2")
                    Text("raw").tag("raw")
                }
                Text("VZ の仮想マシンでは、初回起動時に Lima が raw 形式へ変換します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isCreating { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    isCreating = true
                    Task {
                        let ok = await model.createDisk(name, sizeGiB: sizeGiB, format: format)
                        isCreating = false
                        if ok {
                            onCreated?(name)
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || nameError != nil || isCreating)
            }
            .padding()
        }
        .frame(width: 420, height: 320)
    }

    private var nameError: String? {
        guard !name.isEmpty else { return nil }
        if !CreateOptions.isValidName(name) { return String(localized: "英数字と . _ - が使えます（記号は連続不可）。") }
        if model.disks.contains(where: { $0.name == name }) { return String(localized: "「\(name)」は既に存在します。") }
        return nil
    }
}

private struct ResizeDiskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let disk: LimaDisk
    @State private var sizeGiB = 0
    @State private var isResizing = false

    private var currentGiB: Int { Int((Double(disk.size) / Double(1 << 30)).rounded(.up)) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                LabeledContent("ディスク", value: disk.name)
                LabeledContent("現在のサイズ", value: Formatting.bytes(disk.size))
                Stepper(value: $sizeGiB, in: currentGiB...max(currentGiB, 4096), step: 5) {
                    LabeledContent("新しいサイズ", value: "\(sizeGiB) GiB")
                }
                Text("拡張のみ可能です。ゲスト側のファイルシステムは次回起動時に Lima が拡張します。")
                    .font(.caption).foregroundStyle(.secondary)
                if let inst = disk.attachedInstance,
                   model.instance(named: inst)?.isRunning == true {
                    Label("「\(inst)」の実行中はサイズを変更できません。", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isResizing { ProgressView().controlSize(.small) }
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("変更") {
                    isResizing = true
                    Task {
                        let ok = await model.resizeDisk(disk.name, sizeGiB: sizeGiB)
                        isResizing = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(sizeGiB <= currentGiB || isResizing)
            }
            .padding()
        }
        .frame(width: 420, height: 300)
        .onAppear { sizeGiB = currentGiB }
    }
}
