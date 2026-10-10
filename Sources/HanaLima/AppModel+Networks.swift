import Foundation
import LimaKit
import NetworkKit

/// Management of HanaLima virtual networks: networks.json, the LaunchAgents and the helper.
extension AppModel {
    /// The helper bundled in the app (Contents/Helpers/hanalima-netd).
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL.appending(path: "Contents/Helpers/hanalima-netd")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// Loads networks.json, installs/updates the helper copy and re-registers any network whose
    /// LaunchAgent is missing (e.g. after the user cleaned ~/Library/LaunchAgents).
    func setUpVirtualNetworks() async {
        do {
            virtualNetworks = try NetworkStore.load()
        } catch {
            alert = AlertMessage(title: String(localized: "ネットワーク設定を読み込めませんでした"), message: error.localizedDescription)
            return
        }
        let networks = virtualNetworks
        let helper = Self.bundledHelper
        let problems: [String] = await Task.detached {
            var problems: [String] = []
            if let helper {
                do { try HelperInstaller.installIfNeeded(from: helper) }
                catch { problems.append(String(localized: "ヘルパーの配置に失敗しました: \(error.localizedDescription)")) }
            }
            let agents = LaunchAgentManager()
            for n in networks where !agents.isInstalled(n.name) {
                do { try agents.install(n) }
                catch { problems.append("\(n.name): \(error.localizedDescription)") }
            }
            agents.upgradeIdleAgents(networks)
            HelperInstaller.removeUnusedCopies(agents: agents)
            return problems
        }.value
        if !problems.isEmpty {
            alert = AlertMessage(title: String(localized: "仮想ネットワークの準備で問題が発生しました"), message: problems.joined(separator: "\n"))
        }
        await refreshNetworkStates()
    }

    func refreshNetworkStates() async {
        let leases = await Task.detached { DHCPLeases.load() }.value
        if leases != dhcpLeases { dhcpLeases = leases }
        let networks = virtualNetworks
        let names = networks.map(\.name)
        guard !names.isEmpty else {
            if !networkStates.isEmpty { networkStates = [:] }
            return
        }
        let (states, statuses) = await Task.detached {
            let agents = LaunchAgentManager()
            // Agents still on an older helper move to the current one once their helper exits.
            if !agents.upgradeIdleAgents(networks).isEmpty { HelperInstaller.removeUnusedCopies(agents: agents) }
            var states: [String: LaunchAgentManager.State] = [:]
            var statuses: [String: NetworkDaemonStatus] = [:]
            for name in names {
                states[name] = agents.state(of: name)
                if case .running = states[name], let st = NetworkDaemonStatus.load(for: name) { statuses[name] = st }
            }
            return (states, statuses)
        }.value
        if states != networkStates { networkStates = states }
        if statuses != networkStatuses { networkStatuses = statuses }
    }

    func virtualNetwork(forSocket path: String) -> VirtualNetwork? {
        virtualNetworks.first { $0.socketPath == path }
    }

    /// MAC address of `instance`'s NIC on `network` (Lima fills one in if lima.yaml has none).
    func macAddress(of instance: LimaInstance, on network: VirtualNetwork) -> String? {
        (instance.networks ?? []).first { $0.socket == network.socketPath }?.macAddress
            .flatMap(DHCPReservation.normalizedMAC)
    }

    /// The reservation for `instance` on `network`, if any.
    func reservation(of instance: LimaInstance, on network: VirtualNetwork) -> DHCPReservation? {
        guard let mac = macAddress(of: instance, on: network) else { return nil }
        return network.reservations.first { DHCPReservation.normalizedMAC($0.mac) == mac }
    }

    /// The VM's current address on `network`, from the DHCP leases.
    func address(of instance: LimaInstance, on network: VirtualNetwork) -> String? {
        guard let subnet = network.subnet else { return nil }
        return DHCPLeases.address(of: instance.name, in: subnet, leases: dhcpLeases)
    }

    /// Instances whose config attaches to `network` (running or not).
    func instances(using network: VirtualNetwork) -> [LimaInstance] {
        instances.filter { inst in
            (inst.networks ?? []).contains { $0.socket == network.socketPath }
        }
    }

    /// Adds or updates a network and (re)registers its LaunchAgent. Returns an error message on
    /// failure, after putting the previous network back (file and agent), so nothing is half-saved.
    func saveVirtualNetwork(_ network: VirtualNetwork) async -> String? {
        guard Self.bundledHelper != nil || FileManager.default.isExecutableFile(atPath: NetworkPaths.installedHelper.path) else {
            return String(localized: "hanalima-netd がアプリに同梱されていません。scripts/build-app.sh でビルドした HanaLima.app から起動してください。")
        }
        let before = virtualNetworks
        let previous = before.first { $0.name == network.name }
        var updated = before.filter { $0.name != network.name }
        updated.append(network)
        updated.sort { $0.name < $1.name }
        do {
            try NetworkStore.save(updated)
            if let helper = Self.bundledHelper { try HelperInstaller.installIfNeeded(from: helper) }
            try await Task.detached { try LaunchAgentManager().install(network) }.value
            virtualNetworks = updated
        } catch {
            try? NetworkStore.save(before)
            if let previous {
                _ = try? await Task.detached { try LaunchAgentManager().install(previous) }.value
            } else {
                await Task.detached { LaunchAgentManager().uninstall(network.name) }.value
            }
            virtualNetworks = before
            await refreshNetworkStates()
            return error.localizedDescription
        }
        // The helper restarts with the new settings; running VMs keep a dead link until restarted.
        if let previous, previous != network { markRestartNeeded(using: previous) }
        await refreshNetworkStates()
        return nil
    }

