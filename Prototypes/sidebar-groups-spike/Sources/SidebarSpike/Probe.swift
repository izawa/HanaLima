import AppKit
import SwiftUI

/// SPIKE_PROBE=<dir>: drives the window with synthetic events posted to this app's own queue
/// (no accessibility permission needed), logging the model and saving a PNG after each step.
@MainActor
enum Probe {
    static var dir: String? { ProcessInfo.processInfo.environment["SPIKE_PROBE"] }

    static func startIfRequested(_ store: Store) {
        guard dir != nil else { return }
        Task {
            if ProcessInfo.processInfo.environment["SPIKE_PROBE_SET"] == "2" { await run2(store) } else if ProcessInfo.processInfo.environment["SPIKE_PROBE_SET"] == "3" { await run3(store) } else if ProcessInfo.processInfo.environment["SPIKE_PROBE_SET"] == "4" { await run4(store) } else if ProcessInfo.processInfo.environment["SPIKE_PROBE_SET"] == "5" { await run5(store) } else { await run(store) }
        }
    }

    static var window: NSWindow { NSApp.windows.first { $0.isVisible && $0.contentView != nil }! }

    static func findTable(_ v: NSView?) -> NSTableView? {
        guard let v else { return nil }
        if let t = v as? NSTableView { return t }
        for s in v.subviews { if let t = findTable(s) { return t } }
        return nil
    }

    static func classes(_ v: NSView, depth: Int = 0, into out: inout [String]) {
        guard depth < 14 else { return }
        out.append(String(repeating: " ", count: depth) + String(describing: type(of: v)))
        for s in v.subviews { classes(s, depth: depth + 1, into: &out) }
    }

    static var table: NSTableView { findTable(window.contentView)! }

    static func rowIndex(_ key: String, _ store: Store) -> Int? { store.flattened.firstIndex(of: key) }

    /// Window coordinates of a point in a row: x as a fraction of the row width, or an absolute x.
    static func point(row: Int, x: CGFloat) -> NSPoint {
        let t = table
        var r = t.rect(ofRow: row)
        r.origin.x = x
        let mid = NSPoint(x: r.origin.x, y: r.midY)
        return t.convert(mid, to: nil)
    }

