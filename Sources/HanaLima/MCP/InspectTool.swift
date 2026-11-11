import Foundation
import LimaKit
import MCPKit
import NetworkKit

/// The `inspect` tool (docs/14 §4): HanaLima's state as compact text for the model.
///
/// Answers from the model's memory only and starts no process, so a call costs nothing on the
/// Mac. Values are raw (Lima's status names, ids, numbers), never the localized labels the UI
/// shows, so the output doesn't change with the Mac's language. Lists are tab-separated tables
/// with a header line: the column names are written once instead of once per row as JSON keys.
@MainActor
struct InspectTool {
    let model: AppModel

    nonisolated static let defaultLimit = 20

    enum Failure: Error { case invalid(String) }

    func run(_ arguments: MCPKit.JSONValue) throws -> String {
        let args = try Arguments(arguments)
        let (topics, ids, query, limit, offset) = (args.topics, args.ids, args.query, args.limit, args.offset)
        var sections: [String] = []
        for topic in topics {
            switch topic {
            case "context": sections.append(context())
            case "vms": sections.append(ids.isEmpty ? vms(limit: limit, offset: offset) : vmDetails(ids))
            case "networks": sections.append(ids.isEmpty ? networks() : networkDetails(ids))
            case "groups": sections.append(groups())
            case "templates": sections.append(try templates(query: query, limit: limit, offset: offset))
            case "examples": sections.append(examples())
            case "snapshots": sections.append(try snapshots(ids))
            case "jobs": sections.append(jobs())
            case "help": sections.append(Self.help(query))
            default: throw Failure.invalid("unknown topic: \(topic)")
            }
        }
        return sections.joined(separator: "\n")
    }

    /// The arguments, checked against the tool's input schema: a mistyped argument is an error,
    /// not a quietly different answer (an `ids` the model got wrong would list everything).
    struct Arguments {
        var topics = ["context"]
        var ids: [String] = []
        var query = ""
        var limit = InspectTool.defaultLimit
        var offset = 0

        init(_ json: MCPKit.JSONValue) throws {
            guard let object = json.objectValue else { throw Failure.invalid("arguments must be an object") }
            let known: Set = ["topics", "ids", "query", "limit", "cursor"]
            if let unknown = object.keys.first(where: { !known.contains($0) }) {
                throw Failure.invalid("unknown argument: \(unknown)")
            }
            if let raw = object["topics"] {
                let list = try Self.strings(raw, "topics")
                if !list.isEmpty { topics = list }
            }
            if let raw = object["ids"] { ids = try Self.strings(raw, "ids") }
            if let raw = object["query"] {
                guard let s = raw.stringValue else { throw Failure.invalid("query must be a string") }
                query = s.trimmingCharacters(in: .whitespaces)
            }
            if let raw = object["limit"] {
                guard let n = raw.intValue, (1...100).contains(n) else { throw Failure.invalid("limit must be an integer from 1 to 100") }
                limit = n
            }
            if let raw = object["cursor"] {
                guard let n = raw.stringValue.flatMap(Int.init), n >= 0 else {
                    throw Failure.invalid("cursor must be a value returned as next")
                }
                offset = n
            }
        }

        private static func strings(_ raw: MCPKit.JSONValue, _ name: String) throws -> [String] {
            guard let array = raw.arrayValue else { throw Failure.invalid("\(name) must be an array of strings") }
            let list = array.compactMap(\.stringValue)
            guard list.count == array.count else { throw Failure.invalid("\(name) must be an array of strings") }
            return list
        }
    }

    /// One page of `items` and the `next` line when more remain (shared by every paged topic).
    static func page<T>(_ items: [T], limit: Int, offset: Int, row: (T) -> String) -> [String] {
        let page = items.dropFirst(offset).prefix(limit)
        var lines = page.map(row)
        if offset + page.count < items.count { lines.append("next\t\(offset + page.count)") }
        return lines
    }

    // MARK: - context

