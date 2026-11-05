import Foundation
import LimaKit

extension AppModel {
    /// Why `name` can't be rescue-booted now, or nil. The VM must be a stopped Linux VZ instance
    /// whose disk is its own and present (the rescue writes it).
    func rescueBlocker(_ name: String) -> String? {
        guard let inst = instance(named: name) else { return String(localized: "まだ作成中です。") }
        if inst.vmType != "vz" { return String(localized: "救出起動は VZ の仮想マシンだけで使えます。") }
        if inst.config?["os"]?.stringValue == "Darwin" { return String(localized: "macOS のゲストは救出起動できません。") }
        if inst.isRunning { return String(localized: "停止してから救出起動してください。") }
        if isBusy(name) { return String(localized: "操作中です。") }
        if pendingInstall(name) != nil { return String(localized: "OS のインストールが終わると使えます。") }
        if let owner = sharedDiskOwners[name] { return String(localized: "「\(owner)」とディスクを共有しているため起動できません。") }
        if case .missing = diskPlacement(of: inst) { return String(localized: "ディスクの保存先が見つかりません。") }
        if let session = rescueSession, session.isRunning, session.name != name {
            return String(localized: "「\(session.name)」を救出起動中です。")
        }
        return nil
    }

    /// Opens (or reuses) the rescue session for `name`; the window shows it.
    func beginRescue(_ name: String) -> RescueSession? {
        if let session = rescueSession, session.name == name { return session }
        if let blocker = rescueBlocker(name) {
            alert = AlertMessage(title: String(localized: "「\(name)」を救出起動できません"), message: blocker)
            return nil
        }
        guard let inst = instance(named: name) else { return nil }
        let session = RescueSession(name: name, instanceDir: URL(filePath: inst.dir, directoryHint: .isDirectory),
                                    cpus: inst.cpus ?? 2, memoryBytes: UInt64(inst.memory ?? 4 << 30))
        rescueSession = session
        return session
    }

    /// While the rescue VM runs, the VM counts as busy (no start, copy, delete, disk moves).
    func rescueSessionChanged() {
        guard let session = rescueSession else { return }
        if session.isRunning {
            if operations[session.name]?.kind != .rescue { operations[session.name] = Operation(kind: .rescue) }
        } else if operations[session.name]?.kind == .rescue {
            operations[session.name] = nil
        }
    }

    func closeRescueSession() {
        guard let session = rescueSession else { return }
        rescueSession = nil
        if operations[session.name]?.kind == .rescue { operations[session.name] = nil }
        guard session.isRunning else { return }
        session.stop(force: true)
        closingRescueSessions.append(session)
        Task {
            while session.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
            closingRescueSessions.removeAll { $0 === session }
        }
    }

    #if DEBUG
    /// `HANALIMA_E2E_RESCUE=<instance>`: boots the instance headless the way the rescue window
    /// does, waits until the guest is up (a login prompt on the serial console, which Alpine
    /// doesn't print, or a DHCP lease for Lima's MAC from VZ's NAT in `/var/db/dhcpd_leases`), or
    /// `HANALIMA_E2E_RESCUE_SECONDS` (default 180), asks the guest to power off (pulls the plug
    /// after 30 s) and exits 0; 1 on failure (see RescueEndToEndTests).
    func e2eRescue(_ name: String) async {
        let env = ProcessInfo.processInfo.environment
        while instance(named: name) == nil { try? await Task.sleep(for: .milliseconds(200)) }
        guard let inst = instance(named: name) else { exit(2) }
        if let blocker = rescueBlocker(name) { print("rescue: \(blocker)"); exit(1) }
        let dir = URL(filePath: inst.dir, directoryHint: .isDirectory)
        let log = dir.appending(path: RescueSession.serialLog)
        let limit = Double(env["HANALIMA_E2E_RESCUE_SECONDS"] ?? "") ?? 180
        do {
            let vm = try HostedVM(instanceDir: dir, options: RescueSession.options(instanceDir: dir, headless: true),
                                  cpus: inst.cpus ?? 2, memoryBytes: UInt64(inst.memory ?? 4 << 30))
            vm.start()
            let started = Date.now
            // bootpd writes hex bytes without padding ("0:1"), and the DUID form ends with the MAC.
            let leases = URL(filePath: "/var/db/dhcpd_leases")
            let mac = LimaMACAddress.address(instanceDir: dir)?.split(separator: ":")
                .map { String(Int($0, radix: 16) ?? 0, radix: 16) }.joined(separator: ":") ?? "-"
            var up = ""
            while vm.state == .starting || vm.state == .running {
                try? await Task.sleep(for: .seconds(2))
                if let text = try? String(contentsOf: log, encoding: .utf8), text.contains("login:") { up = "login prompt"; break }
                if let modified = try? leases.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modified > started, let text = try? String(contentsOf: leases, encoding: .utf8), text.contains(mac) {
                    up = "DHCP lease for \(mac)"; break
                }
                if Date.now.timeIntervalSince(started) > limit { break }
            }
            print("rescue: \(up.isEmpty ? "not up after \(Int(limit)) s" : up), state \(vm.state)")
            let sawLogin = !up.isEmpty
            vm.stop()
            let stopping = Date.now
            while vm.state == .running {
                try? await Task.sleep(for: .seconds(1))
                if Date.now.timeIntervalSince(stopping) > 30 { vm.stop(force: true) }
            }
            exit(sawLogin && vm.state == .stopped ? 0 : 1)
        } catch {
            print("rescue: configuration failed: \(error)")
            exit(1)
        }
    }
    #endif
}