    static func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) {
        let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
        NSApp.postEvent(e, atStart: false)
    }

    static func click(_ p: NSPoint, clicks: Int = 1) async {
        for c in 1...clicks {
            mouse(.leftMouseDown, p, clicks: c)
            mouse(.leftMouseUp, p, clicks: c)
            try? await Task.sleep(for: .milliseconds(60))
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func drag(from a: NSPoint, to b: NSPoint) async {
        mouse(.leftMouseDown, a)
        try? await Task.sleep(for: .milliseconds(150))
        for i in 1...20 {
            let t = CGFloat(i) / 20
            mouse(.leftMouseDragged, NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try? await Task.sleep(for: .milliseconds(30))
        }
        try? await Task.sleep(for: .milliseconds(200))
        mouse(.leftMouseUp, b)
        try? await Task.sleep(for: .milliseconds(800))
    }

    static func key(_ code: UInt16, _ chars: String) async {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
            NSApp.postEvent(e, atStart: false)
        }
        try? await Task.sleep(for: .milliseconds(400))
    }

    static var step = 0
    static func report(_ title: String, _ store: Store) {
        step += 1
        let t = table
        print(String(format: "STEP %02d %@", step, title))
        print("  selection=\(store.selection?.description ?? "nil") renaming=\(store.renaming ?? "-")")
        print("  groups=" + store.groups.map { "\($0.name)\($0.expanded ? "▾" : "▸")\($0.members)" }.joined(separator: " ") + " ungrouped=\(store.ungrouped)")
        print("  firstResponder=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")")
        print("  tableRows=\(t.numberOfRows) expected=\(store.flattened.count) selectedRow=\(t.selectedRow)")
        guard let dir, let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/step-%02d.png", dir, step)))
    }

    static func run(_ s: Store) async {
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        var cls: [String] = []
        classes(table, into: &cls)
        print("TABLE \(type(of: table)) outline=\(table is NSOutlineView)")
        print(cls.prefix(40).joined(separator: "\n"))
        if let o = table as? NSOutlineView {
            for r in 0..<o.numberOfRows {
                print("row \(r) level=\(o.level(forRow: r)) expandable=\(o.isExpandable(o.item(atRow: r))) rect=\(o.rect(ofRow: r)) outlineCell=\(o.frameOfOutlineCell(atRow: r)) model=\(r < s.flattened.count ? s.flattened[r] : "?")")
            }
        }
        report("initial", s)

        let textX: CGFloat = 80
        await click(point(row: rowIndex("group:隔離テスト", s)!, x: textX))
        report("click group label 隔離テスト", s)

        if let o = table as? NSOutlineView {
            let r = rowIndex("group:隔離テスト", s)!
            let cell = o.frameOfOutlineCell(atRow: r)
            await click(o.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil))
            report("click triangle of 隔離テスト (expect collapse, selection kept)", s)
            await click(o.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil))
            report("click triangle again (expect expand)", s)
        }

        await click(point(row: rowIndex("vm:guest1", s)!, x: textX))
        report("click vm guest1", s)
        if let o = table as? NSOutlineView {
            let r = rowIndex("group:隔離テスト", s)!
            let cell = o.frameOfOutlineCell(atRow: r)
            await click(o.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil))
            report("collapse 隔離テスト while guest1 selected", s)
            await click(o.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil))
            report("expand it again", s)
        }

        await click(point(row: rowIndex("group:隔離テスト", s)!, x: textX))
        await key(125, String(Character(UnicodeScalar(NSDownArrowFunctionKey)!)))
        report("down arrow from group (expect first child gateway)", s)
        await click(point(row: rowIndex("group:隔離テスト", s)!, x: textX))
        await key(123, String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!)))
        report("left arrow on group (expect collapse)", s)
        await key(124, String(Character(UnicodeScalar(NSRightArrowFunctionKey)!)))
        report("right arrow on group (expect expand)", s)

        await click(point(row: rowIndex("group:ディストリ", s)!, x: textX), clicks: 2)
        report("double-click group ディストリ (expect primaryAction -> renaming)", s)
        s.renaming = nil

        // Drag guest2 onto the ディストリ label.
        let from = point(row: rowIndex("vm:guest2", s)!, x: textX)
        let to = point(row: rowIndex("group:ディストリ", s)!, x: textX)
        await drag(from: from, to: to)
        report("drag guest2 onto group ディストリ label", s)

        // Drag gateway below guest1 (reorder within group).
        await drag(from: point(row: rowIndex("vm:gateway", s)!, x: textX),
                   to: NSPoint(x: point(row: rowIndex("vm:guest1", s)!, x: textX).x,
                               y: point(row: rowIndex("vm:guest1", s)!, x: textX).y - 8))
        report("drag gateway below guest1", s)

        // Drag a grouped VM into the ungrouped area.
        await drag(from: point(row: rowIndex("vm:fedora", s)!, x: textX),
                   to: point(row: rowIndex("vm:macOS27", s)!, x: textX))
        report("drag fedora into ungrouped near macOS27", s)

        print("EVENTS\n" + s.events.joined(separator: "\n"))
        exit(0)
    }

    static func typeText(_ text: String) async {
        for ch in text { await key(0, String(ch)) }
    }

    /// y of the boundary above a row (window coordinates), for "insert between" drops.
    static func edge(aboveRow row: Int, x: CGFloat) -> NSPoint {
        let t = table
        let r = t.rect(ofRow: row)
        return t.convert(NSPoint(x: x, y: r.minY + 2), to: nil)
    }

    static func run2(_ s: Store) async {
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let x: CGFloat = 80
        report("initial", s)

        await click(point(row: rowIndex("group:ディストリ", s)!, x: x), clicks: 2)
        report("double-click ディストリ", s)
        await key(0, "a")  // select-all is not needed: the field starts with the name
        await typeText("2")
        await key(36, "\r")
        report("type '2' + Return (expect rename to ディストリa2 or similar)", s)

        await drag(from: point(row: rowIndex("vm:fedora", s)!, x: x), to: edge(aboveRow: rowIndex("vm:macOS27", s)!, x: x))
        report("drag fedora to the edge above macOS27 (ungrouped insert)", s)

        await drag(from: point(row: rowIndex("vm:hanalima-dev", s)!, x: x), to: point(row: rowIndex("group:空", s)!, x: x))
        report("drag hanalima-dev onto empty group 空", s)

        await drag(from: point(row: rowIndex("vm:gateway", s)!, x: x), to: edge(aboveRow: rowIndex("vm:ubuntu-24.04", s)!, x: x))
        report("drag gateway between ubuntu-lts and ubuntu-24.04 (cross-group insert)", s)

        let g2 = s.groups[1].name
        await drag(from: point(row: rowIndex("group:\(g2)", s)!, x: x), to: edge(aboveRow: rowIndex("group:隔離テスト", s)!, x: x))
        report("drag group \(g2) above 隔離テスト (group reorder)", s)

        // Collapse 空 and drop onto the collapsed label.
        if let o = table as? NSOutlineView, let r = rowIndex("group:隔離テスト", s) {
            let cell = o.frameOfOutlineCell(atRow: r)
            await click(o.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil))
        }
        await drag(from: point(row: rowIndex("vm:JAIST-Alumni", s)!, x: x), to: point(row: rowIndex("group:隔離テスト", s)!, x: x))
        report("drag JAIST-Alumni onto collapsed 隔離テスト", s)

        print("EVENTS\n" + s.events.joined(separator: "\n"))
        exit(0)
    }

    static func run3(_ s: Store) async {
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let x: CGFloat = 80
        for (label, target) in [("edge above macOS27", { edge(aboveRow: rowIndex("vm:macOS27", s)!, x: x) }),
                                ("center of macOS27", { point(row: rowIndex("vm:macOS27", s)!, x: x) }),
                                ("edge below last ungrouped", { let t = table; let r = t.rect(ofRow: rowIndex("vm:JAIST-Alumni", s)!); return t.convert(NSPoint(x: x, y: r.maxY - 2), to: nil) })] {
            await drag(from: point(row: rowIndex("vm:fedora", s)!, x: x), to: target())
            report("drag fedora -> \(label)", s)
            if s.ungrouped.contains("fedora") { break }
        }
        print("EVENTS\n" + s.events.joined(separator: "\n"))
        exit(0)
    }

    static func run4(_ s: Store) async {
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let x: CGFloat = 80
        await drag(from: point(row: rowIndex("vm:fedora", s)!, x: x), to: point(row: rowIndex("vm:macOS27", s)!, x: x))
        report("drag fedora onto macOS27 row (move out, before macOS27)", s)
        await drag(from: point(row: rowIndex("vm:gateway", s)!, x: x), to: point(row: rowIndex("vm:ubuntu-24.04", s)!, x: x))
        report("drag gateway onto ubuntu-24.04 row (cross-group, before it)", s)
        await drag(from: point(row: rowIndex("vm:guest1", s)!, x: x), to: edge(aboveRow: rowIndex("vm:guest2", s)! + 1, x: x))
        report("reorder guest1 below guest2 via edge (onMove still works?)", s)
        await drag(from: point(row: rowIndex("vm:ubuntu-lts", s)!, x: x), to: edge(aboveRow: rowIndex("vm:ubuntu-24.04", s)!, x: x))
        report("reorder ubuntu-lts to the edge above ubuntu-24.04 (gateway in between)", s)
        await drag(from: point(row: rowIndex("vm:JAIST-Alumni", s)!, x: x), to: point(row: rowIndex("vm:hanalima-dev", s)!, x: x))
        report("drag JAIST-Alumni onto hanalima-dev (same ForEach, row drop vs onMove)", s)
        print("EVENTS\n" + s.events.joined(separator: "\n"))
        exit(0)
    }

    static func run5(_ s: Store) async {
        try? await Task.sleep(for: .seconds(1.5))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        let x: CGFloat = 80
        await click(point(row: rowIndex("group:ディストリ", s)!, x: x), clicks: 2)
        report("double-click group ディストリ", s)
        s.renaming = nil
        await click(point(row: rowIndex("vm:fedora", s)!, x: x), clicks: 2)
        report("double-click vm fedora", s)
        await click(point(row: rowIndex("vm:macOS27", s)!, x: x), clicks: 2)
        report("double-click ungrouped vm macOS27", s)
        print("EVENTS\n" + s.events.joined(separator: "\n"))
        exit(0)
    }
}
