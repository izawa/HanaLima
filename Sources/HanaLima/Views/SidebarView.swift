import AppKit
import LimaKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showCreate: Bool

    var body: some View {
        SidebarOutline(model: model, structure: SidebarOutline.structure(of: model), selection: model.selection,
                       renaming: model.renamingGroup)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Menu {
                        Button("新規仮想マシン…") { showCreate = true }
                        Button("新規グループ") { model.newGroup() }
                    } label: {
                        Label("新規仮想マシン", systemImage: "plus")
                    } primaryAction: {
                        showCreate = true
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("新規仮想マシン (⇧⌘N)")
                    Spacer()
                    if case .ready(let version) = model.availability {
                        Text("Lima \(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
            }
    }
}

// MARK: - The outline

/// The sidebar as one `NSOutlineView` in source-list style (docs/12 4.1): drops can show the
/// native insertion line at any level, highlight a group, and choose the cursor per target,
/// which a SwiftUI `List` couldn't (Prototypes/sidebar-groups-spike).
struct SidebarOutline: NSViewRepresentable {
    let model: AppModel
    /// The rows' keys in order; the outline reloads only when this changes.
    let structure: [String]
    let selection: SidebarItem?
    let renaming: String?

    /// Keys of every row as shown, expansion included.
    @MainActor
    static func structure(of model: AppModel) -> [String] {
        var keys = ["section:vm"]
        for g in model.sidebarGroups {
            keys.append("group:\(g.name)\(g.expanded ? "+" : "-")")
            if g.expanded { keys += g.members.map { "vm:\($0)" } }
        }
        keys += model.ungroupedNames.map { "vm:\($0)" }
        keys += ["section:storage", "disks", "storage", "section:network", "networks"]
        return keys
    }

    func makeCoordinator() -> Coordinator { Coordinator(model) }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = SidebarOutlineView()
        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.indentationPerLevel = 12
        outline.allowsEmptySelection = true
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([.hanaLimaVM, .hanaLimaGroup])
        outline.setDraggingSourceOperationMask([.move, .copy], forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let menu = NSMenu()
        menu.delegate = context.coordinator
        outline.menu = menu
        outline.setAccessibilityLabel(String(localized: "サイドバー"))
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        context.coordinator.update(structure: structure)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(structure: structure)
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate {
        let model: AppModel
        weak var outline: NSOutlineView?
        private var nodes: [String: SidebarNode] = [:]
        private var cells: [String: NSView] = [:]
        private var lastStructure: [String] = []
        /// True while the outline is being set from the model, so its notifications are ignored.
        private var syncing = false

        init(_ model: AppModel) { self.model = model }

        private func node(_ kind: SidebarNode.Kind, _ key: String, _ name: String) -> SidebarNode {
            if let n = nodes[key] { return n }
            let n = SidebarNode(kind, key: key, name: name)
            nodes[key] = n
            return n
        }

        private var vmSection: SidebarNode { node(.section, "section:vm", String(localized: "仮想マシン")) }
        private var storageSection: SidebarNode { node(.section, "section:storage", String(localized: "ストレージ")) }
        private var networkSection: SidebarNode { node(.section, "section:network", String(localized: "ネットワーク")) }
        func groupNode(_ name: String) -> SidebarNode { node(.group, "group:\(name)", name) }
        func vmNode(_ name: String) -> SidebarNode { node(.vm, "vm:\(name)", name) }

        func children(of item: Any?) -> [SidebarNode] {
            guard let n = item as? SidebarNode else { return [vmSection, storageSection, networkSection] }
            switch n.kind {
            case .section where n === vmSection:
                return model.sidebarGroups.map { groupNode($0.name) } + model.ungroupedNames.map { vmNode($0) }
            case .section where n === storageSection:
                return [node(.disks, "disks", ""), node(.storage, "storage", "")]
            case .section:
                return [node(.networks, "networks", "")]
            case .group:
                return model.sidebarGroups.first { $0.name == n.name }?.members.map { vmNode($0) } ?? []
            default:
                return []
            }
        }

        // MARK: Model → outline

        func update(structure: [String]) {
            guard let outline else { return }
            syncing = true
            defer { syncing = false }
            if structure != lastStructure {
                lastStructure = structure
                let keep = Set(structure.map { $0.hasPrefix("group:") ? String($0.dropLast()) : $0 })
                cells = cells.filter { keep.contains($0.key) }
                outline.reloadData()
                for n in [vmSection, storageSection, networkSection] { outline.expandItem(n) }
                for g in model.sidebarGroups {
                    if g.expanded { outline.expandItem(groupNode(g.name)) } else { outline.collapseItem(groupNode(g.name)) }
                }
            }
            let row = model.selection.flatMap(node(for:)).map { outline.row(forItem: $0) } ?? -1
            // A VM selected elsewhere (the group page, the menu bar) inside a collapsed group:
            // open the group, as Finder reveals a file; the reload then selects it.
            if row < 0, case .instance(let vm)? = model.selection, let group = model.groupName(of: vm),
               model.sidebarGroups.first(where: { $0.name == group })?.expanded == false {
                DispatchQueue.main.async { [weak self] in self?.model.setGroupExpanded(group, true) }
            }
            if row != outline.selectedRow {
                if row >= 0 {
                    outline.selectRowIndexes([row], byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                } else {
                    outline.deselectAll(nil)
                }
            }
            if let name = model.renamingGroup {
                let r = outline.row(forItem: groupNode(name))
                DispatchQueue.main.async { [weak self] in
                    self?.model.renamingGroup = nil
                    if r >= 0 { outline.editColumn(0, row: r, with: nil, select: true) }
                }
            }
        }

        private func node(for item: SidebarItem) -> SidebarNode? {
            switch item {
            case .instance(let n): vmNode(n)
            case .group(let n): model.groupLayout.index(ofGroup: n).map { groupNode(model.groupLayout.groups[$0].name) }
            case .disks: nodes["disks"]
            case .storage: nodes["storage"]
            case .networks: nodes["networks"]
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let n = item as? SidebarNode else { return false }
            return n.kind == .section || n.kind == .group
        }

        // MARK: Delegate

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarNode)?.kind == .section }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarNode)?.kind != .section }
        func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { (item as? SidebarNode)?.kind != .section }
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { (item as? SidebarNode)?.kind != .section }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            switch (item as? SidebarNode)?.kind {
            case .section: 26
            case .vm: 40
            default: 30
            }
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let n = item as? SidebarNode else { return nil }
            if let cell = cells[n.key] { return cell }
            let cell: NSView
            switch n.kind {
            case .section:
                cell = sectionCell(n.name)
            case .group:
                cell = groupCell(n.name)
            case .vm:
                cell = hosted(VMSidebarRow(name: n.name))
            case .disks:
                cell = hosted(CountRow(title: "ディスク", systemImage: "externaldrive", count: { $0.disks.count }))
            case .storage:
                cell = hosted(Label("使用量", systemImage: "chart.pie").frame(maxWidth: .infinity, alignment: .leading))
            case .networks:
                cell = hosted(CountRow(title: "仮想ネットワーク", systemImage: "point.3.connected.trianglepath.dotted",
                                       count: { $0.virtualNetworks.count }))
            }
            cells[n.key] = cell
            return cell
        }

        private func hosted(_ view: some View) -> NSView {
            let cell = NSTableCellView()
            let host = NSHostingView(rootView: AnyView(view.environment(model)))
            host.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                host.topAnchor.constraint(equalTo: cell.topAnchor),
                host.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            ])
            return cell
        }

        private func sectionCell(_ title: String) -> NSView {
            let cell = NSTableCellView()
            let text = NSTextField(labelWithString: title)
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            text.textColor = .secondaryLabelColor
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                                         text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
            return cell
        }

        /// AppKit text field so the name can be edited in place; the count is SwiftUI so it updates.
        private func groupCell(_ name: String) -> NSView {
            let cell = NSTableCellView()
            let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!)
            icon.contentTintColor = .secondaryLabelColor
            let text = NSTextField(labelWithString: name)
            text.isEditable = true
            text.delegate = self
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let count = NSHostingView(rootView: AnyView(GroupCount(name: name).environment(model)))
            for v in [icon, text, count] as [NSView] {
                v.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(v)
            }
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
        }

        // MARK: Outline → model

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !syncing, let outline else { return }
            let n = outline.item(atRow: outline.selectedRow) as? SidebarNode
            let item: SidebarItem? = switch n?.kind {
            case .group: .group(n!.name)
            case .vm: .instance(n!.name)
            case .disks: .disks
            case .storage: .storage
            case .networks: .networks
            default: nil
            }
            if model.selection != item { model.selection = item }
        }

        func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, false) }

        private func expansionChanged(_ notification: Notification, _ expanded: Bool) {
            guard !syncing, let n = notification.userInfo?["NSObject"] as? SidebarNode, n.kind == .group else { return }
            model.setGroupExpanded(n.name, expanded)
        }

        @objc func doubleClicked(_ sender: NSOutlineView) {
            let row = sender.clickedRow
            guard (sender.item(atRow: row) as? SidebarNode)?.kind == .group else { return }
            // On the next turn: editing started inside the double-click's own handling ends at once.
            DispatchQueue.main.async { sender.editColumn(0, row: row, with: nil, select: true) }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField, let outline else { return }
            guard let n = outline.item(atRow: outline.row(for: field)) as? SidebarNode, n.kind == .group else { return }
            let new = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if new == n.name { return }
            field.stringValue = n.name  // shown until the rename reloads the row (or if refused)
            model.renameGroup(n.name, to: new)
        }

        // MARK: Context menu (group rows and empty space; VM rows have their SwiftUI menu)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline else { return }
            let n = outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? SidebarNode : nil
            if n?.kind == .group, let name = n?.name {
                menu.addItem(MenuAction.item(String(localized: "名前を変更")) { [weak self] in
                    guard let self, let outline = self.outline else { return }
                    let r = outline.row(forItem: self.groupNode(name))
                    if r >= 0 { outline.editColumn(0, row: r, with: nil, select: true) }
                })
                menu.addItem(MenuAction.item(String(localized: "グループを解除")) { [weak self] in self?.model.ungroup(name) })
                menu.addItem(.separator())
                let active = model.isGroupRunActive(name)
                let members = model.sidebarGroups.first { $0.name == name }?.members ?? []
                for action in GroupAction.allCases {
                    if action == .hibernate, !members.contains(where: { model.instance(named: $0)?.usesHanaLimaDriver == true }) { continue }
                    let item = MenuAction.item(action.label + "…") { [weak self] in self?.model.requestGroupRun(action, group: name) }
                    item.isEnabled = !active && !members.isEmpty
                    menu.addItem(item)
                }
                menu.autoenablesItems = false
                menu.addItem(.separator())
            }
            if n == nil || n?.kind == .group || n === vmSection {
                menu.addItem(MenuAction.item(String(localized: "新規グループ")) { [weak self] in self?.model.newGroup() })
            }
        }

        // MARK: Drag and drop (docs/12 4.2)

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let n = item as? SidebarNode else { return nil }
            let p = NSPasteboardItem()
            switch n.kind {
            case .vm where model.metadata[n.name] != nil: p.setString(n.name, forType: .hanaLimaVM)
            case .group: p.setString(n.name, forType: .hanaLimaGroup)
            default: return nil
            }
            return p
        }

        /// Decides a drop at (item, index), retargeting it so the line shows where it will go:
        /// `.move` is a line or a highlighted group, `.copy` the plus (two ungrouped VMs make a
        /// new group), [] refuses.
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                         proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            let groups = model.sidebarGroups.map { SidebarDropRule.Group(name: $0.name, expanded: $0.expanded, members: $0.members) }
            let decision = SidebarDropRule.decide(dragged(info), on: target(item), at: index,
                                                  groups: groups, ungrouped: model.ungroupedNames)
            if decision.operation != .none, decision.target != target(item) || decision.index != index {
                outlineView.setDropItem(node(for: decision.target), dropChildIndex: decision.index)
            }
            switch decision.operation {
            case .none: return []
            case .move: return .move
            case .newGroup: return .copy
            }
        }

        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            SidebarDrop.perform(dragged(info), on: target(item), at: index, model: model)
        }

        private func dragged(_ info: any NSDraggingInfo) -> SidebarDropRule.Dragged? {
            let pb = info.draggingPasteboard
            if let vm = pb.string(forType: .hanaLimaVM) { return .vm(vm) }
            if let group = pb.string(forType: .hanaLimaGroup) { return .group(group) }
            return nil
        }

        private func target(_ item: Any?) -> SidebarDropRule.Place {
            guard let n = item as? SidebarNode else { return .root }
            switch n.kind {
            case .section where n === vmSection: return .vmSection
            case .group: return .group(n.name)
            case .vm: return .vm(n.name)
            default: return .other
            }
        }

        private func node(for place: SidebarDropRule.Place) -> SidebarNode? {
            switch place {
            case .vmSection: vmSection
            case .group(let name): groupNode(name)
            case .vm(let name): vmNode(name)
            case .root, .other: nil
            }
        }
    }
}

