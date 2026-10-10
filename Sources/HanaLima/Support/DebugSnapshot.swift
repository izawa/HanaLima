#if DEBUG
import AppKit
import LimaKit

/// Development aid: with `HANALIMA_SNAPSHOT=/path/prefix`, the app renders each visible window
/// to `<prefix>-<n>.png` after a delay and quits. Works without screen-recording permission
/// because it draws in-process.
///
/// Optional: `HANALIMA_SNAPSHOT_DELAY` (seconds, default 4), `HANALIMA_SNAPSHOT_CREATE=1`
/// (open the create sheet first), `HANALIMA_SNAPSHOT_TAB=<tab name>` (select a detail tab),
/// `HANALIMA_SNAPSHOT_SELECT=disks|storage|networks|<instance>` (sidebar selection),
/// `HANALIMA_SNAPSHOT_ABOUT=1` (open the About panel),
/// `HANALIMA_SNAPSHOT_START=<instance>` (press Start; only use when a confirmation will stop it),
/// `HANALIMA_SNAPSHOT_DOWNLOAD=<instance>` (show a made-up download in progress for it).
@MainActor
enum DebugSnapshot {
    static var env: [String: String] { ProcessInfo.processInfo.environment }
    static var requestedTab: String? { env["HANALIMA_SNAPSHOT_TAB"] }
    /// `HANALIMA_SNAPSHOT_SELECT=disks` or `=<instance name>`.
    static var requestedSelection: SidebarItem? {
        guard let s = env["HANALIMA_SNAPSHOT_SELECT"] else { return nil }
        switch s {
        case "disks": return .disks
        case "storage": return .storage
        case "networks": return .networks
        default: return .instance(s)
        }
    }

    static func scheduleIfRequested() {
        guard let prefix = env["HANALIMA_SNAPSHOT"] else { return }
        let delay = Double(env["HANALIMA_SNAPSHOT_DELAY"] ?? "") ?? 4
        if env["HANALIMA_SNAPSHOT_ABOUT"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay / 2) { NSApp.orderFrontStandardAboutPanel(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            capture(prefix: prefix)
            // Not NSApp.terminate: an open sheet blocks it.
            ProcessRunner.terminateBackgroundProcesses()
            exit(0)
        }
    }

    private static func capture(prefix: String) {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil }
        if env["HANALIMA_SNAPSHOT_DUMP"] == "1" {
            for w in NSApp.windows {
                print("window \(type(of: w)) title=\(w.title) visible=\(w.isVisible) frame=\(w.frame)")
            }
            for w in windows { dumpTables(w.contentView?.superview) }
        }
        for (i, window) in windows.enumerated() {
            // Render the frame view so the titlebar/toolbar are included.
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
            }
        }
    }

    /// Prints table/outline views and their visible text, to tell rendering artifacts from real bugs.
    private static func dumpTables(_ view: NSView?) {
        guard let view else { return }
        if let table = view as? NSTableView {
            print("table rows=\(table.numberOfRows) frame=\(table.frame) visible=\(table.visibleRect)")
        }
        if let text = view as? NSTextField, !text.stringValue.isEmpty {
            print("  text: \(text.stringValue)")
        }
        view.subviews.forEach(dumpTables)
    }
}
#endif
