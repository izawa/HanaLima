import AppKit
import LimaKit
import SwiftUI

/// Logs of one instance: the last limactl command, `limactl watch` events, and the files in the
/// instance directory (host agent log, serial console), followed live.
struct LogTab: View {
    @Environment(AppModel.self) private var model
    let name: String

    private enum Source: String, CaseIterable, Identifiable {
        case operation = "コマンド出力"
        case events = "イベント"
        case hostAgent = "ホストエージェント"
        case serial = "シリアルコンソール"
        var id: String { rawValue }
    }

    @State private var source: Source = Self.initialSource

    private static var initialSource: Source {
        #if DEBUG
        if let raw = DebugSnapshot.env["HANALIMA_SNAPSHOT_LOG"], let s = Source(rawValue: raw) { return s }
        #endif
        return .operation
    }
    @State private var query = ""
    @State private var showDebug = false
    @State private var serialFile = ""
    @State private var followed = FollowedLog()

    private var instance: LimaInstance? { model.instance(named: name) }
    private var instanceDir: URL? { instance.map { URL(fileURLWithPath: $0.dir) } }

    /// serialv.log (VZ), serial.log and serialp.log (QEMU): whichever exist.
    private var serialFiles: [String] {
        guard let dir = instanceDir else { return [] }
        // The main console first: virtio for VZ, the first serial port for QEMU.
        let order = instance?.vmType?.lowercased() == "qemu"
            ? ["serial.log", "serialp.log", "serialv.log"] : ["serialv.log", "serial.log", "serialp.log"]
        return order.filter {
            FileManager.default.fileExists(atPath: dir.appending(path: $0).path)
        }
    }

    private var fileURL: URL? {
        guard let dir = instanceDir else { return nil }
        switch source {
        case .hostAgent: return dir.appending(path: "ha.stderr.log")
        case .serial:
            let file = serialFiles.contains(serialFile) ? serialFile : serialFiles.first
            return file.map { dir.appending(path: $0) }
        case .operation, .events: return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            LogLinesView(lines: filtered(lines), emptyText: emptyText, showsDate: source != .serial)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Keep the controls at the top when the list is empty (the empty-state view doesn't stretch).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: fileURL) {
            guard let fileURL else { return }
            await followed.follow(fileURL, parse: source == .hostAgent ? Self.hostAgentLine : Self.serialLine)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            if source == .hostAgent {
                Toggle("デバッグ", isOn: $showDebug)
                    .toggleStyle(.checkbox)
                    .help("debug レベルのメッセージも表示します")
            }
            if source == .serial, serialFiles.count > 1 {
                Picker("", selection: Binding(get: { serialFiles.contains(serialFile) ? serialFile : serialFiles[0] },
                                              set: { serialFile = $0 })) {
                    ForEach(serialFiles, id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
            }
            Spacer()
            TextField("検索", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
            if let fileURL {
                Menu {
                    Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
                    Button("コンソールで開く") {
                        NSWorkspace.shared.open([fileURL],
                                                withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"),
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(fileURL.path)
            } else if source == .operation, let op = model.operations[name] {
                Text("最後のコマンド: \(op.kind.label)\(op.isRunning ? "（実行中）" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var lines: [LogLine] {
        switch source {
        case .operation:
            (model.operations[name]?.log ?? []).map {
                LogLine(id: $0.id, date: $0.date, text: $0.displayText, color: $0.level.color, level: $0.level)
            }
        case .events:
            (model.events[name] ?? []).map {
                LogLine(id: $0.id, date: $0.date, text: $0.text, color: $0.isError ? .red : .primary)
            }
        case .hostAgent:
            followed.lines.filter { showDebug || ($0.level ?? .info) > .debug }
        case .serial:
            followed.lines
        }
    }

    private func filtered(_ lines: [LogLine]) -> [LogLine] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    private var emptyText: String {
        if !query.isEmpty { return "「\(query)」を含む行はありません。" }
        switch source {
        case .operation: return "このセッションで実行したコマンドはまだありません。"
        case .events: return "イベントはまだありません。"
        case .hostAgent: return "ホストエージェントのログはまだありません。"
        case .serial:
            guard let file = fileURL?.lastPathComponent else { return "シリアルコンソールのログはありません。" }
            return "\(file) は空です。ゲストによっては、このコンソールに何も出力しません。"
        }
    }

    private static func hostAgentLine(_ raw: String) -> LogLine {
        let e = LogEntry.parse(raw)
        return LogLine(id: e.id, date: e.date, text: e.displayText, color: e.level.color, level: e.level)
    }

    private static func serialLine(_ raw: String) -> LogLine {
        LogLine(id: UUID(), date: nil, text: LogFileFollower.stripANSI(raw), color: .primary)
    }
}

/// Lines of a followed log file, refreshed once a second while the view is visible.
@MainActor
@Observable
final class FollowedLog {
    private(set) var lines: [LogLine] = []
    private static let maxLines = 5000

    func follow(_ url: URL, parse: (String) -> LogLine) async {
        let follower = LogFileFollower(url: url)
        lines = []
        while !Task.isCancelled {
            if let chunk = follower.readNewLines() {
                if chunk.reset { lines = [] }
                if !chunk.lines.isEmpty {
                    lines.append(contentsOf: chunk.lines.map(parse))
                    if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

struct LogLine: Identifiable {
    let id: UUID
    /// nil for raw console output, which has no timestamps.
    let date: Date?
    let text: String
    let color: Color
    var level: LogEntry.Level?
}

/// Auto-scrolling monospaced log.
struct LogLinesView: View {
    let lines: [LogLine]
    let emptyText: String
    var showsDate = true

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(emptyText, systemImage: "text.alignleft")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if showsDate, let date = line.date {
                                    Text(date, format: .dateTime.hour().minute().second())
                                        .foregroundStyle(.secondary)
                                }
                                Text(line.text)
                                    .foregroundStyle(line.color)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(12)
                }
                .onAppear { proxy.scrollTo(lines.last?.id, anchor: .bottom) }
                .onChange(of: lines.last?.id) { _, id in
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}