/// The sidebar's outline view (its own class so DebugSnapshot can find it).
final class SidebarOutlineView: NSOutlineView {}

final class SidebarNode: NSObject {
    enum Kind { case section, group, vm, disks, storage, networks }
    let kind: Kind
    let key: String
    let name: String

    init(_ kind: Kind, key: String, name: String) {
        self.kind = kind
        self.key = key
        self.name = name
    }
}

extension NSPasteboard.PasteboardType {
    static let hanaLimaVM = NSPasteboard.PasteboardType("org.izawa.HanaLima.vm")
    static let hanaLimaGroup = NSPasteboard.PasteboardType("org.izawa.HanaLima.group")
}

/// An NSMenuItem running a closure (the menu keeps the target alive through representedObject).
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }

    static func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(run), keyEquivalent: "")
        item.target = target
        item.representedObject = target
        return item
    }
}

// MARK: - Drops

/// Carries out a drop the outline accepted (at the retargeted place; rules in SidebarDropRule).
@MainActor
enum SidebarDrop {
    static func perform(_ dragged: SidebarDropRule.Dragged?, on target: SidebarDropRule.Place, at index: Int,
                        model: AppModel) -> Bool {
        switch (dragged, target) {
        case (.group(let g), .vmSection):
            guard let from = model.groupLayout.index(ofGroup: g) else { return false }
            model.moveGroup(from: from, to: index)
        case (.vm(let vm), .group(let g)):
            model.moveVM(vm, toGroup: g, at: index == SidebarDropRule.onItem ? nil : index)
        case (.vm(let vm), .vm(let other)):
            model.newGroup(with: [other, vm])
        case (.vm(let vm), .vmSection):
            model.moveVM(vm, toGroup: nil, at: index - model.groupLayout.groups.count)
        default:
            return false
        }
        return true
    }
}

