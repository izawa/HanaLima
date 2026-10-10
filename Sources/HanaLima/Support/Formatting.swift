import LimaKit
import SwiftUI

enum Formatting {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
}

extension InstanceStatus {
    var label: String {
        switch self {
        case .running: String(localized: "実行中")
        case .stopped: String(localized: "vm-status.stopped", defaultValue: "停止")  // "停止" alone is the Stop button
        case .broken: String(localized: "異常")
        case .installing: String(localized: "インストール中")
        case .uninitialized: String(localized: "未初期化")
        case .unknown(let s): s.isEmpty ? String(localized: "不明") : s
        }
    }

    var color: Color {
        switch self {
        case .running: .green
        case .stopped: .secondary
        case .broken: .red
        case .installing, .uninitialized: .orange
        case .unknown: .gray
        }
    }
}

extension LogEntry.Level {
    var color: Color {
        switch self {
        case .trace, .debug: .secondary
        case .info: .primary
        case .warning: .orange
        case .error, .fatal, .panic: .red
        }
    }
}

/// Small colored dot used for instance status.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
}
