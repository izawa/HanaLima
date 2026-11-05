import Foundation
import LimaKit

extension AppModel {
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
