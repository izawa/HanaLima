import Foundation
import LimaKit
import NetworkKit
import Observation

/// A long-running limactl command (create/start/stop/...) tied to one instance.
struct Operation: Sendable {
    enum Kind: String, Sendable {
        case create, start, stop, restart, delete, edit
        case snapshotCreate, snapshotApply, snapshotDelete
        case moveDisk, moveDiskBack, separateDisk
        case clone

        var label: String {
            switch self {
            case .create: String(localized: "作成")
            case .start: String(localized: "起動")
            case .stop: String(localized: "停止")
            case .restart: String(localized: "再起動")
            case .delete: String(localized: "削除")
            case .edit: String(localized: "設定変更")
            case .snapshotCreate: String(localized: "スナップショット作成")
            case .snapshotApply: String(localized: "スナップショットの復元")
            case .snapshotDelete: String(localized: "スナップショット削除")
            case .moveDisk: String(localized: "ディスクの移動")
            case .moveDiskBack: String(localized: "ディスクを内蔵に戻す処理")
            case .separateDisk: String(localized: "ディスクの独立")
            case .clone: String(localized: "複製")
            }
        }

        /// "Starting", "Creating"… A separate string rather than label + suffix: English can't
        /// build these by appending (Japanese adds 中).
        var progressLabel: String {
            switch self {
            case .create: String(localized: "作成中")
            case .start: String(localized: "起動中")
            case .stop: String(localized: "停止中")
            case .restart: String(localized: "再起動中")
            case .delete: String(localized: "削除中")
            case .edit: String(localized: "設定変更中")
            case .snapshotCreate: String(localized: "スナップショット作成中")
            case .snapshotApply: String(localized: "スナップショットの復元中")
            case .snapshotDelete: String(localized: "スナップショット削除中")
            case .moveDisk: String(localized: "ディスクを移動中")
            case .moveDiskBack: String(localized: "ディスクを内蔵に戻しています")
            case .separateDisk: String(localized: "ディスクを独立させています")
            case .clone: String(localized: "複製中")
            }
        }
    }

    var kind: Kind
    var log: [LogEntry] = []
    var isRunning = true
    var error: String?
    /// Set while limactl is downloading an image or archive.
    var download: DownloadProgress?
    /// 0...1 for operations HanaLima measures itself (moving a disk).
    var fraction: Double?
}

/// What the sidebar can select.
enum SidebarItem: Hashable {
    case instance(String)
    case disks
    case storage
    case networks

    var instanceName: String? {
        if case .instance(let name) = self { name } else { nil }
    }
}

/// An event from `limactl watch`, kept for the log tab.
struct EventRecord: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let text: String
    let isError: Bool
}

@MainActor
@Observable
final class AppModel {
    enum Availability: Equatable {
        case checking
        case ready(version: String)
        case missing
        case failed(String)
    }

