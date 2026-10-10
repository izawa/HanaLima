import LimaKit
import SwiftUI

/// Output of the last limactl command plus events from `limactl watch`.
struct LogTab: View {
    @Environment(AppModel.self) private var model
    let name: String

    private enum Source: String, CaseIterable, Identifiable {
        case operation = "コマンド出力"
        case events = "イベント"
        var id: String { rawValue }
    }

    @State private var source: Source = .operation

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $source) {
                    ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Spacer()
                if let op = model.operations[name] {
                    Text("最後のコマンド: \(op.kind.label)\(op.isRunning ? "（実行中）" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch source {
            case .operation:
                LogLinesView(lines: (model.operations[name]?.log ?? []).map {
                    LogLine(id: $0.id, date: $0.date, text: $0.displayText, color: $0.level.color)
                }, emptyText: "このセッションで実行したコマンドはまだありません。")
            case .events:
                LogLinesView(lines: (model.events[name] ?? []).map {
                    LogLine(id: $0.id, date: $0.date, text: $0.text, color: $0.isError ? .red : .primary)
                }, emptyText: "イベントはまだありません。")
            }
        }
    }
}

struct LogLine: Identifiable {
    let id: UUID
    let date: Date
    let text: String
    let color: Color
}

/// Auto-scrolling monospaced log.
struct LogLinesView: View {
    let lines: [LogLine]
    let emptyText: String

    var body: some View {
        if lines.isEmpty {
            ContentUnavailableView(emptyText, systemImage: "text.alignleft")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(lines) { line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(line.date, format: .dateTime.hour().minute().second())
                                    .foregroundStyle(.secondary)
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
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}
