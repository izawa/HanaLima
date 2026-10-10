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
            alert = AlertMessage(title: "ネットワーク設定を読み込めませんでした", message: error.localizedDescription)
            return
        }
        let networks = virtualNetworks
        let helper = Self.bundledHelper
        let problems: [String] = await Task.detached {
            var problems: [String] = []
            if let helper {
                do { try HelperInstaller.installIfNeeded(from: helper) }
                catch { problems.append("ヘルパーの配置に失敗しました: \(error.localizedDescription)") }
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
            alert = AlertMessage(title: "仮想ネットワークの準備で問題が発生しました", message: problems.joined(separator: "\n"))
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

    /// Adds or updates a network and (re)registers its LaunchAgent. Returns false on failure.
    @discardableResult
    func saveVirtualNetwork(_ network: VirtualNetwork) async -> Bool {
        guard Self.bundledHelper != nil || FileManager.default.isExecutableFile(atPath: NetworkPaths.installedHelper.path) else {
            alert = AlertMessage(title: "ヘルパーが見つかりません",
                                 message: "hanalima-netd がアプリに同梱されていません。scripts/build-app.sh でビルドした HanaLima.app から起動してください。")
            return false
        }
        var updated = virtualNetworks.filter { $0.name != network.name }
        updated.append(network)
        updated.sort { $0.name < $1.name }
        do {
            try NetworkStore.save(updated)
            if let helper = Self.bundledHelper { try HelperInstaller.installIfNeeded(from: helper) }
            try await Task.detached { try LaunchAgentManager().install(network) }.value
            virtualNetworks = updated
        } catch {
            alert = AlertMessage(title: "ネットワーク「\(network.name)」を保存できませんでした", message: error.localizedDescription)
            virtualNetworks = (try? NetworkStore.load()) ?? virtualNetworks
            return false
        }
        await refreshNetworkStates()
        return true
    }

    func deleteVirtualNetwork(_ name: String) async {
        let remaining = virtualNetworks.filter { $0.name != name }
        do {
            try NetworkStore.save(remaining)
        } catch {
            alert = AlertMessage(title: "ネットワーク「\(name)」を削除できませんでした", message: error.localizedDescription)
            return
        }
        await Task.detached { LaunchAgentManager().uninstall(name) }.value
        virtualNetworks = remaining
        networkStates[name] = nil
        networkStatuses[name] = nil
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
