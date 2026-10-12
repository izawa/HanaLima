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
    /// Lima fail with a file error.
    func refuseIfDiskMissing(_ name: String) -> Bool {
        guard let inst = instance(named: name), case .missing(let url) = diskPlacement(of: inst) else { return false }
        alert = AlertMessage(title: String(localized: "「\(name)」のディスクが見つかりません"),
                             message: String(localized: "ディスクの保存先 \(url.deletingLastPathComponent().path) が見つかりません。外付けドライブを接続してから、もう一度起動してください。"))
        return true
    }

    /// Moves `name`'s disk to `folder` (`<folder>/HanaLima Disks/<name>/disk`), then starts the VM
    /// if asked. The VM must be stopped.
    func moveDisk(_ name: String, to folder: URL, thenStart: Bool = false) {
        guard let inst = instance(named: name), !inst.isRunning, !isBusy(name) else { return }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        let target = ExternalDisk.target(in: folder, name: name)
        runDiskMove(.moveDisk, name: name) { progress in
            try await ExternalDisk.moveOut(instanceDir: dir, name: name, to: target, progress: progress)
        } completion: { [weak self] ok in
            if ok && thenStart { self?.start(name) }
        }
    }

    func moveDiskBack(_ name: String) {
        guard let inst = instance(named: name), !inst.isRunning, !isBusy(name) else { return }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        runDiskMove(.moveDiskBack, name: name) { progress in
            try await ExternalDisk.moveBack(instanceDir: dir, progress: progress)
        } completion: { _ in }
    }

    func cancelDiskMove(_ name: String) {
        diskMoveTasks[name]?.cancel()
    }

    private func runDiskMove(_ kind: Operation.Kind, name: String,
                             _ work: @escaping @Sendable (@escaping @Sendable (Double) -> Void) async throws -> Void,
                             completion: @escaping @MainActor (Bool) -> Void) {
        var op = Operation(kind: kind)
        op.fraction = 0
        operations[name] = op
        diskMoveTasks[name] = Task {
            var ok = true
            do {
                try await work { fraction in
                    Task { @MainActor [weak self] in self?.operations[name]?.fraction = fraction }
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
    func cleanUpExternalDisk(after name: String, placement: DiskPlacement) {
        switch placement {
        case .local:
            break
        case .external(let url):
            if !ExternalDisk.removeExternalFolder(of: url) {
                alert = AlertMessage(title: String(localized: "外部のディスクを削除できませんでした"),
                                     message: String(localized: "\(url.deletingLastPathComponent().path) を手作業で削除してください。"))
            }
        case .missing(let url):
            alert = AlertMessage(title: String(localized: "外部のディスクは残っています"),
                                 message: String(localized: "ドライブが接続されていなかったため、\(url.deletingLastPathComponent().path) は削除していません。ドライブを接続して、手作業で削除してください。"))
        }
    }
}