    struct AlertMessage: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private(set) var availability: Availability = .checking
    private(set) var instances: [LimaInstance] = []
    private(set) var templates: [LimaTemplate] = []
    var operations: [String: Operation] = [:]
    private(set) var events: [String: [EventRecord]] = [:]
    private(set) var disks: [LimaDisk] = []
    private(set) var networks: LimaNetworks = .defaults
    /// HanaLima's own vmnet networks (served by hanalima-netd).
    var virtualNetworks: [VirtualNetwork] = []
    var networkStates: [String: LaunchAgentManager.State] = [:]
    var networkStatuses: [String: NetworkDaemonStatus] = [:]
    /// macOS's DHCP leases (written by vmnet), for showing VM addresses.
    var dhcpLeases: [DHCPLease] = []
    /// True while a `limactl disk` command runs.
    private(set) var isDiskBusy = false
    /// Space used by Lima's data and download cache (the Storage view measures it on demand).
    var storage: StorageReport?
    var isMeasuringStorage = false
    var isPruningCache = false
    /// Running instances whose boot has finished (SSH and guest agent are up). `limactl list`
    /// says Running as soon as the VM boots, so readiness comes from the watch `running` event
    /// or from `limactl start` returning.
    private(set) var readyInstances: Set<String> = []
    @ObservationIgnored private var hasListedOnce = false
    @ObservationIgnored private var bootstrapStarted = false
    /// Snapshots per instance, loaded when the snapshot tab is shown (QEMU only).
    private(set) var snapshots: [String: [LimaSnapshot]] = [:]
    /// HanaLima's snapshots of VZ instances (see DiskSnapshot), loaded with the snapshot tab.
    var diskSnapshots: [String: [DiskSnapshot]] = [:]
    /// Instances registered to start at login (`limactl autostart`).
    private(set) var autostartInstances: Set<String> = []
    var selection: SidebarItem?
    /// Set by the menu bar to show an instance's console; InstanceDetailView switches tab and clears it.
    var consoleRequest: String?
    /// Set by the menu bar and the File menu to open the create sheet; ContentView clears it.
    var createRequested = false
    /// The VM to copy, from a menu or the toolbar; the window shows the copy sheet for it.
    var copyRequest: CopyRequest?
    var alert: AlertMessage?
    /// A start/restart waiting for the user to confirm a socket_vmnet + virtual network mix.
    var pendingConflictStart: ConflictPrompt?
    /// A start/restart of an instance whose NIC points at a deleted HanaLima network.
    var pendingDeletedNetworkStart: ConflictPrompt?
    /// Running instances whose HanaLima network was changed or deleted since they started:
    /// instance name → network names. They keep the old setup until restarted.
    var restartNeeded: [String: Set<String>] = [:]
    /// Disk moves in progress, so they can be cancelled.
    @ObservationIgnored var diskMoveTasks: [String: Task<Void, Never>] = [:]
    /// Where each instance's disk is. Kept as state (not read from the file system while
    /// drawing) so every view updates when a drive is plugged in or out.
    var diskPlacements: [String: DiskPlacement] = [:]
    /// HanaLima's record of each VM (id, parent, note), by name. See `InstanceMetadata`.
    var metadata: [String: InstanceMetadata] = [:]
    /// VMs whose disk link points to another VM's moved disk (a `limactl clone` copies the link),
    /// with the VM that owns it.
    var sharedDiskOwners: [String: String] = [:]
    @ObservationIgnored var volumeObservers: [NSObjectProtocol] = []

    struct ConflictPrompt: Identifiable {
        let id = UUID()
        let name: String
        let restart: Bool
        let message: String
    }

    private(set) var client: LimaClient?
    @ObservationIgnored private var lastSSHPort: [String: Int] = [:]
    private var watchTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    private static let maxEventsPerInstance = 500
    private static let maxLogLines = 2000

    // MARK: - Lifecycle

    /// Called by both the main window and the menu bar item; only the first call does the work.
    func bootstrap() async {
        guard !bootstrapStarted else { return }
        bootstrapStarted = true
        observeVolumes()
        availability = .checking
        guard let url = LimaClient.locate() else {
            availability = .missing
            return
        }
        let client = LimaClient(limactlURL: url)
        do {
            let version = try await client.version()
            self.client = client
            availability = .ready(version: version)
        } catch {
            availability = .failed(error.localizedDescription)
            return
        }
        await refresh()
        if selection == nil { selection = instances.first.map { .instance($0.name) } }
        #if DEBUG
        if let item = DebugSnapshot.requestedSelection { selection = item }
        #endif
        networks = LimaNetworks.load()
        await setUpVirtualNetworks()
        #if DEBUG
        // After the networks are loaded, so the conflict check sees them.
        if let name = DebugSnapshot.env["HANALIMA_SNAPSHOT_START"] { start(name) }
        // A made-up download in progress, to check the banner and the sidebar without downloading.
        if let name = DebugSnapshot.env["HANALIMA_SNAPSHOT_DOWNLOAD"] {
            var op = Operation(kind: .create)
            op.download = DownloadProgress(
                remote: URL(string: "https://cloud-images.ubuntu.com/releases/resolute/release-20260927/ubuntu-26.04-server-cloudimg-arm64.img")!,
                received: 412_000_000, total: 945_530_880, bytesPerSecond: 11_800_000)
            operations[name] = op
        }
        #endif
        await client.terminateOrphanedWatchers()
        startWatching()
        startPolling()
        templates = (try? await client.templates()) ?? []
    }

    func retryBootstrap() async {
        stopBackgroundTasks()
        client = nil
        bootstrapStarted = false
        await bootstrap()
    }

    private func stopBackgroundTasks() {
        watchTask?.cancel()
        pollTask?.cancel()
        refreshTask?.cancel()
    }

    // MARK: - Queries

