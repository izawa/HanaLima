import LimaKit
import SwiftUI

/// Snapshots: Lima's (`limactl snapshot`) for QEMU instances, HanaLima's own (`DiskSnapshot`,
/// APFS clones of the disk) for VZ. Both only while stopped (see LimaSnapshot for why).
/// A snapshot returns this VM to an earlier state; making another VM is "Copy".
struct SnapshotTab: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    @State private var selection: LimaSnapshot.ID?
    @State private var isCreating = false
    @State private var restoring: LimaSnapshot?
    @State private var deleting: LimaSnapshot?

    private var list: [LimaSnapshot] { model.snapshots[instance.name] ?? [] }
    private var selected: LimaSnapshot? { list.first { $0.id == selection } }
    private var busy: Bool { model.isBusy(instance.name) }
    private var canOperate: Bool { !instance.isRunning && !busy }

    var body: some View {
        if instance.vmType?.lowercased() != "qemu" {
            DiskSnapshotContent(instance: instance)
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if instance.isRunning {
                StopFirstBar(instance: instance)
                Divider()
            }
            Table(list, selection: $selection) {
                TableColumn("タグ") { Text($0.tag).fontWeight(.medium) }
                TableColumn("作成日時") { s in
                    if let date = s.date {
                        Text(date, format: .dateTime.year().month().day().hour().minute().second())
                    } else {
                        Text("—")
                    }
                }
                TableColumn("メモリの状態") { s in
                    Text(s.vmSize == "0 B" ? String(localized: "なし（ディスクのみ）") : s.vmSize).foregroundStyle(.secondary)
                }
            }
            .contextMenu(forSelectionType: LimaSnapshot.ID.self) { ids in
                if let s = list.first(where: { ids.contains($0.id) }) {
                    Button("この状態に復元…") { restoring = s }.disabled(!canOperate)
                    Button("この状態から新しい仮想マシン…") {
                        model.copyRequest = CopyRequest(source: instance.name, snapshot: .lima(tag: s.tag))
                    }
                    .disabled(model.copyBlocker(instance.name) != nil)
                    Button("削除…", role: .destructive) { deleting = s }.disabled(!canOperate)
                }
            }
            .overlay {
                if list.isEmpty {
                    ContentUnavailableView("スナップショットはありません", systemImage: "camera.on.rectangle",
                                           description: Text("停止中に「作成」を押すと、その時点のディスクの状態を保存します。"))
                }
            }
            Divider()
            HStack {
                Text("起動ディスクの状態を保存します。追加ディスクは対象外です。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("復元…") { restoring = selected }
                    .disabled(selected == nil || !canOperate)
                Button("削除…") { deleting = selected }
                    .disabled(selected == nil || !canOperate)
                Button("作成…") { isCreating = true }
                    .disabled(!canOperate)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(12)
        }
        .task(id: "\(instance.name)-\(instance.status.label)-\(busy)") {
            if !busy { await model.loadSnapshots(instance.name) }
        }
        .sheet(isPresented: $isCreating) {
            CreateSnapshotSheet(name: instance.name, existing: Set(list.map(\.tag)))
        }
        .confirmationDialog("「\(restoring?.tag ?? "")」の状態に復元しますか？",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("復元", role: .destructive) {
                if let s = restoring { model.applySnapshot(instance.name, tag: s.tag) }
            }
        } message: {
            Text("起動ディスクが、このスナップショットを作成した時点の内容に戻ります。それ以降の変更は失われます。")
        }
        .confirmationDialog("スナップショット「\(deleting?.tag ?? "")」を削除しますか？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("削除", role: .destructive) {
                if let s = deleting { model.deleteSnapshot(instance.name, tag: s.tag) }
            }
        } message: {
            Text("この操作は取り消せません。")
        }
    }
}

private struct CreateSnapshotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    let existing: Set<String>
    @State private var tag = LimaSnapshot.suggestedTag()

    private var error: String? {
        if !LimaSnapshot.isValidTag(tag) { return String(localized: "英数字と . _ - で 64 文字以内にしてください（先頭は英数字）。") }
        if existing.contains(tag) { return String(localized: "同じタグのスナップショットがあります。") }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("タグ", text: $tag)
                    .font(.body.monospaced())
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red)
                }
                Text("「\(name)」の起動ディスクの現在の状態を保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    model.createSnapshot(name, tag: tag)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(error != nil)
            }
            .padding()
        }
        .frame(width: 440)
    }
}

