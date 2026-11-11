import CryptoKit
import Foundation
import LimaKit

extension TopologyPlan {
    public func text(planID: String, expires: Date) -> String {
        func row(_ columns: String...) -> String { columns.map(Self.cell).joined(separator: "\t") }
        var lines = [row("plan " + planID, problems.isEmpty ? "ready" : "blocked", "expires=" + expires.ISO8601Format()),
                     "action\ttarget\tdetail"]
        for entry in networks {
            let n = entry.network
            var detail = "\(n.mode.rawValue) \(n.subnet?.description ?? "?")"
            if !n.router.isEmpty { detail += " router=\(n.router)" }
            detail += " dhcp=\(n.gateway)"
            lines.append(row(entry.action.rawValue, n.name, detail))
        }
        for vm in vms {
            var detail = vm.template
            if let cpus = vm.options.cpus { detail += " \(cpus)cpu" }
            if let memory = vm.options.memoryGiB { detail += " \(Self.number(memory))GiB" }
            detail += " nics=" + vm.nics.map { "\($0.network):\($0.ip ?? "dhcp")" }.joined(separator: ",")
            let off = vm.options.setExpressions.contains(".vmOpts.hanalima.usernet = false")
            detail += " usernet=" + (vm.bootstrapUsernet ? "bootstrap→off" : off ? "off" : "on")
            if vm.options.setExpressions.contains(where: { $0.hasPrefix(".provision += ") && $0.contains("/etc/hanalima/gateway.conf") }) {
                detail += " gateway"
            }
            lines.append(row(vm.action.rawValue, vm.name, detail))
        }
        lines.append(row("order", vms.map(\.name).joined(separator: " → ")))
        lines.append(row("filled", filled.joined(separator: "; ")))
        for a in assumptions { lines.append(row("assumption", a.path, a.reason)) }
        if approvals.isEmpty { lines.append("approval\tnone") }
        for approval in approvals { lines.append(row("approval", approval)) }
        for p in problems {
            var columns = ["problem", p.code, p.path, p.message]
            if let alternative = p.alternative { columns.append("alternative: " + alternative) }
            lines.append(columns.map(Self.cell).joined(separator: "\t"))
        }
        lines.append("verify\tconfig, boot, DHCP lease (traffic not checked)")
        return lines.joined(separator: "\n")
    }

    /// Canonical, length-delimited JSON avoids process-random hashing and ambiguous concatenation.
    /// Presentation notes and approvals are excluded; apply's inputs and execution order are included.
    public var fingerprint: String {
        let networkValues: [LimaKit.JSONValue] = networks.map { entry in
            let n = entry.network
            return .object([
                "action": .string(entry.action.rawValue), "name": .string(n.name), "mode": .string(n.mode.rawValue),
                "gateway": .string(n.gateway), "prefixLength": .int(n.prefixLength), "comment": .string(n.comment),
                "bridgedInterface": .string(n.bridgedInterface), "router": .string(n.router),
                "reservations": .array(n.reservations.map { .object(["mac": .string($0.mac), "ip": .string($0.ip), "comment": .string($0.comment)]) })
            ])
        }
        let vmValues: [LimaKit.JSONValue] = vms.map { vm in
            let o = vm.options
            return .object([
                "action": .string(vm.action.rawValue), "name": .string(vm.name), "template": .string(vm.template),
                "bootstrapUsernet": .bool(vm.bootstrapUsernet), "memoryBytes": .string(String(vm.memoryBytes)),
                "nics": .array(vm.nics.map { .object(["network": .string($0.network), "mac": .string($0.mac), "ip": $0.ip.map(LimaKit.JSONValue.string) ?? .null]) }),
                "options": .object([
                    "name": .string(o.name), "template": .string(o.template), "cpus": o.cpus.map(LimaKit.JSONValue.int) ?? .null,
                    "memoryGiB": o.memoryGiB.map(LimaKit.JSONValue.double) ?? .null,
                    "diskGiB": o.diskGiB.map(LimaKit.JSONValue.double) ?? .null,
                    "vmType": o.vmType.map { .string($0.rawValue) } ?? .null,
                    "networks": .array(o.networks.map(LimaKit.JSONValue.string)), "rosetta": .bool(o.rosetta),
                    "video": .bool(o.video), "mountNone": .bool(o.mountNone),
                    "mountOnly": .array(o.mountOnly.map(LimaKit.JSONValue.string)),
                    "setExpressions": .array(o.setExpressions.map(LimaKit.JSONValue.string))
                ])
            ])
        }
        let value = LimaKit.JSONValue.object(["group": group.map(LimaKit.JSONValue.string) ?? .null,
                                              "networks": .array(networkValues), "vms": .array(vmValues)])
        return SHA256.hash(data: Data(value.jsonText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func number(_ value: Double) -> String {
        value.isFinite && value.rounded() == value ? String(format: "%.0f", value) : String(value)
    }
}
