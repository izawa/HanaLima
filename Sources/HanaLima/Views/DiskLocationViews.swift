import AppKit
import LimaKit
import SwiftUI

/// Remembered across sheets, so the external drive is preselected the next time.
enum DiskLocationSettings {
    static let lastFolder = "lastExternalDiskFolder"
    /// Folders holding moved disks (`HanaLima Disks`), searched for leftovers of deleted VMs.
    static let knownFolders = "knownExternalDiskFolders"

    static var knownDiskFolders: [URL] {
        var paths = UserDefaults.standard.stringArray(forKey: knownFolders) ?? []
        if let last = UserDefaults.standard.string(forKey: lastFolder) {
            // Where the next disk would go: <last>/HanaLima Disks, or <last> itself.
            paths.append(ExternalDisk.target(in: URL(filePath: last, directoryHint: .isDirectory), name: "_")
                .deletingLastPathComponent().deletingLastPathComponent().path)
        }
        return Array(Set(paths)).sorted().map { URL(filePath: $0, directoryHint: .isDirectory) }
    }

    /// Remembers the folder holding `disk` (`…/HanaLima Disks/<name>/disk`).
    static func remember(disk: URL) {
        let base = disk.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: knownFolders) ?? []
        guard !paths.contains(base) else { return }
        paths.append(base)
        UserDefaults.standard.set(paths, forKey: knownFolders)
    }
}