    /// What building a topology needs, in one call (docs/14 §2.1).
    private func context() -> String {
        var lines = ["# context"]
        switch model.availability {
        case .ready(let version): lines.append("limactl\t\(version)")
        case .missing: lines.append("limactl\tmissing (install Lima first; nothing can be built)")
        case .failed(let message): lines.append("limactl\terror: \(message)")
        case .checking: lines.append("limactl\tchecking")
        }
        lines.append("driver\t\(AppModel.hasDriver ? "hanalima available" : "hanalima missing (vz only)")")
        let memGiB = Double(ProcessInfo.processInfo.physicalMemory) / Double(1 << 30)
        let used = model.instances.filter(\.isRunning).reduce(0.0) { $0 + Double($1.memory ?? 0) / Double(1 << 30) }
        lines.append("host\tcpus=\(ProcessInfo.processInfo.activeProcessorCount)\tmemoryGiB=\(Self.num(memGiB))\trunningVMsMemoryGiB=\(Self.num(used))")
        lines.append("vm_names\t\(model.instances.map(\.name).joined(separator: ","))")
        let nets = model.virtualNetworks
        lines.append("networks\t" + (nets.isEmpty ? "-" : nets.map { "\($0.name)(\($0.mode.rawValue) \(Self.subnet($0)))" }.joined(separator: ",")))
        let bridges = nets.filter(\.isBridged).map { "\($0.name)(\($0.bridgedInterface))" }
        lines.append("bridged_networks\t" + (bridges.isEmpty ? "- (MCP doesn't create bridges; the user makes them in the app)" : bridges.joined(separator: ",")))
        lines.append("suggested_subnet\t\(Self.suggestedSubnet(avoiding: nets))")
        lines.append("groups\t" + (model.groupLayout.groups.isEmpty ? "-" : model.groupLayout.groups.map(\.name).joined(separator: ",")))
        lines.append("templates\t\(featuredTemplates()) (more: topic templates with query)")
        lines.append("examples\t\(ProvisionExample.ID.allCases.map(\.rawValue).joined(separator: ","))")
        lines.append("""
        limits\tnetwork prefix /\(VirtualNetwork.prefixLengths.lowerBound)-/\(VirtualNetwork.prefixLengths.upperBound), private ranges, no overlap with other networks or the reserved \(VirtualNetwork.reservedSubnets.map(\.subnet.description).joined(separator: ",")); \
        names: lowercase letters, digits, '-'; NIC 0 (usernet) can be removed only with vmType hanalima; \
        SSH and the guest agent use vsock, so a VM without NIC 0 stays manageable
        """)
        return lines.joined(separator: "\n")
    }

    /// One template per family, the ones people usually start from.
    private func featuredTemplates() -> String {
        let wanted = ["ubuntu-lts", "debian", "fedora", "alpine", "archlinux", "almalinux", "rocky", "opensuse"]
        let names = Set(model.templates.map(\.name))
        let found = wanted.filter(names.contains).map { name in
            model.templates.first { $0.name == name }?.resolvedImage.map { "\(name)=\($0)" } ?? name
        }
        return found.isEmpty ? "-" : found.joined(separator: ",")
    }

    static func suggestedSubnet(avoiding networks: [VirtualNetwork]) -> String {
        let gateway = VirtualNetwork.suggestedGateway(avoiding: networks)
        guard let ip = IPv4(gateway) else { return gateway }
        return IPv4Subnet(containing: ip, prefixLength: 24).description
    }

    // MARK: - vms

    private func vms(limit: Int, offset: Int) -> String {
        let all = model.instances
        let header = ["# vms \(all.count)", "name\tstatus\tvmType\tcpus\tmemGiB\tdiskGiB\tgroup\tnics"]
        return (header + Self.page(all, limit: limit, offset: offset) { inst in
            [inst.name, state(of: inst), inst.vmType ?? "-", inst.cpus.map(String.init) ?? "-",
             Self.gib(inst.memory), Self.gib(inst.disk), model.metadata[inst.name]?.group ?? "-",
             nics(of: inst)].joined(separator: "\t")
        }).joined(separator: "\n")
    }

    /// Lima's status, refined with what HanaLima knows (ready, paused, hibernated, an operation).
    private func state(of inst: LimaInstance) -> String {
        if let op = model.operations[inst.name], op.isRunning { return "busy:\(op.kind)" }
        if model.isPaused(inst.name) { return "paused" }
        if model.isHibernated(inst.name) { return "hibernated" }
        if inst.isRunning { return model.isReady(inst.name) ? "ready" : "booting" }
        return inst.status.rawValue.lowercased()
    }

    private func nics(of inst: LimaInstance) -> String {
        var parts: [String] = inst.usesUsernet ? ["usernet"] : []
        for attachment in inst.networks ?? [] {
            if let socket = attachment.socket {
                if let net = model.virtualNetwork(forSocket: socket) {
                    let ip = model.address(of: inst, on: net) ?? model.reservation(of: inst, on: net)?.ip
                    parts.append(ip.map { "\(net.name)=\($0)" } ?? net.name)
                } else {
                    parts.append("deleted-network")
                }
            } else {
                parts.append(attachment.kindDescription)
            }
        }
        return parts.isEmpty ? "-" : parts.joined(separator: ",")
    }