    func instance(named name: String?) -> LimaInstance? {
        guard let name else { return nil }
        return instances.first { $0.name == name }
    }

    /// Names shown in the sidebar: real instances plus ones still being created.
    var sidebarNames: [String] {
        let existing = Set(instances.map(\.name))
        let pending = operations.filter { [.create, .clone].contains($0.value.kind) && !existing.contains($0.key) }.keys
        return instances.map(\.name) + pending.sorted()
    }

    func isBusy(_ name: String) -> Bool { operations[name]?.isRunning == true }

    /// "作成中" while a command runs (Lima lists a VM being created as stopped), else the state.
    func statusText(of name: String) -> String {
        if let op = operations[name], op.isRunning { return op.kind.progressLabel }
        return instance(named: name)?.status.label ?? String(localized: "作成中")
    }

    func isReady(_ name: String) -> Bool { readyInstances.contains(name) }

    func refresh() async {
        guard let client else { return }
        do {
            let list = try await client.list()
            for inst in list {
                if !inst.isRunning {
                    readyInstances.remove(inst.name)
                    restartNeeded[inst.name] = nil
                } else if !hasListedOnce && !isBusy(inst.name) {
                    // Already running when the app launched: assume it finished booting.
                    // (The console retries if it turns out it hasn't.)
                    readyInstances.insert(inst.name)
                }
            }
            readyInstances.formIntersection(list.map(\.name))
            hasListedOnce = true
            if list != instances { instances = list }
            updateDiskPlacements()
            updateMetadata(list)
            let autostart = Set(list.map(\.name).filter { client.isAutostartEnabled($0) })
            if autostart != autostartInstances { autostartInstances = autostart }
        } catch {
            // Transient failures (e.g. an instance dir mid-creation) are retried by polling.
        }
        if let list = try? await client.disks(), list != disks { disks = list }
    }

