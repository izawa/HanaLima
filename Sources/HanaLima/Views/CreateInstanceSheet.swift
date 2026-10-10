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
                    model.create(options, startAfterCreate: startAfterCreate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameError != nil)
            }
            .padding()
        }
        .frame(width: 560, height: 680)
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
            setExpressions: virtualNetworkExpression)
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