/// "Disk location" in the Settings tab: where the disk is, and moving it out or back.
struct DiskLocationSection: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance
    @State private var showMove = false
    @State private var confirmBack = false

    var body: some View {
        let placement = model.diskPlacement(of: instance)
        let hasSnapshots = instance.vmType?.lowercased() != "qemu" && model.hasDiskSnapshots(instance)
        let locked = instance.status != .stopped || model.isBusy(instance.name) || hasSnapshots
        Section {
            LabeledContent("保存場所") {
                switch placement {
                case .local:
                    Text("この Mac（内蔵ディスク）")
                case .external(let url):
                    Button(DiskLocationText.describe(url)) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.link)
                    .help(url.path)
                case .missing(let url):
                    Text("見つかりません（\(url.deletingLastPathComponent().path)）").foregroundStyle(.red)
                }
            }
            if let owner = model.sharedDiskOwners[instance.name] {
                Label("「\(owner)」のディスクと同じファイルを指しています。", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            if case .missing = placement {} else {
                LabeledContent("使用量") {
                    Text(Formatting.bytes(model.diskAllocatedSize(of: instance))).monospacedDigit()
                }
            }
            HStack {
                if hasSnapshots {
                    Text("スナップショットがあるあいだは移動できません（スナップショットはディスクと同じドライブに置くため）。").font(.caption).foregroundStyle(.secondary)
                } else if locked {
                    Text("仮想マシンを停止すると移動できます。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                switch placement {
                case .local:
                    Button("外付けドライブなどへ移動…") { showMove = true }.disabled(locked)
                case .external:
                    if model.sharedDiskOwners[instance.name] != nil {
                        Button("ディスクを独立させる") { model.separateDisk(instance.name) }.disabled(locked)
                    }
                    Button("この Mac に戻す…") { confirmBack = true }.disabled(locked)
                case .missing:
                    EmptyView()
                }
            }
        } header: {
            Text("ディスクの保存場所")
        } footer: {
            Group {
                switch placement {
                case .local:
                    Text("一時的に使う仮想マシンなら、ディスク（いちばん大きなファイル）を外付けドライブに置いて、Mac の空き容量を節約できます。移動したあとも、これまでどおり起動・編集できます。")
                case .external where model.sharedDiskOwners[instance.name] != nil:
                    Text("「ディスクを独立させる」は、同じドライブの上に APFS のクローン（書き込むまで中身を共有するコピー）を作るので、すぐに終わり、容量もほとんど使いません。「この Mac に戻す」でも、この仮想マシン専用のディスクになります。")
                case .external:
                    Text("ディスクは外付けドライブなどにあります。そのドライブを外しているあいだは起動できません。仮想マシンを削除すると、このディスクも削除します。")
                case .missing:
                    Text("ディスクのあるドライブが接続されていません。接続すると、そのまま使えます。")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showMove) { MoveDiskSheet(instance: instance) }
        #if DEBUG
        .task { if DebugSnapshot.env["HANALIMA_SNAPSHOT_MOVEDISK"] != nil { showMove = true } }
        #endif
        .confirmationDialog("ディスクをこの Mac に戻しますか？", isPresented: $confirmBack) {
            Button("戻す") { model.moveDiskBack(instance.name) }
                .disabled(!backFits)
        } message: {
            Text(backMessage)
        }
    }

    private var internalAvailable: Int64 {
        let values = try? URL(filePath: instance.dir).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return ExternalDisk.availableSpace(values)
    }

    private var backFits: Bool { internalAvailable > model.diskAllocatedSize(of: instance) + 1 << 30 }

    private var backMessage: String {
        let size = Formatting.bytes(model.diskAllocatedSize(of: instance))
        let free = Formatting.bytes(internalAvailable)
        if backFits, let owner = model.sharedDiskOwners[instance.name] {
            return String(localized: "ディスク（\(size)）を Mac の内蔵ディスクにコピーします。外付けドライブ上のディスクは「\(owner)」のものなので残します。内蔵の空き: \(free)。")
        }
        return backFits
            ? String(localized: "ディスク（\(size)）を Mac の内蔵ディスクにコピーし、終わったら外付けドライブ上のディスクを削除します。内蔵の空き: \(free)。")
            : String(localized: "内蔵ディスクの空きが足りません（必要 \(size)、空き \(free)）。")
    }
}

enum DiskLocationText {
    /// "HDD › HanaLima Disks/ubuntu-test" for a moved disk.
    static func describe(_ disk: URL) -> String {
        let folder = disk.deletingLastPathComponent()
        return describe(folder: folder, relative: folder.pathComponents.suffix(2).joined(separator: "/"))
    }

    /// "HDD › Lima" for a chosen folder (the path inside its volume); the name alone for the root.
    static func describe(folder: URL, relative: String? = nil) -> String {
        let values = try? folder.resourceValues(forKeys: [.volumeNameKey, .volumeURLKey])
        guard let volume = values?.volumeName else { return folder.path }
        var rest = relative ?? ""
        if relative == nil, let root = values?.volume?.standardizedFileURL.pathComponents {
            let parts = folder.standardizedFileURL.pathComponents
            if parts.starts(with: root) { rest = parts.dropFirst(root.count).joined(separator: "/") }
        }
        return rest.isEmpty ? volume : "\(volume) › \(rest)"
    }

    static func problem(_ problem: ExternalDisk.DestinationCheck.Problem, check: ExternalDisk.DestinationCheck,
                        nominal: Int64?) -> String {
        switch problem {
        case .sameVolume:
            String(localized: "Mac の内蔵ディスクと同じディスクです。移しても空き容量は増えません。外付けドライブなど、別のディスクを選んでください。")
        case .notAPFS(let fs):
            String(localized: "「\(check.volumeName)」は \(fs.isEmpty ? "APFS 以外" : fs) です。APFS でないと、ディスクが名目のサイズ（\(Formatting.bytes(nominal))）を丸ごと使ってしまいます。APFS でフォーマットしたドライブを選んでください。")
        case .notEnoughSpace:
            String(localized: "空き容量が足りません（必要 \(Formatting.bytes(check.required))、空き \(Formatting.bytes(check.available))）。")
        case .alreadyExists:
            String(localized: "選んだ場所に「\(ExternalDisk.folderName)/…」の同じ名前のフォルダが既にあります。別の場所を選ぶか、そのフォルダを片付けてください。")
        case .notWritable:
            String(localized: "この場所には書き込めません。")
        }
    }
}

/// Choose a folder on another drive, with the check result right below it.
struct ExternalFolderPicker: View {
    @Binding var folder: URL?
    let check: ExternalDisk.DestinationCheck?
    var nominalSize: Int64?

    var body: some View {
        LabeledContent("移動先") {
            HStack {
                Text(folder.map { DiskLocationText.describe(folder: $0) } ?? String(localized: "未選択"))
                    .foregroundStyle(folder == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(folder?.path ?? "")
                Button("選択…") { choose() }
            }
        }
        if let check {
            if check.isOK {
                Label("「\(check.volumeName)」（\(check.fileSystem.uppercased())）・空き \(Formatting.bytes(check.available))。保存先: \(destinationText(check))",
                      systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .help(check.target.deletingLastPathComponent().path)
            } else {
                ForEach(Array(check.problems.enumerated()), id: \.offset) { _, problem in
                    Label(DiskLocationText.problem(problem, check: check, nominal: nominalSize),
                          systemImage: "xmark.octagon.fill")
                        .font(.callout).foregroundStyle(.red)
                }
            }
        }
    }

    /// The target doesn't exist yet, so describe it from the chosen folder.
    private func destinationText(_ check: ExternalDisk.DestinationCheck) -> String {
        let inside = check.target.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/")
        return folder.map { "\(DiskLocationText.describe(folder: $0)) › \(inside)" } ?? check.target.path
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "選択")
        panel.message = String(localized: "ディスクを置く場所（外付けドライブなど）を選んでください。中に「\(ExternalDisk.folderName)」フォルダを作ります。")
        panel.directoryURL = folder ?? URL(filePath: "/Volumes")
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
            UserDefaults.standard.set(url.path, forKey: DiskLocationSettings.lastFolder)
        }
    }

    /// The last folder chosen, if its drive is connected.
    static var lastFolder: URL? {
        guard let path = UserDefaults.standard.string(forKey: DiskLocationSettings.lastFolder),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(filePath: path, directoryHint: .isDirectory)
    }
}

/// Moving an existing VM's disk out: pick a place, see whether it works, read the trade-offs.
struct MoveDiskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let instance: LimaInstance
    @State private var folder: URL? = Self.initialFolder

    private static var initialFolder: URL? {
        #if DEBUG
        if let path = DebugSnapshot.env["HANALIMA_SNAPSHOT_MOVEDISK"], !path.isEmpty { return URL(filePath: path) }
        #endif
        return ExternalFolderPicker.lastFolder
    }

    private var check: ExternalDisk.DestinationCheck? {
        folder.map {
            ExternalDisk.check(folder: $0, instanceDir: URL(filePath: instance.dir), name: instance.name,
                               required: model.diskAllocatedSize(of: instance))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("「\(instance.name)」のディスクを移動").font(.headline)
                    Text("仮想マシンのディスク（いちばん大きなファイル、今 \(Formatting.bytes(model.diskAllocatedSize(of: instance)))）だけを、選んだ場所へ移します。設定やログは ~/.lima に残り、移したあとも、これまでどおり起動・編集できます。")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    ExternalFolderPicker(folder: $folder, check: check, nominalSize: instance.disk)
                }
                Section("移す前に") {
                    Label("そのドライブを外しているあいだは、この仮想マシンは起動できません。", systemImage: "externaldrive")
                    Label("仮想マシンを削除すると、移動先のディスクも一緒に削除します。", systemImage: "trash")
                    Label("あとから「この Mac に戻す」で、いつでも内蔵ディスクに戻せます。", systemImage: "arrow.uturn.backward")
                    if model.autostartInstances.contains(instance.name) {
                        Label("この仮想マシンは、ログイン時に自動で起動する設定です。ログインの時点でドライブが接続されていないと、起動に失敗します。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("移動") {
                    if let folder { model.moveDisk(instance.name, to: folder) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(check?.isOK != true)
            }
            .padding()
        }
        .frame(width: 580, height: 540)
    }
}