    /// Coalesces bursts of watch events into a single `limactl list`.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                await refresh()
                await refreshNetworkStates()
            }
        }
    }

    private func startWatching() {
        guard let client else { return }
        watchTask = Task {
            while !Task.isCancelled {
                do {
                    for try await event in client.watch() {
                        record(event)
                        if event.affectsStatus { scheduleRefresh() }
                    }
                } catch {
                    // limactl watch exited; restart below.
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func record(_ event: WatchEvent) {
        if event.event.status.running == true { readyInstances.insert(event.instance) }
        if event.event.status.exiting == true { readyInstances.remove(event.instance) }
        let text = event.summary(previousSSHPort: lastSSHPort[event.instance])
        if let port = event.event.status.sshLocalPort, port != 0 { lastSSHPort[event.instance] = port }
        if event.event.status.exiting == true { lastSSHPort[event.instance] = nil }
        guard !text.isEmpty else { return }
        var list = events[event.instance, default: []]
        list.append(EventRecord(date: event.event.time ?? .now, text: text,
                                isError: !(event.event.status.errors ?? []).isEmpty))
        if list.count > Self.maxEventsPerInstance { list.removeFirst(list.count - Self.maxEventsPerInstance) }
        events[event.instance] = list
    }

    // MARK: - Actions

    /// Creates the VM; with `diskFolder`, moves its disk there before the first start (Lima
    /// always creates the disk under ~/.lima).
    func create(_ options: CreateOptions, startAfterCreate: Bool, diskFolder: URL? = nil) {
        guard let client else { return }
        selection = .instance(options.name)
        run(.create, on: options.name, client.create(options)) { [weak self] ok in
            guard let self, ok else { return }
            self.recordCreation(of: options.name, template: options.template)
            if let diskFolder {
                Task {
                    await self.refresh()  // moveDisk needs the instance listed
                    self.moveDisk(options.name, to: diskFolder, thenStart: startAfterCreate)
                }
            } else if startAfterCreate {
                self.start(options.name)
            }
        }
    }

    /// Starts `name`. If it would mix socket_vmnet and HanaLima networks, asks first
    /// (see NetworkConflict) unless `confirmed`.
    func start(_ name: String, confirmed: Bool = false) {
        guard !refuseIfDiskUnusable(name) else { return }
        guard let client, confirmed || !askIfDeletedNetworks(name, restart: false) else { return }
        guard confirmed || !askIfConflicting(name, restart: false) else { return }
        run(.start, on: name, client.start(name))
    }

    /// Returns true (and asks the user) if starting `name` would mix socket_vmnet and HanaLima
    /// networks.
    private func askIfConflicting(_ name: String, restart: Bool) -> Bool {
        guard let conflict = networkConflict(starting: name) else { return false }
        pendingConflictStart = ConflictPrompt(name: name, restart: restart, message: conflict.message)
        return true
    }

    func confirmConflictStart(_ prompt: ConflictPrompt) {
        if prompt.restart { restart(prompt.name, confirmed: true) } else { start(prompt.name, confirmed: true) }
    }

    func stop(_ name: String, force: Bool = false) {
        guard let client else { return }
        run(.stop, on: name, client.stop(name, force: force))
    }

    func restart(_ name: String, confirmed: Bool = false) {
        guard !refuseIfDiskUnusable(name) else { return }
        guard let client, confirmed || !askIfDeletedNetworks(name, restart: true) else { return }
        guard confirmed || !askIfConflicting(name, restart: true) else { return }
        run(.restart, on: name, client.restart(name))
    }

    /// Selects `name` and asks its detail view to show the console.
    func openConsole(_ name: String) {
        selection = .instance(name)
        consoleRequest = name
    }

    // MARK: - Snapshots

    func loadSnapshots(_ name: String) async {
        guard let client else { return }
        let list = (try? await client.snapshots(name)) ?? []
        if snapshots[name] != list { snapshots[name] = list }
    }

    /// limactl can exit 0 without creating anything (see LimaSnapshot), so check the list afterwards.
    func createSnapshot(_ name: String, tag: String) {
        guard let client else { return }
        run(.snapshotCreate, on: name, client.createSnapshot(name, tag: tag)) { [weak self] ok in
            Task { @MainActor in
                guard let self else { return }
                await self.loadSnapshots(name)
                if ok && !(self.snapshots[name] ?? []).contains(where: { $0.tag == tag }) {
                    self.alert = AlertMessage(title: String(localized: "スナップショット「\(tag)」を作成できませんでした"),
                                              message: String(localized: "limactl はエラーを返しませんでしたが、一覧に見つかりません。ログタブの「コマンド出力」を確認してください。"))
                }
            }
        }
    }

    func applySnapshot(_ name: String, tag: String) {
        guard let client else { return }
        run(.snapshotApply, on: name, client.applySnapshot(name, tag: tag)) { [weak self] _ in
            Task { await self?.loadSnapshots(name) }
        }
    }

    func deleteSnapshot(_ name: String, tag: String) {
        guard let client else { return }
        run(.snapshotDelete, on: name, client.deleteSnapshot(name, tag: tag)) { [weak self] _ in
            Task { await self?.loadSnapshots(name) }
        }
    }

    func setAutostart(_ name: String, enabled: Bool) async {
        guard let client else { return }
        do {
            try await client.setAutostart(name, enabled: enabled)
        } catch {
            // Whole sentences, not a switched word: word order differs between languages.
            alert = AlertMessage(title: enabled
                                     ? String(localized: "「\(name)」の自動起動を有効にできませんでした")
                                     : String(localized: "「\(name)」の自動起動を無効にできませんでした"),
                                 message: error.localizedDescription)
        }
        await refresh()
    }

    func delete(_ name: String, force: Bool = false) {
        guard let client else { return }
        let placement = instance(named: name).map { diskPlacement(of: $0) } ?? .local
        let dir = instance(named: name).map { URL(filePath: $0.dir, directoryHint: .isDirectory) }
        let shared = sharedDiskOwners[name] != nil
        let recordID = metadata[name]?.id
        run(.delete, on: name, client.delete(name, force: force)) { [weak self] ok in
            guard let self, ok else { return }
            if let recordID, let dir {
                DiskSnapshot.removeLocalSnapshots(limaHome: dir.deletingLastPathComponent(), id: recordID)
            }
            if let dir, !shared { self.cleanUpExternalDisk(after: name, placement: placement, instanceDir: dir) }
            self.operations[name] = nil
            self.events[name] = nil
            if self.selection == .instance(name) { self.selection = self.instances.first.map { .instance($0.name) } }
        }
    }

    /// Applies `limactl edit --set` expressions. `completion` gets whether it succeeded.
    func edit(_ name: String, set expressions: [String], completion: @escaping @MainActor (Bool) -> Void) {
        guard let client, !expressions.isEmpty else { return completion(true) }
        run(.edit, on: name, client.edit(name, set: expressions), completion: completion)
    }

    /// Replaces lima.yaml wholesale; Lima validates it and rejects invalid configs.
    func replaceConfig(_ name: String, yaml: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let client else { return completion(false) }
        run(.edit, on: name, client.replaceConfig(name, yaml: yaml), completion: completion)
    }

    func createDisk(_ name: String, sizeGiB: Int, format: String) async -> Bool {
        guard let client else { return false }
        return await runDiskCommand(String(localized: "ディスク「\(name)」の作成"), client.createDisk(name, size: ByteSize.gib(sizeGiB), format: format))
    }

    func resizeDisk(_ name: String, sizeGiB: Int) async -> Bool {
        guard let client else { return false }
        return await runDiskCommand(String(localized: "ディスク「\(name)」のサイズ変更"), client.resizeDisk(name, size: ByteSize.gib(sizeGiB)))
    }

    func deleteDisk(_ name: String) async -> Bool {
        guard let client else { return false }
        return await runDiskCommand(String(localized: "ディスク「\(name)」の削除"), client.deleteDisk(name))
    }

    private func runDiskCommand(_ title: String, _ stream: AsyncThrowingStream<LogEntry, Error>) async -> Bool {
        isDiskBusy = true
        defer { isDiskBusy = false }
        do {
            for try await _ in stream {}
            await refresh()
            return true
        } catch {
            alert = AlertMessage(title: String(localized: "\(title)に失敗しました"), message: error.localizedDescription)
            await refresh()
            return false
        }
    }

    func reloadNetworks() {
        networks = LimaNetworks.load()
    }

    func clearOperation(_ name: String) {
        if operations[name]?.isRunning == false { operations[name] = nil }
    }

    /// Runs a limactl command for `name`, showing its progress. `keepBusy` leaves the operation
    /// running (and skips the refresh) for a `completion` that has more to do and ends it.
    func run(_ kind: Operation.Kind, on name: String,
                     _ stream: AsyncThrowingStream<LogEntry, Error>,
                     keepBusy: Bool = false,
                     completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !isBusy(name) else { return }
        operations[name] = Operation(kind: kind)
        if [.start, .restart, .stop, .delete].contains(kind) { readyInstances.remove(name) }
        Task {
            var ok = true
            var monitor: Task<Void, Never>?
            defer { monitor?.cancel() }
            do {
                for try await entry in stream {
                    appendLog(entry, to: name)
                    // Lima logs "Attempting to download the image" (with the URL), then prints
                    // "Downloading the image (<file>)", so other output doesn't mean it's done:
                    // the monitor ends by itself when the temp file is renamed into place.
                    if entry.message.hasPrefix("Attempting to download"), let location = entry.fields["location"] {
                        monitor?.cancel()
                        operations[name]?.download = nil
                        monitor = monitorDownload(location, for: name)
                    }
                    // Status flips (Installing → Running etc.) happen mid-command.
                    if kind != .delete { scheduleRefresh() }
                }
            } catch {
                ok = false
                operations[name]?.error = error.localizedDescription
                alert = AlertMessage(title: String(localized: "\(name) の\(kind.label)に失敗しました"),
                                     message: error.localizedDescription)
            }
            monitor?.cancel()
            operations[name]?.download = nil
            if keepBusy && ok {
                completion?(ok)
                return
            }
            operations[name]?.isRunning = false
            // `limactl start` only returns after the instance reports READY.
            if ok && (kind == .start || kind == .restart) {
                readyInstances.insert(name)
                restartNeeded[name] = nil
            }
            await refresh()
            completion?(ok)
        }
    }

    private func monitorDownload(_ location: String, for name: String) -> Task<Void, Never> {
        Task {
            for await progress in DownloadMonitor.progress(for: location) {
                guard !Task.isCancelled else { return }
                operations[name]?.download = progress
            }
            if !Task.isCancelled { operations[name]?.download = nil }
        }
    }

    private func appendLog(_ entry: LogEntry, to name: String) {
        guard operations[name] != nil else { return }
        operations[name]!.log.append(entry)
        let overflow = operations[name]!.log.count - Self.maxLogLines
        if overflow > 0 { operations[name]!.log.removeFirst(overflow) }
    }
}