    private func vmDetails(_ names: [String]) -> String {
        var out: [String] = []
        for name in names {
            guard let inst = model.instance(named: name) else { out.append("# vm \(name)\nerror\tnot found"); continue }
            var lines = ["# vm \(name)", "state\t\(state(of: inst))", "vmType\t\(inst.vmType ?? "-")",
                         "cpus\t\(inst.cpus.map(String.init) ?? "-")\tmemGiB\t\(Self.gib(inst.memory))\tdiskGiB\t\(Self.gib(inst.disk))",
                         "usernet\t\(inst.usesUsernet)"]
            for attachment in inst.networks ?? [] {
                if let socket = attachment.socket, let net = model.virtualNetwork(forSocket: socket) {
                    let mac = model.macAddress(of: inst, on: net) ?? "-"
                    let reserved = model.reservation(of: inst, on: net)?.ip ?? "-"
                    let leased = model.address(of: inst, on: net) ?? "-"
                    lines.append("nic\t\(net.name)\tmode=\(net.mode.rawValue)\tmac=\(mac)\treserved=\(reserved)\taddress=\(leased)")
                } else {
                    lines.append("nic\t\(attachment.kindDescription)\tmac=\(attachment.macAddress ?? "-")")
                }
            }
            if let meta = model.metadata[name] {
                lines.append("id\t\(meta.id.uuidString)")
                if let template = meta.template { lines.append("template\t\(template)") }
                if let group = meta.group { lines.append("group\t\(group)") }
                if let parent = meta.parent { lines.append("parent\t\(parent.name)") }
                if meta.pendingInstall != nil { lines.append("pending\tinstall from ISO (start it from the app)") }
                if meta.pendingIsolation == true { lines.append("pending\tNIC 0 is removed when the VM stops after its first boot has finished") }
            }
            if let changed = model.restartNeeded[name], !changed.isEmpty {
                lines.append("restart_needed\tnetworks changed: \(changed.sorted().joined(separator: ","))")
            }
            if inst.usesVirtualization {
                lines.append("snapshots\t\(DiskSnapshot.list(instanceDir: inst.instanceDir).count)")
            }
            out.append(lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - networks and groups

    private func networks() -> String {
        var lines = ["# networks \(model.virtualNetworks.count)", "name\tmode\tsubnet\tgateway\trouter\tbridge\treservations\tvms"]
        for net in model.virtualNetworks {
            lines.append([net.name, net.mode.rawValue, Self.subnet(net), net.isBridged ? "-" : net.gateway,
                          net.router.isEmpty ? "-" : net.router, net.isBridged ? net.bridgedInterface : "-",
                          "\(net.reservations.count)", model.instances(using: net).map(\.name).joined(separator: ",").nonEmpty ?? "-"]
                .joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    private func networkDetails(_ names: [String]) -> String {
        var out: [String] = []
        for name in names {
            guard let net = model.virtualNetworks.first(where: { $0.name == name }) else {
                out.append("# network \(name)\nerror\tnot found"); continue
            }
            var lines = ["# network \(name)", "mode\t\(net.mode.rawValue)\tsubnet\t\(Self.subnet(net))"]
            if !net.isBridged { lines.append("dhcp_server\t\(net.gateway)") }
            if !net.router.isEmpty { lines.append("router\t\(net.router)") }
            if net.isBridged { lines.append("bridge\t\(net.bridgedInterface)") }
            if let state = model.networkStates[name] { lines.append("helper\t\(state)") }
            if !net.reservations.isEmpty {
                lines.append("reservation\tmac\tip\tcomment")
                lines += net.reservations.map { "reservation\t\($0.mac)\t\($0.ip)\t\($0.comment.nonEmpty ?? "-")" }
            }
            for inst in model.instances(using: net) {
                lines.append("vm\t\(inst.name)\t\(model.address(of: inst, on: net) ?? "-")")
            }
            out.append(lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    private func groups() -> String {
        let byID = Dictionary(model.metadata.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        var lines = ["# groups \(model.groupLayout.groups.count)", "group\tmembers(start order)"]
        for group in model.groupLayout.groups {
            lines.append("\(group.name)\t\(group.members.compactMap { byID[$0] }.joined(separator: ",").nonEmpty ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - templates, examples, snapshots, jobs

    private func templates(query: String, limit: Int, offset: Int) throws -> String {
        guard !query.isEmpty else {
            throw Failure.invalid("templates needs a query (e.g. ubuntu, debian, alpine); the full list is long")
        }
        let matches = model.templates.filter { $0.name.localizedCaseInsensitiveContains(query) && !$0.isExperimental }
        let header = ["# templates \(query) \(matches.count)", "name\tresolves_to"]
        return (header + Self.page(matches, limit: limit, offset: offset) { "\($0.name)\t\($0.resolvedImage ?? "-")" })
            .joined(separator: "\n")
    }

    private func examples() -> String {
        var lines = ["# examples", "id\tdistributions\twhat"]
        for example in ProvisionExamples.all {
            lines.append("\(example.id.rawValue)\t\(example.distributions.joined(separator: ","))\t\(Self.exampleSummary[example.id] ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    /// For the model, in English (the app's own descriptions are localized for people).
    static let exampleSummary: [ProvisionExample.ID: String] = [
        .basicTools: "common CLI tools (curl, git, vim, htop, jq...)",
        .dotfiles: "clone a dotfiles repo and add SSH public keys",
        .containerEngine: "Docker Engine; the user joins the docker group at next login",
        .xdp: "XDP/eBPF development (clang, libbpf, bpftool)",
        .japan: "Japanese timezone and locale",
        .noAutoUpdates: "turn off automatic package updates",
        .swap: "add a swap file",
        .devLanguages: "Go, Node.js, uv, rustup",
        .fullUpgrade: "upgrade all packages, once",
        .consoleLogin: "autologin on the screen console and serial (for rescue)",
        .gateway: "egress-filtering gateway for a guest-only network's router VM (NAT, DNS, allow list)",
    ]

    private func snapshots(_ names: [String]) throws -> String {
        guard !names.isEmpty else { throw Failure.invalid("snapshots needs ids (VM names)") }
        var out: [String] = []
        let format = ISO8601DateFormatter()
        for name in names {
            guard let inst = model.instance(named: name) else { out.append("# snapshots \(name)\nerror\tnot found"); continue }
            guard inst.usesVirtualization else { out.append("# snapshots \(name)\nerror\tonly vz and hanalima VMs"); continue }
            var lines = ["# snapshots \(name)", "name\tcreated"]
            lines += DiskSnapshot.list(instanceDir: inst.instanceDir).map { "\($0.name)\t\(format.string(from: $0.createdAt))" }
            out.append(lines.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    /// The MCP jobs, newest first (kept across launches; unfinished ones become interrupted).
    private func jobs() -> String {
        let store = model.agentHost.vmJobs.store
        store.expireStale()
        let jobs = store.jobs
        let lines = ["# jobs \(jobs.count)"]
            + jobs.prefix(20).map { "\($0.id)\t\($0.state.rawValue)\t\($0.summary)" }
        return lines.joined(separator: "\n")
    }

    // MARK: - help

    static func help(_ topic: String) -> String {
        let topics: [String: String] = [
            "isolation": """
            A VM without NIC 0 (usernet: false, vmType hanalima) reaches only the networks it is attached to; \
            SSH, the guest agent and port forwarding go over vsock. Ubuntu 26.04 (systemd 256+) works from \
            the first boot; Alpine and older systemd need one boot with NIC 0 first to install socat.
            """,
            "networks": """
            Modes: shared (NAT via the Mac), host (host-only), bridged (the Mac's interface; made by the user only), \
            guestOnly (a switch between VMs inside netd; the Mac has no interface on it). A guestOnly network can name \
            a router: a VM address handed out by DHCP as the default route and second DNS server.
            """,
            "gateway": """
            The gateway example makes a router VM do NAT and DNS for a guestOnly network and pass only hosts \
            in /etc/hanalima/gateway.conf (host names, addresses, CIDRs, or *). Host names are matched by \
            the addresses resolved through the gateway, so other services on the same address pass too.
            """,
        ]
        guard !topic.isEmpty else {
            return "# help\ntopics\t\(topics.keys.sorted().joined(separator: ","))"
        }
        return "# help \(topic)\n" + (topics[topic] ?? "unknown topic; topics: \(topics.keys.sorted().joined(separator: ","))")
    }

    // MARK: - formatting

    static func subnet(_ net: VirtualNetwork) -> String { net.subnet?.description ?? "-" }

    static func gib(_ bytes: Int64?) -> String {
        guard let bytes else { return "-" }
        return num(Double(bytes) / Double(1 << 30))
    }

    static func num(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