// MARK: - Rows

private struct VMSidebarRow: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        SidebarRow(name: name)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                InstanceActionsMenu(name: name)
                if model.metadata[name] != nil {
                    Divider()
                    GroupMoveMenu(name: name)
                }
            }
    }
}

/// 「グループへ移動」 and 「グループから外す」 for a VM.
private struct GroupMoveMenu: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let current = model.groupName(of: name)
        Menu("グループへ移動") {
            ForEach(model.groupLayout.groups.map(\.name), id: \.self) { group in
                Button(group) { model.moveVM(name, toGroup: group) }
                    .disabled(group == current)
            }
            if !model.groupLayout.groups.isEmpty { Divider() }
            Button("新規グループ…") { model.newGroup(with: [name]) }
        }
        if current != nil {
            Button("グループから外す") { model.moveVM(name, toGroup: nil, at: 0) }
        }
    }
}

private struct GroupCount: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        if let group = model.sidebarGroups.first(where: { $0.name == name }) {
            let counts = model.groupCounts(group)
            Text("\(counts.running)/\(counts.total)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .help("実行中の台数／全体の台数")
        }
    }
}

private struct CountRow: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    let systemImage: String
    let count: (AppModel) -> Int

    var body: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                let n = count(model)
                if n > 0 { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

struct SidebarRow: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let instance = model.instance(named: name)
        HStack(spacing: 8) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                Text(subtitle(instance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.isBusy(name) {
                ProgressView().controlSize(.small)
            } else {
                StatusDot(color: model.isPaused(name) ? .yellow : model.isHibernated(name) ? .indigo : instance?.status.color ?? .gray)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ instance: LimaInstance?) -> String {
        if let op = model.operations[name], op.isRunning {
            if let percent = op.download?.percent {
                return String(localized: "\(op.kind.progressLabel) · ダウンロード \(percent)%")
            }
            return op.kind.progressLabel + "…"
        }
        guard let instance else { return String(localized: "作成中…") }
        var parts = [model.isPaused(name) ? String(localized: "一時停止中")
                     : model.isHibernated(name) ? String(localized: "休止中") : instance.status.label]
        if model.pendingInstall(instance.name) != nil {
            parts.append(String(localized: "インストール待ち"))
        } else if model.sharedDiskOwners[instance.name] != nil {
            parts.append(String(localized: "ディスクを共有"))
        } else if case .missing = model.diskPlacement(of: instance) {
            parts.append(String(localized: "ディスクが見つからない"))
        } else if !model.deletedNetworkSockets(of: instance).isEmpty {
            parts.append(String(localized: "NIC の接続先なし"))
        } else if instance.isRunning, !(model.restartNeeded[name] ?? []).isEmpty {
            parts.append(String(localized: "再起動が必要"))
        } else if let vm = instance.vmType {
            parts.append(vm.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}

/// Start/stop/delete actions shared by the context menu and the toolbar.
struct InstanceActionsMenu: View {
    @Environment(AppModel.self) private var model
    let name: String

    var body: some View {
        let instance = model.instance(named: name)
        let busy = model.isBusy(name)
        if instance?.isRunning == true {
            if instance?.usesHanaLimaDriver == true {
                if model.isPaused(name) {
                    Button("再開") { model.resume(name) }.disabled(busy)
                } else {
                    Button("一時停止") { model.pause(name) }.disabled(model.pauseBlocker(name) != nil)
                }
                Button("休止") { model.hibernate(name) }.disabled(model.hibernateBlocker(name) != nil)
            }
            Button("停止") { model.stop(name) }.disabled(busy)
            Button("再起動") { model.restart(name) }.disabled(busy)
        } else {
            Button(model.isHibernated(name) ? "再開" : "起動") { model.start(name) }.disabled(busy || instance == nil)
            if model.isHibernated(name) {
                Button("保存した状態を捨てる…") { model.confirmDiscardSavedState(name) }.disabled(busy)
            }
        }
        Button("複製…") { model.copyRequest = CopyRequest(source: name) }
            .disabled(model.copyBlocker(name) != nil)
        Button("救出起動…") { model.rescueRequest = RescueRequest(name: name) }
            .disabled(model.rescueBlocker(name) != nil)
        Divider()
        if let instance {
            Button("Finder で表示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: instance.dir)])
            }
        }
    }
}
