import CryptoKit
import Foundation
import LimaKit
import NetworkKit

public enum TopologyPlanner {
    public static func plan(_ spec: TopologySpec, facts: PlannerFacts) -> TopologyPlan {
        var result = TopologyPlan(networks: [], vms: [], group: spec.group, verifyOutside: spec.verifyOutside,
                                  filled: ["driver=hanalima", "shares=none"], assumptions: spec.assumptions,
                                  problems: declarationProblems(spec), approvals: [])
        func problem(_ code: String = "INVALID", _ path: String, _ message: String, _ alternative: String? = nil) {
            result.problems.append(.init(code: code, path: path, message: message, alternative: alternative))
        }
        if let group = spec.group, !validName(group, limit: 40) {
            problem("INVALID", "/group", "Group must start with a lowercase letter and contain 1–40 lowercase letters, digits or hyphens, with no trailing hyphen")
        }
        var vmNames = Set<String>(), networkNames = Set<String>()
        for (i, network) in spec.networks.enumerated() {
            if !validName(network.ref, limit: 24) {
                problem("INVALID", "/networks/\(i)/ref", "Network name must start with a lowercase letter and contain 1–24 lowercase letters, digits or hyphens, with no trailing hyphen")
            }
            if !networkNames.insert(network.ref).inserted { problem("INVALID", "/networks/\(i)/ref", "Duplicate network ref") }
        }
        for (i, vm) in spec.vms.enumerated() {
            let path = "/vms/\(i)"
            if !validName(vm.ref, limit: 76) || !CreateOptions.isValidName(vm.ref) {
                problem("INVALID", path + "/ref", "VM name must start with a lowercase letter and contain lowercase letters, digits and single hyphens, up to 76 characters")
            }
            if !vmNames.insert(vm.ref).inserted { problem("INVALID", path + "/ref", "Duplicate VM ref") }
            let existing = facts.vms.first { $0.name == vm.ref }
            if let existing, !existing.ownedByMCP {
                let taken = Set(facts.vms.map(\.name)).union(spec.vms.map(\.ref))
                problem("CONFLICT", path + "/ref", "name taken", freeName(vm.ref, avoiding: taken, limit: 76))
            }
            let action: TopologyPlan.Action = existing?.ownedByMCP == true ? .unchanged : .create
            let given = vm.template ?? spec.defaults.template ?? "default"
            var pinned = given
            if let template = facts.templates.first(where: { $0.name == given }) {
                if let image = template.resolvedImage, facts.templates.contains(where: { $0.name == image }) { pinned = image }
            } else if action == .create {
                let names = facts.templates.map(\.name).sorted {
                    let a = distance(given, $0), b = distance(given, $1)
                    return a == b ? $0 < $1 : a < b
                }
                problem("INVALID", path + "/template", "Unknown template: \(given)", names.prefix(5).joined(separator: ", "))
            }
            result.filled.append("template[\(vm.ref)]=\(pinned)")
            let usernet = vm.usernet ?? spec.defaults.usernet ?? true
            if action == .create {
                if !usernet && !facts.hasDriver {
                    problem("UNSUPPORTED", path + "/usernet", "Removing NIC 0 requires the HanaLima driver", "install the HanaLima driver or set usernet: true")
                }
                if !usernet && (given.lowercased().contains("alpine") || pinned.lowercased().contains("alpine")) && !vm.bootstrapUsernet {
                    problem("UNSUPPORTED", path + "/bootstrapUsernet",
                            "Alpine installs socat for vsock SSH over the network on its first boot",
                            "set bootstrapUsernet: true (first boot with NIC 0, then removed) or use ubuntu-26.04 (systemd 256+, no first boot needed)")
                }
                if usernet && vm.bootstrapUsernet { problem("INVALID", path + "/bootstrapUsernet", "bootstrapUsernet requires usernet: false") }
                if vm.gatewayAllow != nil && !usernet {
                    problem("UNSUPPORTED", path + "/gateway", "A gateway requires usernet for its way out in stage 2", "set usernet: true")
                }
            }
            var attached = Set<String>()
            let nics: [TopologyPlan.PlannedNIC] = vm.nics.enumerated().map { j, nic in
                let p = path + "/nics/\(j)"
                if !networkNames.contains(nic.network) { problem("INVALID", p + "/network", "Unknown network ref: \(nic.network)") }
                if !attached.insert(nic.network).inserted { problem("INVALID", p + "/network", "Duplicate NIC on the same network") }
                if let ip = nic.ip, IPv4(ip) == nil { problem("INVALID", p + "/ip", "Invalid IPv4 address") }
                return .init(network: nic.network, mac: mac(vm: vm.ref, network: nic.network),
                             ip: nic.ip.map { IPv4($0)?.description ?? $0 })
            }
            var expressions: [String] = []
            if !nics.isEmpty {
                let entries = nics.map { NetworkConfig(kind: .socket(VirtualNetwork(name: $0.network).socketPath), macAddress: $0.mac).json }
                expressions.append(".networks += " + LimaKit.JSONValue.array(entries).jsonText)
            }
            if !usernet && !vm.bootstrapUsernet { expressions.append(".vmOpts.hanalima.usernet = false") }
            if let allow = vm.gatewayAllow {
                let entries = ProvisionExamples.example(.gateway).entries.map { original in
                    var entry = original
                    if entry.mode == .data && entry.path == "/etc/hanalima/gateway.conf" {
                        entry.content = allow.joined(separator: "\n") + "\n"
                    }
                    return entry.json
                }
                expressions.append(".provision += " + LimaKit.JSONValue.array(entries).jsonText)
            }
            let memory = vm.memoryGiB ?? spec.defaults.memoryGiB
            let bytes = (memory ?? 4) * 1_073_741_824
            let memoryBytes = bytes.isFinite && bytes >= 0 && bytes < Double(Int64.max) ? Int64(bytes) : 0
            let options = CreateOptions(name: vm.ref, template: pinned, cpus: vm.cpus ?? spec.defaults.cpus,
                                        memoryGiB: memory, diskGiB: vm.diskGiB ?? spec.defaults.diskGiB,
                                        vmType: .hanalima, mountNone: true, setExpressions: expressions)
            result.vms.append(.init(action: action, name: vm.ref, options: options, template: pinned,
                                    bootstrapUsernet: vm.bootstrapUsernet, nics: nics, memoryBytes: memoryBytes))
        }
        let declaredSubnets = spec.networks.compactMap { IPv4Subnet(cidr: $0.cidr) }
        for (i, declaration) in spec.networks.enumerated() {
            let path = "/networks/\(i)"
            let existing = facts.networks.first { $0.name == declaration.ref }
            let owned = existing != nil && facts.ownedNetworks.contains(declaration.ref)
            if existing != nil && !owned {
                let taken = Set(facts.networks.map(\.name)).union(spec.networks.map(\.ref))
                problem("CONFLICT", path + "/ref", "name taken", freeName(declaration.ref, avoiding: taken, limit: 24))
            }
            guard let requestedSubnet = IPv4Subnet(cidr: declaration.cidr) else {
                problem("INVALID", path + "/cidr", "Invalid IPv4 CIDR")
                continue
            }
            guard VirtualNetwork.prefixLengths.contains(requestedSubnet.prefixLength) else {
                let address = declaration.cidr.split(separator: "/").first.flatMap { IPv4(String($0)) } ?? requestedSubnet.network
                let prefix = address.value & 0xffff != 0 || requestedSubnet.prefixLength >= 24 ? 24 : 16
                problem("UNSUPPORTED", path + "/cidr", "Prefix length must be /16 through /28",
                        IPv4Subnet(containing: address, prefixLength: prefix).description)
                continue
            }
            let subnet = owned ? (existing?.subnet ?? requestedSubnet) : requestedSubnet
            if !requestedSubnet.isPrivate { problem("INVALID", path + "/cidr", "Subnet must be private (RFC 1918)") }
            let others = facts.networks.filter { !(owned && $0.name == declaration.ref) }
            let overlaps = others.compactMap(\.subnet).contains { subnet.overlaps($0) }
                || VirtualNetwork.reservedSubnets.contains { subnet.overlaps($0.subnet) }
                || spec.networks.enumerated().contains { j, other in
                    j != i && IPv4Subnet(cidr: other.cidr).map { subnet.overlaps($0) } == true
                }
            if overlaps {
                problem("CONFLICT", path + "/cidr", "Subnet overlaps an existing, planned or reserved network",
                        freeSubnet(avoiding: facts.networks.compactMap(\.subnet) + declaredSubnets))
            }
            let nics = result.vms.flatMap { vm in vm.nics.filter { $0.network == declaration.ref }.map { (vm.name, $0) } }
            let used = Set(nics.compactMap { $0.1.ip.flatMap(IPv4.init) })
            var serverValue = subnet.broadcast.value - 1
            while serverValue > subnet.network.value && used.contains(IPv4(serverValue)) { serverValue -= 1 }
            guard serverValue > subnet.network.value else {
                problem("INVALID", path + "/cidr", "No usable address remains for the DHCP server")
                continue
            }
            let server = owned ? existing!.gateway : IPv4(serverValue).description
            result.filled.append("dhcpServer[\(declaration.ref)]=\(server)")
            var ips = Set<IPv4>()
            for (vi, vm) in spec.vms.enumerated() {
                for (ni, nic) in vm.nics.enumerated() where nic.network == declaration.ref {
                    guard let text = nic.ip, let ip = IPv4(text) else { continue }
                    let p = "/vms/\(vi)/nics/\(ni)/ip"
                    if !subnet.contains(ip) || ip == subnet.network || ip == subnet.broadcast || ip.description == server {
                        problem("INVALID", p, "IP must be a usable address in \(subnet), excluding the DHCP server")
                    }
                    if !ips.insert(ip).inserted { problem("INVALID", p, "Duplicate IP on this network") }
                }
            }
            var router = ""
            if let ref = declaration.router {
                if let vm = result.vms.first(where: { $0.name == ref }), let nic = vm.nics.first(where: { $0.network == declaration.ref }) {
                    if let ip = nic.ip { router = ip }
                    else { problem("INVALID", path + "/router", "Router VM requires an IP on this network", "give it an ip") }
                } else { problem("INVALID", path + "/router", "Router must name a VM attached to this network", "attach the router VM and give it an ip") }
            }
            let reservations = nics.compactMap { name, nic in
                nic.ip.map { DHCPReservation(mac: nic.mac, ip: $0, comment: name) }
            }
            let network = owned ? existing! : VirtualNetwork(name: declaration.ref, mode: .guestOnly, gateway: server,
                                                              prefixLength: subnet.prefixLength, reservations: reservations, router: router)
            if owned {
                for reservation in reservations where !network.reservations.contains(where: {
                    DHCPReservation.normalizedMAC($0.mac) == reservation.mac && IPv4($0.ip) == IPv4(reservation.ip)
                }) {
                    problem("CONFLICT", path + "/reservations", "Owned network is missing reservation \(reservation.mac)=\(reservation.ip)")
                }
            }
            // An overlap was already reported above, with a free subnet as the alternative.
            for error in network.validate(against: others) {
                if case .overlaps = error, overlaps { continue }
                problem("INVALID", path, validationMessage(error))
            }
            result.networks.append(.init(action: owned ? .unchanged : .create, network: network))
        }
        let routers = Set(spec.networks.compactMap(\.router))
        result.vms = result.vms.filter { routers.contains($0.name) } + result.vms.filter { !routers.contains($0.name) }
        let memory = result.vms.filter { $0.action == .create }.reduce(Double(facts.runningMemory)) { $0 + Double($1.memoryBytes) }
        if memory > Double(facts.physicalMemory) {
            result.approvals.append("memory: \(memory / 1_073_741_824) GiB exceeds the Mac's \(Double(facts.physicalMemory) / 1_073_741_824) GiB")
        }
        return result
    }

