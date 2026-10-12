import LimaKit
import NetworkKit
import SwiftUI

struct CreateInstanceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var template = "default"
    @State private var vmType: CreateOptions.VMType = .vz
    @State private var cpus = min(4, HostInfo.cpuCount)
    @State private var memoryGiB = min(4, HostInfo.memoryGiB)
    @State private var diskGiB = 100
    @State private var extraNIC: ExtraNIC = .none

    /// The optional second NIC offered at creation time (more can be added in Settings).
    private enum ExtraNIC: Hashable {
        case none
        case vzNAT
        case virtual(String)
    }
    @State private var rosetta = false
    @State private var startAfterCreate = true
    @State private var shareHome = true
    @State private var workFolder: URL?
    @State private var workFolderWritable = true
    @State private var diskOnOtherDrive = false
    @State private var diskFolder: URL? = ExternalFolderPicker.lastFolder

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("基本") {
                    TextField("名前", text: $name, prompt: Text(suggestedName))
                    if let nameError {
                        Text(nameError).font(.caption).foregroundStyle(.red)
                    }
                    Picker("テンプレート", selection: $template) {
                        if templateGroups.isEmpty {
                            Text("標準").tag("default")
                        }
                        ForEach(templateGroups) { group in
                            Section(group.title) {
                                ForEach(group.templates) { Text($0.displayName).tag($0.name) }
                            }
                        }
                    }
                    LabeledContent("Lima のテンプレート") {
                        Text(verbatim: "template:\(template)").monospaced().textSelection(.enabled)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Picker("仮想化方式", selection: $vmType) {
                        Text("VZ (Virtualization.framework)").tag(CreateOptions.VMType.vz)
                        Text("QEMU").tag(CreateOptions.VMType.qemu)
                    }
                }

                Section("ハードウェア") {
                    Stepper(value: $cpus, in: 1...HostInfo.cpuCount) {
                        LabeledContent("仮想 CPU") { Text("\(cpus) コア") }
                    }
                    Stepper(value: $memoryGiB, in: 1...HostInfo.memoryGiB) {
                        LabeledContent("メモリ", value: "\(memoryGiB) GiB")
                    }
                    if memoryGiB > HostInfo.memoryGiB / 2 {
                        Text("ホストの物理メモリ (\(HostInfo.memoryGiB) GiB) の半分を超えています。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Stepper(value: $diskGiB, in: 10...4096, step: 10) {
                        LabeledContent("ディスク", value: "\(diskGiB) GiB")
                    }
                    Text("ディスクはスパースファイルなので、実際に使用した分だけホストの容量を消費します。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("ネットワーク") {
                    LabeledContent("NIC 0") { Text("ユーザーモード NAT（常に有効）") }
                    Picker("NIC 1", selection: $extraNIC) {
                        Text("なし").tag(ExtraNIC.none)
                        ForEach(model.virtualNetworks) { n in
                            Text(n.menuDescription)
                                .tag(ExtraNIC.virtual(n.name))
                        }
                        if vmType == .vz {
                            Text("vzNAT（NAT・サブネット指定不可）").tag(ExtraNIC.vzNAT)
                        }
                    }
                    Text(model.virtualNetworks.isEmpty
                         ? "サイドバーの「仮想ネットワーク」でネットワークを作ると、ここで選べるようになります。"
                         : "ホストや他の VM から到達できる IP アドレスが割り当てられます。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Picker("保存場所", selection: $diskOnOtherDrive) {
                        Text("この Mac").tag(false)
                        Text("外付けドライブなど").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if diskOnOtherDrive {
                        ExternalFolderPicker(folder: $diskFolder, check: diskCheck)
                    }
                } header: {
                    Text("ディスク")
                } footer: {
                    Text(diskOnOtherDrive
                         ? "作成したあと、最初の起動の前にディスクを移します（作成の途中は、いったん Mac の中に作ります）。ドライブを外しているあいだは起動できません。"
                         : "一時的に使う仮想マシンなら、ディスクを外付けドライブに置いて Mac の空き容量を節約できます。あとから「設定」タブで移すこともできます。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Toggle("ホームフォルダを共有（読み取り専用）", isOn: $shareHome)
                    if !shareHome {
                        LabeledContent("作業フォルダ") {
                            HStack {
                                Text(workFolder.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
                                     ?? String(localized: "なし"))
                                    .foregroundStyle(workFolder == nil ? .secondary : .primary)
                                    .lineLimit(1).truncationMode(.middle)
                                    .help(workFolder?.path ?? "")
                                if workFolder != nil {
                                    Button("外す") { workFolder = nil }
                                }
                                Button("選択…") { chooseWorkFolder() }
                            }
                        }
                        if workFolder != nil {
                            Toggle("仮想マシンからの書き込みを許可", isOn: $workFolderWritable)
                        }
                        if let workFolderError {
                            Text(workFolderError).font(.caption).foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Mac との共有")
                } footer: {
                    Text(shareHome
                         ? "仮想マシンから Mac のホームフォルダ（~/.ssh などの認証情報を含む）を読めます。AI のエージェントなど、信頼しきれないものを動かすならオフにしてください。"
                         : workFolder == nil
                         ? "Mac のファイルは仮想マシンから見えません。作業フォルダを選ぶと、そのフォルダだけを共有します（あとから「設定」タブの共有フォルダでも追加できます）。"
                         : "仮想マシンから見えるのは作業フォルダだけで、仮想マシンの中でも同じパスにあります。ホームフォルダのほかの場所は見えません。")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("オプション") {
                    if HostInfo.isAppleSilicon {
                        Toggle("Rosetta で x86_64 バイナリを実行", isOn: $rosetta)
                            .disabled(vmType != .vz)
                    }
                    Toggle("作成後すぐに起動", isOn: $startAfterCreate)
                }

                Section("実行されるコマンド") {
                    Text(commandPreview)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("作成") {
                    model.create(options, startAfterCreate: startAfterCreate,
                                 diskFolder: diskOnOtherDrive ? diskFolder : nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameError != nil || !diskPlaceOK || (!shareHome && workFolderError != nil))
            }
            .padding()
        }
        .frame(width: 560, height: 720)
        .onChange(of: vmType) { _, new in
            if new != .vz {
                if extraNIC == .vzNAT { extraNIC = .none }
                rosetta = false
            }
        }
    }

    // MARK: -

    private var effectiveName: String { name.isEmpty ? suggestedName : name }

    /// Template name minus any directory prefix, de-duplicated against existing instances.
    private var suggestedName: String {
        let base = template == "default" ? "default" : (template.split(separator: "/").last.map(String.init) ?? template)
        let taken = Set(model.sidebarNames)
        if !taken.contains(base) { return base }
        var i = 2
        while taken.contains("\(base)-\(i)") { i += 1 }
        return "\(base)-\(i)"
    }

    private var nameError: String? {
        let n = effectiveName
        if !CreateOptions.isValidName(n) {
            return String(localized: "英数字と . _ - が使えます（記号は連続不可、先頭と末尾は英数字）。")
        }
        if model.sidebarNames.contains(n) { return String(localized: "「\(n)」は既に存在します。") }
        return nil
    }

    private var templateGroups: [TemplateGroup] { TemplateCatalog.groups(model.templates) }

    /// The disk doesn't exist yet, so only the place is checked (volume, format, folder name).
    private var diskCheck: ExternalDisk.DestinationCheck? {
        diskFolder.map {
            ExternalDisk.check(folder: $0, instanceDir: LimaNetworks.limaHome.appending(path: effectiveName),
                               name: effectiveName, required: 0)
        }
    }

    private var diskPlaceOK: Bool { !diskOnOtherDrive || diskCheck?.isOK == true }

    private var options: CreateOptions {
        CreateOptions(
            name: effectiveName,
            template: template,
            cpus: cpus,
            memoryGiB: Double(memoryGiB),
            diskGiB: Double(diskGiB),
            vmType: vmType,
            networks: extraNIC == .vzNAT ? ["vzNAT"] : [],
            rosetta: rosetta,
            mountNone: !shareHome,
            mountOnly: shareHome ? [] : workFolderMount,
            setExpressions: virtualNetworkExpression)
    }

    /// The work folder as a `--mount-only` value: `<path>` or `<path>:w`.
    private var workFolderMount: [String] {
        guard let workFolder, workFolderError == nil else { return [] }
        return [workFolder.path + (workFolderWritable ? ":w" : "")]
    }

    /// Lima reads `<path>:w`, so a colon in the path can't be passed this way.
    private var workFolderError: String? {
        guard let workFolder, workFolder.path.contains(":") else { return nil }
        return String(localized: "パスに「:」を含むフォルダは選べません。")
    }

    private func chooseWorkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "選択")
        panel.message = String(localized: "仮想マシンと共有するフォルダを選んでください。仮想マシンから見えるのは、このフォルダだけになります。")
        panel.directoryURL = workFolder ?? URL(filePath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url { workFolder = url }
    }

    private var virtualNetworkExpression: [String] {
        guard case .virtual(let name) = extraNIC,
              let net = model.virtualNetworks.first(where: { $0.name == name }) else { return [] }
        let entry = JSONValue.object(["socket": .string(net.socketPath)])
        return [".networks += [\(entry.jsonText)]"]
    }

    private var commandPreview: String {
        (["limactl"] + options.arguments).joined(separator: " ")
    }
}

enum HostInfo {
    static let cpuCount = ProcessInfo.processInfo.activeProcessorCount
    static let memoryGiB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
    static let isAppleSilicon: Bool = {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }()
}
