import AppKit
import SwiftUI

@main
struct SidebarSpikeApp: App {
    @State private var store = Store()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("Sidebar Spike", id: "main") {
            ContentView()
                .environment(store)
                .frame(minWidth: 700, minHeight: 560)
                .task { Probe.startIfRequested(store) }
        }
    }
}

struct ContentView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(alignment: .leading, spacing: 8) {
                Text("selection: \(store.selection?.description ?? "nil")").font(.title3)
                Text("groups: " + store.groups.map { "\($0.name)\($0.expanded ? "▾" : "▸")\($0.members)" }.joined(separator: "  "))
                Text("ungrouped: \(store.ungrouped)")
                Divider()
                ScrollView { Text(store.events.suffix(20).joined(separator: "\n")).font(.caption.monospaced()) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Variant via SPIKE_DRAG: "both" (default: onMove + draggable/dropDestination), "move" (onMove only).
let dragVariant = ProcessInfo.processInfo.environment["SPIKE_DRAG"] ?? "both"

struct Sidebar: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section("仮想マシン") {
                ForEach($store.groups) { $group in
                    DisclosureGroup(isExpanded: $group.expanded) {
                        ForEach(group.members, id: \.self) { vm in
                            vmRow(vm)
                        }
                        .onMove { store.reorder(inGroup: group.name, from: $0, to: $1) }
                        .dropDestination(for: String.self) { items, index in
                            store.move(items, toGroup: group.name, at: index)
                        }
                    } label: {
                        GroupRow(group: group)
                            .tag(Item.group(group.name))
                            .modifier(LabelDrop(enabled: dragVariant == "both") { items in
                                store.move(items, toGroup: group.name)
                            })
                    }
                }
                .onMove { store.reorderGroups(from: $0, to: $1) }
                if ProcessInfo.processInfo.environment["SPIKE_NOMOVE"] == "1" {
                    ForEach(store.ungrouped, id: \.self) { vm in
                        vmRow(vm)
                    }
                    .dropDestination(for: String.self) { items, index in
                        store.moveOut(items, at: index)
                    }
                } else {
                    ForEach(store.ungrouped, id: \.self) { vm in
                        vmRow(vm)
                    }
                    .onMove { store.reorderUngrouped(from: $0, to: $1) }
                    .dropDestination(for: String.self) { items, index in
                        store.moveOut(items, at: index)
                    }
                }
            }
            Section("ストレージ") {
                Label("ディスク", systemImage: "externaldrive").tag(Item.disks)
            }
        }
        .contextMenu(forSelectionType: Item.self) { items in
            if let item = items.first {
                switch item {
                case .group(let name):
                    Button("名前を変更") { store.renaming = name }
                case .vm(let name):
                    Menu("グループへ移動") {
                        ForEach(store.groups) { g in Button(g.name) { store.move([name], toGroup: g.name) } }
                        Divider()
                        Button("グループから外す") { store.moveOut([name]) }
                    }
                case .disks: EmptyView()
                }
            }
        } primaryAction: { items in
            store.note("primaryAction \(items.map(\.description))")
            if case .group(let name)? = items.first { store.renaming = name }
        }
        .onChange(of: store.selection) { _, new in store.note("selection -> \(new?.description ?? "nil")") }
    }

    @ViewBuilder
    private func vmRow(_ vm: String) -> some View {
        let row = Label(vm, systemImage: "desktopcomputer").tag(Item.vm(vm))
            .modifier(RowMenu(enabled: ProcessInfo.processInfo.environment["SPIKE_ROWMENU"] == "1", vm: vm))
        if dragVariant == "both" {
            row.draggable(vm)
                .dropDestination(for: String.self) { items, _ in
                    // Dropped on a VM row: insert before that VM, in its group (or ungrouped).
                    let items = items.filter { $0 != vm }
                    guard !items.isEmpty else { return false }
                    store.insert(items, before: vm)
                    return true
                }
        } else {
            row
        }
    }
}

struct GroupRow: View {
    @Environment(Store.self) private var store
    let group: VMGroup
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Label {
                if store.renaming == group.name {
                    TextField("名前", text: $draft)
                        .focused($focused)
                        .onSubmit { store.rename(group.name, to: draft) }
                        .onAppear { draft = group.name; focused = true }
                } else {
                    Text(group.name)
                }
            } icon: {
                Image(systemName: "folder")
            }
            Spacer()
            Text("0/\(group.members.count)").foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

struct LabelDrop: ViewModifier {
    let enabled: Bool
    let action: ([String]) -> Void
    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: String.self) { items, _ in action(items); return true }
        } else {
            content
        }
    }
}


/// SPIKE_ROWMENU=1: a per-row context menu on VM rows, as HanaLima's SidebarView has today.
struct RowMenu: ViewModifier {
    let enabled: Bool
    let vm: String
    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu { Button("起動 \(vm)") {} }
        } else {
            content
        }
    }
}
