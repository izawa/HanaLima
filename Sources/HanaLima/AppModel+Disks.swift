import AppKit
import Foundation
import LimaKit

/// Moving a VM's disk to another volume (an external drive) and back. See `ExternalDisk`.
extension AppModel {
    func diskPlacement(of instance: LimaInstance) -> DiskPlacement {
        diskPlacements[instance.name] ?? Self.placement(of: instance)
    }

    private static func placement(of instance: LimaInstance) -> DiskPlacement {
        ExternalDisk.placement(instanceDir: URL(filePath: instance.dir, directoryHint: .isDirectory))
    }

    /// Re-reads where each disk is; assigns only on a change, so views redraw just then.
    func updateDiskPlacements() {
        let current = Dictionary(uniqueKeysWithValues: instances.map { ($0.name, Self.placement(of: $0)) })
        if current != diskPlacements { diskPlacements = current }
        var shared: [String: String] = [:]
        for inst in instances where current[inst.name]?.externalURL != nil {
            let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
            ExternalDisk.claimIfOrphaned(instanceDir: dir, name: inst.name)
            if let owner = ExternalDisk.owner(sharingWith: dir) {
                shared[inst.name] = instances.first { ExternalDisk.samePath(URL(filePath: $0.dir), owner) }?.name ?? owner.lastPathComponent
            }
        }
        if shared != sharedDiskOwners { sharedDiskOwners = shared }
    }

    /// Plugging a drive in or out changes no Lima state, so listen for it directly.
    func observeVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDiskPlacements() }
            })
        }
    }

    /// Space the disk takes now (follows a link to a moved disk).
    func diskAllocatedSize(of instance: LimaInstance) -> Int64 {
        let disk = ExternalDisk.diskURL(instanceDir: URL(filePath: instance.dir))
        return StorageReport.allocatedSize(of: disk.resolvingSymlinksInPath())
    }

    /// A VM whose disk is on a drive that isn't connected can't start; say so instead of letting
    /// Lima fail with a file error. Nor can one that shares another VM's disk: it would write it.
    func refuseIfDiskUnusable(_ name: String) -> Bool {
        if let owner = sharedDiskOwners[name] {
            alert = AlertMessage(title: String(localized: "「\(name)」は「\(owner)」とディスクを共有しています"),
                                 message: String(localized: "このまま起動すると「\(owner)」のディスクを書き換えてしまいます。「設定」タブの「ディスクを独立させる」で、この仮想マシン専用のディスクを作ってから起動してください。"))
            return true
        }
        guard let inst = instance(named: name), case .missing(let url) = diskPlacement(of: inst) else { return false }
        alert = AlertMessage(title: String(localized: "「\(name)」のディスクが見つかりません"),
                             message: String(localized: "ディスクの保存先 \(url.deletingLastPathComponent().path) が見つかりません。外付けドライブを接続してから、もう一度起動してください。"))
        return true
    }

    /// Moves `name`'s disk to `folder` (`<folder>/HanaLima Disks/<name>/disk`), then starts the VM
    /// if asked. The VM must be stopped.
    func moveDisk(_ name: String, to folder: URL, thenStart: Bool = false) {
        guard let inst = instance(named: name), !inst.isRunning, !isBusy(name), !hasDiskSnapshots(inst) else { return }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        let target = ExternalDisk.target(in: folder, name: name)
        runFileOperation(.moveDisk, name: name) { progress in
            try await ExternalDisk.moveOut(instanceDir: dir, name: name, to: target, progress: progress)
        } completion: { [weak self] ok in
            if ok && thenStart { self?.start(name) }
        }
    }

    func moveDiskBack(_ name: String) {
        guard let inst = instance(named: name), !inst.isRunning, !isBusy(name), !hasDiskSnapshots(inst) else { return }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        runFileOperation(.moveDiskBack, name: name) { progress in
            try await ExternalDisk.moveBack(instanceDir: dir, progress: progress)
        } completion: { _ in }
    }

    /// Gives a VM that shares another's moved disk its own copy on the same drive.
    func separateDisk(_ name: String) {
        guard let inst = instance(named: name), !inst.isRunning, !isBusy(name) else { return }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        runFileOperation(.separateDisk, name: name) { progress in
            try await ExternalDisk.separate(instanceDir: dir, name: name, progress: progress)
        } completion: { _ in }
    }

    func cancelDiskMove(_ name: String) {
        diskMoveTasks[name]?.cancel()
    }

    /// Runs file work on a stopped VM as its operation: busy meanwhile, errors shown, the list
    /// refreshed afterwards. With `showsProgress`, a progress bar and Cancel are shown.
    func runFileOperation(_ kind: Operation.Kind, name: String, showsProgress: Bool = true,
                             _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void,
                             completion: @escaping @MainActor (Bool) -> Void) {
        var op = Operation(kind: kind)
        if showsProgress { op.fraction = 0 }
        operations[name] = op
        diskMoveTasks[name] = Task {
            var ok = true
            do {
                try await work { fraction in
                    guard showsProgress else { return }
                    Task { @MainActor in self.operations[name]?.fraction = fraction }
                }
            } catch is CancellationError {
                ok = false
                operations[name] = nil  // nothing changed; no error to show
            } catch {
                ok = false
                operations[name]?.error = error.localizedDescription
                alert = AlertMessage(title: String(localized: "\(name) の\(kind.label)に失敗しました"),
                                     message: error.localizedDescription)
            }
            if ok { operations[name] = nil } else { operations[name]?.isRunning = false }
            diskMoveTasks[name] = nil
            await refresh()
            if storage != nil { await measureStorage() }
            completion(ok)
        }
    }

    /// After `limactl delete` (which removes only the link): delete the moved disk too, or say
    /// where it was left when the drive is away.
    func cleanUpExternalDisk(after name: String, placement: DiskPlacement, instanceDir: URL) {
        switch placement {
        case .local:
            break
        case .external(let url):
            if !ExternalDisk.removeExternalFolder(of: url, for: instanceDir) {
                alert = AlertMessage(title: String(localized: "外部のディスクを削除できませんでした"),
                                     message: String(localized: "\(url.deletingLastPathComponent().path) を手作業で削除してください。"))
            }
        case .missing(let url):
            alert = AlertMessage(title: String(localized: "外部のディスクは残っています"),
                                 message: String(localized: "ドライブが接続されていなかったため、\(url.deletingLastPathComponent().path) は削除していません。ドライブを接続して、手作業で削除してください。"))
        }
    }
}