/// Hint shown while the VM runs: snapshots are made and restored while stopped.
private struct StopFirstBar: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    var body: some View {
        HStack {
            Label("スナップショットの作成・復元・削除は、仮想マシンを停止してから行えます。", systemImage: "info.circle")
            Spacer()
            Button("停止") { model.stop(instance.name) }
                .disabled(model.isBusy(instance.name))
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.yellow.opacity(0.12))
    }
}

/// HanaLima's snapshots of a VZ VM (see DiskSnapshot).
private struct DiskSnapshotContent: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    @State private var selection: DiskSnapshot.ID?
    @State private var isCreating = false
    @State private var restoring: DiskSnapshot?
    @State private var deleting: DiskSnapshot?

    private var list: [DiskSnapshot] { model.diskSnapshots[instance.name] ?? [] }
    private var selected: DiskSnapshot? { list.first { $0.id == selection } }
    private var busy: Bool { model.isBusy(instance.name) }
    private var shared: Bool { model.sharedDiskOwners[instance.name] != nil }
    private var canOperate: Bool { !instance.isRunning && !busy && !shared }

    var body: some View {
        if case .missing = model.diskPlacement(of: instance) {
            ContentUnavailableView("ディスクのある外付けドライブが接続されていません", systemImage: "externaldrive.badge.xmark",
                                   description: Text("スナップショットはディスクと同じドライブにあります。ドライブを接続すると表示します。"))
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            if instance.isRunning {
                StopFirstBar(instance: instance)
                Divider()
            }
            Table(list, selection: $selection) {
                TableColumn("名前") { Text($0.name).fontWeight(.medium) }
                TableColumn("作成日時") { s in
                    Text(s.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                }
            }
            .contextMenu(forSelectionType: DiskSnapshot.ID.self) { ids in
                if let s = list.first(where: { ids.contains($0.id) }) {
                    Button("この状態に戻す…") { restoring = s }.disabled(!canOperate)
                    Button("この状態から新しい仮想マシン…") { copyFrom(s) }
                        .disabled(model.copyBlocker(instance.name) != nil || shared)
                    Divider()
                    Button("削除…", role: .destructive) { deleting = s }.disabled(!canOperate)
                }
            }
            .overlay {
                if list.isEmpty {
                    ContentUnavailableView("スナップショットはありません", systemImage: "camera.on.rectangle",
                                           description: Text("停止中に「作成」を押すと、今の状態を保存します。あとで、いつでもこの仮想マシンをその状態に戻せます。"))
                }
            }
            Divider()
            HStack(alignment: .center) {
                Text("起動ディスクと EFI の状態を APFS のクローンで保存します（すぐに終わり、容量はその後に変わった分だけ使います）。設定と追加ディスクは含みません。別の仮想マシンとして並べて使うなら「複製」を使います。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("戻す…") { restoring = selected }
                    .disabled(selected == nil || !canOperate)
                Button("新しい仮想マシン…") { selected.map(copyFrom) }
                    .disabled(selected == nil || model.copyBlocker(instance.name) != nil || shared)
                    .help("このスナップショットの状態から、新しい仮想マシンを作ります。")
                Button("削除…") { deleting = selected }
                    .disabled(selected == nil || !canOperate)
                Button("作成…") { isCreating = true }
                    .disabled(!canOperate)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(12)
        }
        .task(id: "\(instance.name)-\(instance.status.label)-\(busy)-\(model.diskPlacement(of: instance).externalURL?.path ?? "")") {
            if !busy { model.loadDiskSnapshots(instance.name) }
        }
        .sheet(isPresented: $isCreating) { CreateDiskSnapshotSheet(name: instance.name) }
        .confirmationDialog("「\(restoring?.name ?? "")」の状態に戻しますか？",
                            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("戻す", role: .destructive) {
                if let s = restoring { model.restoreDiskSnapshot(instance.name, s) }
            }
        } message: {
            Text("起動ディスクが、このスナップショットを作成した時点の内容に戻ります。それ以降の変更は失われます（残したいなら、先にスナップショットを作成してください）。スナップショット自体は残ります。")
        }
        .confirmationDialog("スナップショット「\(deleting?.name ?? "")」を削除しますか？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("削除", role: .destructive) {
                if let s = deleting { model.deleteDiskSnapshot(instance.name, s) }
            }
        } message: {
            Text("この操作は取り消せません。")
        }
    }

    private func copyFrom(_ s: DiskSnapshot) {
        model.copyRequest = CopyRequest(source: instance.name, snapshot: .disk(s))
    }
}

private struct CreateDiskSnapshotSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let name: String
    @State private var title = DiskSnapshot.suggestedName()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("名前", text: $title, prompt: Text("例: アップデート前"))
                Text("「\(name)」の起動ディスクの今の状態を保存します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    model.createDiskSnapshot(name, title: title.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 440)
    }
}
