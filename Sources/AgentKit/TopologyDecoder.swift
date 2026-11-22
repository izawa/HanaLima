import Foundation
import LimaKit
import MCPKit

extension TopologySpec {
    public static func decode(_ json: MCPKit.JSONValue) -> (spec: TopologySpec?, problems: [PlanProblem]) {
        let reader = DeclarationReader()
        let root = reader.object(json, at: "", keys: ["group", "verifyOutside", "defaults", "networks", "vms", "assumptions"])
        let d = root["defaults"].map {
            reader.object($0, at: "/defaults", keys: ["template", "cpus", "memoryGiB", "diskGiB", "usernet"])
        } ?? [:]
        let defaults = Defaults(template: reader.string(d, "template", at: "/defaults"),
                                cpus: reader.integer(d, "cpus", at: "/defaults"),
                                memoryGiB: reader.number(d, "memoryGiB", at: "/defaults"),
                                diskGiB: reader.number(d, "diskGiB", at: "/defaults"),
                                usernet: reader.boolean(d, "usernet", at: "/defaults"))
        let networks: [Network] = reader.array(root, "networks", at: "").enumerated().map { i, value in
            let path = "/networks/\(i)"
            let o = reader.object(value, at: path, keys: ["ref", "mode", "cidr", "router", "existing"])
            let existing = reader.string(o, "existing", at: path)
            return Network(ref: reader.string(o, "ref", at: path, required: true) ?? "",
                           mode: reader.string(o, "mode", at: path, required: existing == nil) ?? "",
                           cidr: reader.string(o, "cidr", at: path, required: existing == nil) ?? "",
                           router: reader.string(o, "router", at: path), existing: existing)
        }
        let vms: [VM] = reader.array(root, "vms", at: "").enumerated().map { i, value in
            let path = "/vms/\(i)"
            let o = reader.object(value, at: path, keys: ["ref", "template", "cpus", "memoryGiB", "diskGiB",
                                                         "usernet", "bootstrapUsernet", "nics", "gateway", "provision", "portForwards"])
            let nics: [NIC] = reader.array(o, "nics", at: path).enumerated().map { j, value in
                let p = path + "/nics/\(j)"
                let nic = reader.object(value, at: p, keys: ["network", "ip"])
                return NIC(network: reader.string(nic, "network", at: p, required: true) ?? "",
                           ip: reader.string(nic, "ip", at: p))
            }
            let allow: [String]? = o["gateway"].map { value in
                let p = path + "/gateway"
                let gateway = reader.object(value, at: p, keys: ["allow"])
                return reader.array(gateway, "allow", at: p, required: true).enumerated().compactMap { j, value in
                    guard let s = value.stringValue else {
                        reader.invalid(p + "/allow/\(j)", "Expected a string")
                        return nil
                    }
                    return s
                }
            }
            var provision: [ProvisionExample.ID] = []
            for (j, value) in reader.array(o, "provision", at: path).enumerated() {
                let p = path + "/provision/\(j)"
                guard let id = value.stringValue.flatMap(ProvisionExample.ID.init(rawValue:)) else {
                    reader.invalid(p, "Unknown example (inspect topic examples lists them)")
                    continue
                }
                if provision.contains(id) { reader.invalid(p, "Duplicate example") } else { provision.append(id) }
            }
            let forwards: [PortForward] = reader.array(o, "portForwards", at: path).enumerated().map { j, value in
                let p = path + "/portForwards/\(j)"
                let rule = reader.object(value, at: p, keys: ["guestPort", "hostPort", "proto"])
                if let proto = reader.string(rule, "proto", at: p), proto != "tcp" { reader.invalid(p + "/proto", "Only tcp is supported") }
                guard let guest = reader.integer(rule, "guestPort", at: p), let host = reader.integer(rule, "hostPort", at: p) else {
                    reader.invalid(p, "guestPort and hostPort are required")
                    return PortForward(guestPort: 0, hostPort: 0)  // kept, so later rules keep their positions
                }
                return PortForward(guestPort: guest, hostPort: host)
            }
            return VM(ref: reader.string(o, "ref", at: path, required: true) ?? "",
                      template: reader.string(o, "template", at: path), cpus: reader.integer(o, "cpus", at: path),
                      memoryGiB: reader.number(o, "memoryGiB", at: path), diskGiB: reader.number(o, "diskGiB", at: path),
                      usernet: reader.boolean(o, "usernet", at: path),
                      bootstrapUsernet: reader.boolean(o, "bootstrapUsernet", at: path) ?? false,
                      nics: nics, gatewayAllow: allow, provision: provision, portForwards: forwards)
        }
        let assumptions: [Assumption] = reader.array(root, "assumptions", at: "").enumerated().map { i, value in
            let path = "/assumptions/\(i)"
            let o = reader.object(value, at: path, keys: ["path", "reason"])
            return Assumption(path: reader.string(o, "path", at: path, required: true) ?? "",
                              reason: reader.string(o, "reason", at: path, required: true) ?? "")
        }
        let spec = TopologySpec(group: reader.string(root, "group", at: ""), verifyOutside: reader.string(root, "verifyOutside", at: ""), defaults: defaults,
                                networks: networks, vms: vms, assumptions: assumptions)
        let problems = reader.problems + declarationProblems(spec)
        return (problems.isEmpty ? spec : nil, problems)
    }
}