    func deleteVirtualNetwork(_ name: String) async {
        if let network = virtualNetworks.first(where: { $0.name == name }) { markRestartNeeded(using: network) }
        let remaining = virtualNetworks.filter { $0.name != name }
        do {
            try NetworkStore.save(remaining)
        } catch {
            alert = AlertMessage(title: String(localized: "ネットワーク「\(name)」を削除できませんでした"), message: error.localizedDescription)
            return
        }
        await Task.detached { LaunchAgentManager().uninstall(name) }.value
        virtualNetworks = remaining
        networkStates[name] = nil
        networkStatuses[name] = nil
    }

    // MARK: - After a network changes

    private func markRestartNeeded(using network: VirtualNetwork) {
        for inst in instances(using: network) where inst.isRunning {
            restartNeeded[inst.name, default: []].insert(network.name)
        }
    }

    /// NICs (socket paths) that point at a HanaLima network that no longer exists.
    func deletedNetworkSockets(of instance: LimaInstance) -> [String] {
        (instance.networks ?? []).compactMap(\.socket).filter(isDeletedNetworkSocket)
    }

    func isDeletedNetworkSocket(_ path: String) -> Bool {
        path.hasPrefix(NetworkPaths.socketDirectory.path + "/") && virtualNetwork(forSocket: path) == nil
    }

    /// 「demo」、「lan」 / “demo”, “lan”
    static func quotedNames(_ names: [String]) -> String {
        names.map { String(localized: "「\($0)」") }.joined(separator: String(localized: "list-separator", defaultValue: "、"))
    }

    /// "demo" for `…/HanaLima/net/demo.sock`.
    static func networkName(ofSocket path: String) -> String {
        URL(filePath: path).deletingPathExtension().lastPathComponent
    }

    /// Returns true (and asks the user) if `name` would fail to start on a deleted network.
    func askIfDeletedNetworks(_ name: String, restart: Bool) -> Bool {
        guard let inst = instance(named: name) else { return false }
        let names = deletedNetworkSockets(of: inst).map(Self.networkName(ofSocket:))
        guard !names.isEmpty else { return false }
        let list = Self.quotedNames(names)
        pendingDeletedNetworkStart = ConflictPrompt(
            name: name, restart: restart,
            message: String(localized: "\(name) の NIC が、削除したネットワーク \(list) を指しています。このままでは起動できません。その NIC を設定から外して起動しますか？"))
        return true
    }

    /// Removes the NICs that point at deleted networks, then (if asked) starts the VM again.
    /// `limactl edit` needs the VM stopped, so a running one is stopped first.
    func removeDeletedNICs(_ name: String, thenStart: Bool) {
        guard let client, let inst = instance(named: name) else { return }
        let paths = deletedNetworkSockets(of: inst)
        guard !paths.isEmpty else { return }
        let keep = paths.map { #".socket != "\#($0)""# }.joined(separator: " and ")
        let expression = ".networks |= map(select(\(keep)))"
        var steps: [@Sendable () -> AsyncThrowingStream<LogEntry, Error>] = []
        if inst.isRunning { steps.append { client.stop(name) } }
        steps.append { client.edit(name, set: [expression]) }
        if thenStart { steps.append { client.start(name) } }
        let kind: Operation.Kind = thenStart ? (inst.isRunning ? .restart : .start) : .edit
        run(kind, on: name, Self.sequence(steps))
    }

    /// Runs the streams one after another as one operation; stops at the first failure.
    static func sequence(_ steps: [@Sendable () -> AsyncThrowingStream<LogEntry, Error>]) -> AsyncThrowingStream<LogEntry, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        for try await entry in step() { continuation.yield(entry) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Conflicts between socket_vmnet and HanaLima networks

    /// Classifies a NIC for `NetworkConflict`.
    func conflictAttachment(lima: String?, socket: String?) -> NetworkConflict.Attachment {
        if let lima, !lima.isEmpty {
            // user-v2 is Lima's own user-mode network, not vmnet.
            if networks.network(named: lima)?.needsSocketVMNet ?? (lima != "user-v2") { return .legacyVmnet(lima) }
            return .other
        }
        // hanalima-netd's bridged networks use the legacy API like socket_vmnet, but netd never
        // reuses a vmnet_network, and both mixes were tested on real VMs (docs/02).
        if let socket, let vn = virtualNetwork(forSocket: socket), !vn.isBridged { return .virtualNetwork(vn.name) }
        return .other
    }

    func conflictAttachments(of instance: LimaInstance) -> [NetworkConflict.Attachment] {
        (instance.networks ?? []).map { conflictAttachment(lima: $0.lima, socket: $0.socket) }
    }

    /// The conflict starting `name` would cause with the VMs currently running, if any.
    func networkConflict(starting name: String) -> NetworkConflict.Conflict? {
        guard let inst = instance(named: name) else { return nil }
        let running = instances.filter { $0.isRunning && $0.name != name }
            .map { (name: $0.name, attachments: conflictAttachments(of: $0)) }
        return NetworkConflict.check(vm: name, attachments: conflictAttachments(of: inst), running: running)
    }
}
