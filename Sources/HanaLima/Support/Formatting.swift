import LimaKit
import SwiftUI

enum Formatting {
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }

    /// A rough time left: seconds under a minute (by 5), minutes under an hour, then hours and minutes.
    static func remaining(_ seconds: Double) -> String {
        let style = Duration.UnitsFormatStyle(allowedUnits: [.hours, .minutes, .seconds], width: .abbreviated,
                                              maximumUnitCount: 2)
        let rounded: Double = switch seconds {
        case ..<60: max(5, (seconds / 5).rounded(.up) * 5)
        case ..<3600: (seconds / 60).rounded(.up) * 60
        default: (seconds / 300).rounded(.up) * 300
        }
        return Duration.seconds(rounded).formatted(style)
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
