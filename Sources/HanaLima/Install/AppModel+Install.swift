import Foundation
import LimaKit

extension AppModel {
    /// The isolation preset's second step: a VM created with usernet for its first boot (so the
    /// guest could install the vsock SSH relay) has stopped, so usernet comes off now and the
    /// next start is isolated.
    func applyPendingIsolation() {
        for inst in instances where metadata[inst.name]?.pendingIsolation == true && inst.status == .stopped && !isBusy(inst.name) {
            let name = inst.name
            edit(name, set: [".vmOpts.hanalima.usernet = false"]) { [weak self] ok in
                guard let self, ok, var meta = self.metadata[name] else { return }
                meta.pendingIsolation = nil
                try? meta.save()
                self.metadata[name] = meta
            }
        }
    }

    /// A hosted boot (installer or rescue) left running by a previous run of the app: the
    /// driver's process is still there, so show it as a session again rather than start another.
    func reattachHostedBoots() {
        for inst in instances where installSession?.name != inst.name && rescueSession?.name != inst.name {
            let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
            guard let hosted = HostedProcess.attach(instanceDir: dir) else { continue }
            let cpus = inst.cpus ?? 2, memory = UInt64(inst.memory ?? 4 << 30)
            if let pending = pendingInstall(inst.name), installSession == nil {
                installSession = InstallSession(name: inst.name, instanceDir: dir, iso: pending.isoURL, cpus: cpus, memoryBytes: memory, attached: hosted)
                operations[inst.name] = Operation(kind: .install)
                watchHosted(hosted, name: inst.name) { [weak self] in self?.installSessionChanged() }
            } else if rescueSession == nil {
                rescueSession = RescueSession(name: inst.name, instanceDir: dir, cpus: cpus, memoryBytes: memory, attached: hosted)
                operations[inst.name] = Operation(kind: .rescue)
                watchHosted(hosted, name: inst.name) { [weak self] in self?.rescueSessionChanged() }
            }
        }
    }
}