/// Shared by decoding and planning, since callers may construct a declaration directly.
func declarationProblems(_ spec: TopologySpec) -> [PlanProblem] {
    var problems: [PlanProblem] = []
    func invalid(_ path: String, _ message: String) {
        problems.append(.init(code: "INVALID", path: path, message: message))
    }
    func resources(_ cpus: Int?, _ memory: Double?, _ disk: Double?, at path: String) {
        if let cpus, cpus < 1 { invalid(path + "/cpus", "CPUs must be positive") }
        if let memory, !memory.isFinite || memory < 1 || memory * 1_073_741_824 >= Double(Int64.max) {
            invalid(path + "/memoryGiB", "Memory must be at least 1 GiB and fit in an Int64 byte count")
        }
        if let disk, !disk.isFinite || !(10...4096).contains(disk) {
            invalid(path + "/diskGiB", "Disk must be between 10 and 4096 GiB")
        }
    }
    if let host = spec.verifyOutside,
       !(1...253).contains(host.count) || host.hasPrefix("-") || host.wholeMatch(of: /[A-Za-z0-9.-]+/) == nil {
        invalid("/verifyOutside", "Expected 1–253 letters, digits, dots or hyphens, with no leading hyphen")
    }
    if spec.vms.count > 16 { invalid("/vms", "At most 16 VMs are supported") }
    if spec.networks.count > 4 { invalid("/networks", "At most 4 networks are supported") }
    resources(spec.defaults.cpus, spec.defaults.memoryGiB, spec.defaults.diskGiB, at: "/defaults")
    for (i, network) in spec.networks.enumerated() where network.existing != nil {
        for (key, given) in [("mode", !network.mode.isEmpty), ("cidr", !network.cidr.isEmpty), ("router", network.router != nil)] where given {
            invalid("/networks/\(i)/" + key, "An existing network is used as it is: give existing alone")
        }
    }
    for (i, network) in spec.networks.enumerated() where network.existing == nil && network.mode != "guestOnly" {
        problems.append(.init(code: "UNSUPPORTED", path: "/networks/\(i)/mode", message: "Only guestOnly is supported",
                              alternative: "guestOnly; bridges and other modes are made in the app"))
    }
    var hostPortClaims: [Int: String] = [:]
    for (i, vm) in spec.vms.enumerated() {
        let path = "/vms/\(i)"
        resources(vm.cpus, vm.memoryGiB, vm.diskGiB, at: path)
        if vm.nics.isEmpty && !(vm.usernet ?? spec.defaults.usernet ?? true) {
            invalid(path + "/nics", "At least one NIC is required when usernet is false")
        }
        if Set(vm.provision).count != vm.provision.count { invalid(path + "/provision", "Duplicate example") }
        if vm.portForwards.count > 32 { invalid(path + "/portForwards", "At most 32 port forwards per VM") }
        var guestPorts = Set<Int>()
        for (j, forward) in vm.portForwards.enumerated().prefix(32) where forward.guestPort != 0 || forward.hostPort != 0 {
            let p = path + "/portForwards/\(j)"
            if !(1...65535).contains(forward.guestPort) || forward.guestPort == 22 {
                invalid(p + "/guestPort", "Guest port must be 1–65535, not 22 (Lima's SSH)")
            }
            if !(1024...65535).contains(forward.hostPort) {
                problems.append(.init(code: "UNSUPPORTED", path: p + "/hostPort", message: "Host port must be 1024–65535 (no privileged ports)",
                                      alternative: "a free port in 1024–65535"))
            }
            if !guestPorts.insert(forward.guestPort).inserted {
                invalid(p + "/guestPort", "Duplicate guest port in this VM (only the first rule would apply)")
            }
            if let other = hostPortClaims[forward.hostPort] {
                invalid(p + "/hostPort", "Host port \(forward.hostPort) is already forwarded for \(other)")
            } else {
                hostPortClaims[forward.hostPort] = vm.ref
            }
        }
    }
    return problems
}

private final class DeclarationReader {
    var problems: [PlanProblem] = []
    func invalid(_ path: String, _ message: String) {
        problems.append(.init(code: "INVALID", path: path, message: message))
    }
    func object(_ value: MCPKit.JSONValue, at path: String, keys: Set<String>) -> [String: MCPKit.JSONValue] {
        guard let o = value.objectValue else { invalid(path, "Expected an object"); return [:] }
        for key in o.keys.sorted() where !keys.contains(key) {
            let escaped = key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
            invalid(path + "/" + escaped, "Unknown key")
        }
        return o
    }
    func read<T>(_ o: [String: MCPKit.JSONValue], _ key: String, at path: String, required: Bool = false,
                 type: String, convert: (MCPKit.JSONValue) -> T?) -> T? {
        guard let value = o[key] else {
            if required { invalid(path + "/" + key, "Required field") }
            return nil
        }
        guard let result = convert(value) else { invalid(path + "/" + key, "Expected " + type); return nil }
        return result
    }
    func string(_ o: [String: MCPKit.JSONValue], _ key: String, at path: String, required: Bool = false) -> String? {
        read(o, key, at: path, required: required, type: "a string") { $0.stringValue }
    }
    func integer(_ o: [String: MCPKit.JSONValue], _ key: String, at path: String) -> Int? {
        read(o, key, at: path, type: "an integer") { $0.intValue }
    }
    func number(_ o: [String: MCPKit.JSONValue], _ key: String, at path: String) -> Double? {
        read(o, key, at: path, type: "a finite number") { value in value.doubleValue.flatMap { $0.isFinite ? $0 : nil } }
    }
    func boolean(_ o: [String: MCPKit.JSONValue], _ key: String, at path: String) -> Bool? {
        read(o, key, at: path, type: "a boolean") { $0.boolValue }
    }
    func array(_ o: [String: MCPKit.JSONValue], _ key: String, at path: String, required: Bool = false) -> [MCPKit.JSONValue] {
        read(o, key, at: path, required: required, type: "an array") { $0.arrayValue } ?? []
    }
}
