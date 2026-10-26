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
            let vm = try InstallerVM(instanceDir: dir, options: .init(headless: true), cpus: 1, memoryBytes: 1 << 30)
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

    /// `HANALIMA_E2E_AUTOINSTALL=<instance>` with `HANALIMA_E2E_AUTOINSTALL_ISO`, `_BOOT` (the FAT
    /// boot image) and `_SEED`: runs the unattended install headless and exits 0 once the guest
    /// has powered off, 1 on failure (see ISOInstallEndToEndTests).
    func e2eAutoinstall(_ name: String) async {
        let env = ProcessInfo.processInfo.environment
        while instance(named: name) == nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let inst = instance(named: name),
              let iso = env["HANALIMA_E2E_AUTOINSTALL_ISO"], let boot = env["HANALIMA_E2E_AUTOINSTALL_BOOT"],
              let seed = env["HANALIMA_E2E_AUTOINSTALL_SEED"] else { print("autoinstall: missing environment"); exit(2) }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        do {
            let vm = try InstallerVM(instanceDir: dir,
                                     options: .init(iso: URL(filePath: iso), bootImage: URL(filePath: boot),
                                                    seed: URL(filePath: seed), headless: true),
                                     cpus: inst.cpus ?? 2, memoryBytes: UInt64(inst.memory ?? 4 << 30))
            vm.start()
            while vm.state == .starting || vm.state == .running { try? await Task.sleep(for: .seconds(2)) }
            print("autoinstall: \(vm.state)")
            exit(vm.state == .stopped ? 0 : 1)
        } catch {
            print("autoinstall: configuration failed: \(error)")
            exit(1)
        }
    }
    #endif
}
