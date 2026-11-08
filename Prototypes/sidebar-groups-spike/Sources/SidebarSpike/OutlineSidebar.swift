import AppKit
import SwiftUI

// The AppKit variant (SPIKE_IMPL=appkit, the default): the whole sidebar is one NSOutlineView in
// source-list style, so drops can show the native insertion line at any level, highlight a group
// row, and choose the cursor per target.

/// Outline items. NSOutlineView compares items by identity, so nodes are cached by key.
final class Node: NSObject {
    enum Kind { case section, group, vm, leaf }
    let kind: Kind
    let key: String
    var title: String

    init(_ kind: Kind, key: String, title: String) {
        self.kind = kind
        self.key = key
        self.title = title
    }
}

extension NSPasteboard.PasteboardType {
    static let spikeVM = NSPasteboard.PasteboardType("org.izawa.hanalima.spike.vm")
    static let spikeGroup = NSPasteboard.PasteboardType("org.izawa.hanalima.spike.group")
}

struct OutlineSidebar: NSViewRepresentable {
    let store: Store
    /// Read in body so SwiftUI calls updateNSView when the model changes.
    let version: Int
    var newGroupRequest: Bool { store.requestNewGroup }

    func makeCoordinator() -> Coordinator { Coordinator(store) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = NSOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.spikeVM, .spikeGroup])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.reload()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.reload()
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        let store: Store
        weak var outline: NSOutlineView?
        private var cache: [String: Node] = [:]
        private var syncing = false
        private var lastValidation = ""
        /// The (item, index) the last validateDrop settled on, for the probe.
        var lastTarget: (Node?, Int) = (nil, 0)

        init(_ store: Store) { self.store = store }

        private func node(_ kind: Node.Kind, _ key: String, _ title: String) -> Node {
            if let n = cache[key] { n.title = title; return n }
            let n = Node(kind, key: key, title: title)
            cache[key] = n
            return n
        }

        var vmSection: Node { node(.section, "section:vm", "仮想マシン") }
        var storageSection: Node { node(.section, "section:storage", "ストレージ") }
        func groupNode(_ name: String) -> Node { node(.group, "group:\(name)", name) }
        func vmNode(_ name: String) -> Node { node(.vm, "vm:\(name)", name) }

        func children(of item: Any?) -> [Node] {
            guard let n = item as? Node else { return [vmSection, storageSection] }
            switch n.kind {
            case .section where n === vmSection:
                return store.groups.map { groupNode($0.name) } + store.ungrouped.map { vmNode($0) }
            case .section:
                return [node(.leaf, "disks", "ディスク")]
            case .group:
                return store.groups.first { $0.name == n.title }?.members.map { vmNode($0) } ?? []
            default:
                return []
            }
        }

        func reload() {
            guard let outline, !syncing else { return }
            if store.requestNewGroup {
                store.requestNewGroup = false
                DispatchQueue.main.async { self.newGroup(with: []) }
            }
            syncing = true
            defer { syncing = false }
            outline.reloadData()
            outline.expandItem(vmSection)
            outline.expandItem(storageSection)
            for g in store.groups {
                if g.expanded { outline.expandItem(groupNode(g.name)) } else { outline.collapseItem(groupNode(g.name)) }
            }
            let row = store.selection.flatMap { item(for: $0) }.map { outline.row(forItem: $0) } ?? -1
            if row >= 0 { outline.selectRowIndexes([row], byExtendingSelection: false) } else { outline.deselectAll(nil) }
            if let name = store.renaming, store.renamingStarted == false {
                store.renamingStarted = true
                let r = outline.row(forItem: groupNode(name))
                if r >= 0 {
                    DispatchQueue.main.async { outline.editColumn(0, row: r, with: nil, select: true) }
                }
            }
        }

        func item(for selection: Item) -> Node? {
            switch selection {
            case .group(let n): groupNode(n)
            case .vm(let n): vmNode(n)
            case .disks: cache["disks"]
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? Node else { return false }
            return n.kind == .section || n.kind == .group
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? Node)?.kind == .section }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? Node)?.kind != .section }
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { (item as? Node)?.kind != .section }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            (item as? Node)?.kind == .section ? 24 : 30
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? Node else { return nil }
            switch n.kind {
            case .section:
                let cell = NSTableCellView()
                let text = NSTextField(labelWithString: n.title)
                text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
                text.textColor = .secondaryLabelColor
                cell.addSubview(text)
                cell.textField = text
                text.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                             text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
                return cell
            case .group:
                // AppKit text field so the name can be edited in place (editColumn).
                let cell = NSTableCellView()
                let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
                let text = NSTextField(labelWithString: n.title)
                text.isEditable = true
                text.delegate = self
                text.lineBreakMode = .byTruncatingTail
                let count = NSTextField(labelWithString: "0/\(store.groups.first { $0.name == n.title }?.members.count ?? 0)")
                count.textColor = .secondaryLabelColor
                count.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                for v in [icon, text, count] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
                cell.imageView = icon
                cell.textField = text
                NSLayoutConstraint.activate([
                    icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    count.leadingAnchor.constraint(greaterThanOrEqualTo: text.trailingAnchor, constant: 6),
                    count.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
                    count.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return cell
            case .vm, .leaf:
                // SwiftUI content hosted in the cell, as HanaLima's rows would be.
                let cell = NSTableCellView()
                let host = NSHostingView(rootView: HostedRow(name: n.title, systemImage: n.kind == .vm ? "desktopcomputer" : "externaldrive"))
                host.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(host)
                NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                                             host.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                                             host.topAnchor.constraint(equalTo: cell.topAnchor),
                                             host.bottomAnchor.constraint(equalTo: cell.bottomAnchor)])
                return cell
            }
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            let n = outline.item(atRow: outline.selectedRow) as? Node
            let new: Item? = switch n?.kind {
            case .group: .group(n!.title)
            case .vm: .vm(n!.title)
            case .leaf: .disks
            default: nil
            }
            if store.selection != new { store.selection = new; store.note("selection -> \(new?.description ?? "nil")") }
        }

        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, false) }

        private func expansionChanged(_ notification: Notification, _ expanded: Bool) {
            guard !syncing, let n = notification.userInfo?["NSObject"] as? Node, n.kind == .group,
                  let i = store.groups.firstIndex(where: { $0.name == n.title }), store.groups[i].expanded != expanded else { return }
            store.groups[i].expanded = expanded
            store.note("\(expanded ? "expand" : "collapse") \(n.title)")
        }

        // MARK: Rename

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard let n = sender.item(atRow: sender.clickedRow) as? Node else { return }
            store.note("doubleClick \(n.key)")
            // After the click finishes; editing started inside the double-click's mouse handling ends at once.
            let row = sender.clickedRow
            if n.kind == .group { DispatchQueue.main.async { sender.editColumn(0, row: row, with: nil, select: true) } }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let outline else { return }
            let row = outline.row(for: field)
            guard let n = outline.item(atRow: row) as? Node, n.kind == .group else { return }
            let new = field.stringValue.trimmingCharacters(in: .whitespaces)
            store.renaming = n.title
            store.rename(n.title, to: new)
            if store.groups.contains(where: { $0.name == n.title }) { field.stringValue = n.title }  // refused
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            let n = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? Node : nil
            switch n?.kind {
            case .group:
                menu.addItem(item("名前を変更") { [weak self] in self?.beginRename(n!.title) })
                menu.addItem(item("グループを解除") { [weak self] in self?.store.ungroup(n!.title) })
            case .vm:
                let move = NSMenuItem(title: "グループへ移動", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for g in store.groups { sub.addItem(item(g.name) { [weak self] in self?.store.move([n!.title], toGroup: g.name) }) }
                sub.addItem(.separator())
                sub.addItem(item("新規グループ…") { [weak self] in self?.newGroup(with: [n!.title]) })
                move.submenu = sub
                menu.addItem(move)
                if store.groupIndex(of: n!.title) != nil {
                    menu.addItem(item("グループから外す") { [weak self] in self?.store.moveOut([n!.title]) })
                }
            default:
                menu.addItem(item("新規グループ") { [weak self] in self?.newGroup(with: []) })
            }
        }

        private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            let box = MenuAction(action)
            i.target = box
            i.representedObject = box  // keep it alive
            return i
        }

        func newGroup(with vms: [String]) {
            let name = store.addGroup(with: vms)
            beginRename(name)
        }

        func beginRename(_ name: String) {
            store.selection = .group(name)
            store.renaming = name
            store.renamingStarted = false
            reload()
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let n = item as? Node else { return nil }
            let p = NSPasteboardItem()
            switch n.kind {
            case .vm: p.setString(n.title, forType: .spikeVM)
            case .group: p.setString(n.title, forType: .spikeGroup)
            default: return nil
            }
            return p
        }

        private func dragged(_ info: any NSDraggingInfo) -> (vm: String?, group: String?) {
            let pb = info.draggingPasteboard
            return (pb.string(forType: .spikeVM), pb.string(forType: .spikeGroup))
        }

        /// Decides what a drop at (item, index) means, possibly retargeting it, and returns the
        /// operation: .move shows the line or a highlight, .copy the plus (new group), [] refuses.
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let target = item as? Node
            let (vm, group) = dragged(info)
            var op: NSDragOperation = []
            var finalItem: Node? = target
            var finalIndex = index
            let groupCount = store.groups.count

            if let group {
                // Groups only reorder among groups (no nesting: a group onto a group is refused).
                if target === vmSection, index >= 0, index <= groupCount {
                    op = .move
                } else if target === vmSection, index > groupCount {
                    finalItem = vmSection; finalIndex = groupCount; op = .move
                }
                _ = group
            } else if let vm {
                switch target?.kind {
                case .group where index == NSOutlineViewDropOnItemIndex:
                    // Into a group (highlight); nothing if it is already there.
                    op = store.groups.first { $0.name == target!.title }?.members.contains(vm) == true ? [] : .move
                case .group:
                    op = .move  // between members: line
                case .vm where index == NSOutlineViewDropOnItemIndex:
                    if target!.title == vm {
                        op = []
                    } else if let g = store.groupIndex(of: target!.title) {
                        // On a VM in a group: no nesting, so a line before it.
                        finalItem = groupNode(store.groups[g].name)
                        finalIndex = store.groups[g].members.firstIndex(of: target!.title)!
                        op = .move
                    } else {
                        op = .copy  // onto an ungrouped VM: a new group of the two
                    }
                case .section where target === vmSection && index >= 0:
                    if index < groupCount {
                        // Between groups: a VM can't sit there. After an expanded group, append to it;
                        // otherwise go to the top of the ungrouped VMs.
                        if index > 0, store.groups[index - 1].expanded {
                            finalItem = groupNode(store.groups[index - 1].name)
                            finalIndex = store.groups[index - 1].members.count
                        } else {
                            finalIndex = groupCount
                        }
                    }
                    op = .move
                case nil where index >= 0:
                    // Between the sections (below the last VM): the end of the ungrouped VMs.
                    finalItem = vmSection
                    finalIndex = groupCount + store.ungrouped.count
                    op = .move
                default:
                    op = []
                }
            }
            lastTarget = (finalItem, finalIndex)
            if finalItem !== target || finalIndex != index {
                outlineView.setDropItem(finalItem, dropChildIndex: finalIndex)
            }
            let desc = "VALIDATE \(vm.map { "vm:\($0)" } ?? group.map { "group:\($0)" } ?? "?") proposed=\(target?.key ?? "root")@\(index) -> \(finalItem?.key ?? "root")@\(finalIndex) op=\(op == .move ? "move" : op == .copy ? "copy(+)" : "none")"
            if desc != lastValidation { lastValidation = desc; print(desc) }
            return op
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            let target = item as? Node
            let (vm, group) = dragged(info)
            lastValidation = ""
            if let group {
                guard let from = store.groups.firstIndex(where: { $0.name == group }) else { return false }
                store.reorderGroups(from: [from], to: index)
            } else if let vm {
                switch target?.kind {
                case .group where index == NSOutlineViewDropOnItemIndex:
                    store.move([vm], toGroup: target!.title)
                case .group:
                    store.place(vm, inGroup: target!.title, at: index)
                case .vm:
                    newGroup(with: [target!.title, vm])
                case .section:
                    store.place(vm, inGroup: nil, at: index - store.groups.count)
                default:
                    return false
                }
            }
            return true
        }
    }
}

final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

struct HostedRow: View {
    let name: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(name).lineLimit(1)
            Spacer()
            Circle().fill(.green).frame(width: 7, height: 7)
        }
        .padding(.trailing, 8)
        .frame(maxHeight: .infinity)
    }
}
