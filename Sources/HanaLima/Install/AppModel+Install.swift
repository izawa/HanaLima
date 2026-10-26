import Foundation
import LimaKit

extension AppModel {
    #if DEBUG
    /// `HANALIMA_VZPROBE=<instance>`: boots the instance's disk with InstallerVM (no ISO) for a
    /// few seconds and exits. Proves the signed app can run Virtualization.framework in-process.
    /// A blank disk makes EFI give up at once, so the guest stops by itself.
    func vzProbe(_ name: String) async {
        while instance(named: name) == nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let inst = instance(named: name) else { return }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        do {
            let vm = try InstallerVM(instanceDir: dir, iso: nil, helper: nil, cpus: 1, memoryBytes: 1 << 30)
            vm.start()
            for _ in 0..<50 {
                try? await Task.sleep(for: .milliseconds(200))
                if vm.state != .starting && vm.state != .running { break }
            }
            print("vzprobe: \(vm.state)")
            if vm.state == .running { vm.stop(force: true) }
        } catch {
            print("vzprobe: configuration failed: \(error)")
        }
        exit(0)
    }
    #endif
}