    private static func validationMessage(_ error: VirtualNetwork.ValidationError) -> String {
        switch error {
        case .invalidName: "Invalid network name"
        case .duplicateName: "Duplicate network name"
        case .invalidGateway: "Invalid DHCP server address"
        case .gatewayIsNetworkOrBroadcast: "DHCP server cannot use the network or broadcast address"
        case .invalidPrefixLength: "Prefix length must be /16 through /28"
        case .notPrivate: "Subnet must be private (RFC 1918)"
        case .overlaps: "Subnet overlaps another network or a reserved subnet"
        case .invalidReservation: "Invalid DHCP reservation: check MAC and IP uniqueness and usable addresses"
        case .missingInterface: "Missing bridge interface"
        case .invalidRouter: "Router must be a usable address in the subnet, excluding the DHCP server"
        }
    }

    private static func validName(_ name: String, limit: Int) -> Bool {
        !name.isEmpty && name.count <= limit && name.wholeMatch(of: /[a-z][a-z0-9-]*/) != nil && !name.hasSuffix("-")
    }

    private static func mac(vm: String, network: String) -> String {
        let bytes = SHA256.hash(data: Data((vm + "/" + network).utf8)).prefix(3)
        return "52:55:55:" + bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func freeName(_ name: String, avoiding taken: Set<String>, limit: Int) -> String {
        var suffix = 2
        while true {
            let tail = "-\(suffix)"
            let candidate = String(name.prefix(limit - tail.count)).trimmingCharacters(in: CharacterSet(charactersIn: "-")) + tail
            if !taken.contains(candidate) { return candidate }
            suffix += 1
        }
    }

    private static func freeSubnet(avoiding subnets: [IPv4Subnet]) -> String? {
        let taken = subnets + VirtualNetwork.reservedSubnets.map(\.subnet)
        let candidates = (20...255).map { "10.\($0).0.0/24" } + (210...254).map { "192.168.\($0).0/24" }
        return candidates.first { cidr in
            guard let candidate = IPv4Subnet(cidr: cidr) else { return false }
            return !taken.contains { candidate.overlaps($0) }
        }
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var next = [i + 1]
            for (j, y) in b.enumerated() { next.append(min(next[j] + 1, row[j + 1] + 1, row[j] + (x == y ? 0 : 1))) }
            row = next
        }
        return row[b.count]
    }
}
