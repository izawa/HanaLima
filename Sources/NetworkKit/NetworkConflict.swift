import Foundation

/// Detects VMs that would use socket_vmnet networks and HanaLima virtual networks at the same time.
///
/// On macOS 27.0.1, a vmnet_network that is *reused* after its interface stopped takes over a
/// legacy (socket_vmnet) bridge's bridge100, detaches en0 and removes the host's IPv4 address
/// (FB25122122). hanalima-netd never reuses networks (it releases them when idle), and real-VM
/// tests of every start/restart order passed, so the app only warns: other tools or older
/// HanaLima helpers could still reuse networks. See docs/02-networking-investigation.md.
public enum NetworkConflict {
    public enum Attachment: Hashable, Sendable {
        /// socket_vmnet (legacy vmnet API): lima:shared, lima:host, lima:bridged.
        case legacyVmnet(String)
        /// A HanaLima virtual network.
        case virtualNetwork(String)
        /// Anything else (user-mode, user-v2, vzNAT, unknown sockets).
        case other
    }

    public struct Conflict: Sendable, Equatable {
        /// The VM whose start would conflict.
        public var vm: String
        /// Legacy socket_vmnet networks involved.
        public var legacyNetworks: [String]
        /// HanaLima virtual networks involved.
        public var virtualNetworks: [String]
        /// Running VMs that contribute to the conflict (empty if the VM conflicts with itself).
        public var runningVMs: [String]

        public var message: String {
            let legacy = legacyNetworks.map { "lima:\($0)" }.joined(separator: ", ")
            let virtual = virtualNetworks.joined(separator: ", ")
            let who = runningVMs.isEmpty ? "「\(vm)」自身の NIC で" : "実行中の VM（\(runningVMs.joined(separator: ", "))）と"
            return "\(who)、socket_vmnet のネットワーク（\(legacy)）と HanaLima の仮想ネットワーク（\(virtual)）が同時に使われます。HanaLima はこの組み合わせで動作を確認していますが、macOS の不具合（FB25122122）により、ほかの仮想化ツールが vmnet のネットワークを使い回すと、ブリッジの通信や Mac 本体の IPv4 接続が切れることがあります。その場合は VM を止めて、システム設定で DHCP リースを更新するか Mac を再起動してください。"
        }
    }

    /// Checks whether starting `vm` with `attachments` alongside the `running` VMs mixes the two
    /// kinds of vmnet networks.
    public static func check(vm: String, attachments: [Attachment],
                             running: [(name: String, attachments: [Attachment])]) -> Conflict? {
        func legacy(_ a: [Attachment]) -> [String] {
            a.compactMap { if case .legacyVmnet(let n) = $0 { n } else { nil } }
        }
        func virtual(_ a: [Attachment]) -> [String] {
            a.compactMap { if case .virtualNetwork(let n) = $0 { n } else { nil } }
        }
        let others = running.filter { $0.name != vm }
        let mine = (legacy: legacy(attachments), virtual: virtual(attachments))
        if !mine.legacy.isEmpty && !mine.virtual.isEmpty {
            return Conflict(vm: vm, legacyNetworks: unique(mine.legacy), virtualNetworks: unique(mine.virtual),
                            runningVMs: [])
        }
        if !mine.legacy.isEmpty {
            let culprits = others.filter { !virtual($0.attachments).isEmpty }
            if !culprits.isEmpty {
                return Conflict(vm: vm, legacyNetworks: unique(mine.legacy),
                                virtualNetworks: unique(culprits.flatMap { virtual($0.attachments) }),
                                runningVMs: culprits.map(\.name))
            }
        }
        if !mine.virtual.isEmpty {
            let culprits = others.filter { !legacy($0.attachments).isEmpty }
            if !culprits.isEmpty {
                return Conflict(vm: vm, legacyNetworks: unique(culprits.flatMap { legacy($0.attachments) }),
                                virtualNetworks: unique(mine.virtual), runningVMs: culprits.map(\.name))
            }
        }
        return nil
    }

    private static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }
}
