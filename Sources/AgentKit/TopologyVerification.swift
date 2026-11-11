import Foundation

public struct TrafficCheck: Equatable, Sendable {
    public var vm: String
    public var id: String
    public var description: String

    public init(vm: String, id: String, description: String) {
        self.vm = vm; self.id = id; self.description = description
    }
}

public struct TrafficCheckResult: Equatable, Sendable {
    public var check: TrafficCheck
    public var verified: Bool
    public var reason: String?

    public init(check: TrafficCheck, verified: Bool, reason: String? = nil) {
        self.check = check; self.verified = verified; self.reason = reason
    }
}

public enum TopologyVerification {
    /// One POSIX sh script per VM, run as the login user with the script on stdin.
    public static func scripts(for plan: TopologyPlan) -> [String: (checks: [TrafficCheck], script: String)] {
        var scripts: [String: (checks: [TrafficCheck], script: String)] = [:]
        func append(_ vm: String, _ id: String, _ description: String, _ script: String) {
            scripts[vm, default: ([], "")].checks.append(.init(vm: vm, id: id, description: description))
            scripts[vm, default: ([], "")].script += script + "\n"
        }
        func probe(_ vm: String, _ id: String, _ description: String, command: String, reason: String) {
            append(vm, id, description, """
            if \(command) >/dev/null 2>&1; then
                printf '%s\\n' \(quote("HLCHECK \(id) ok"))
            else
                printf '%s\\n' \(quote("HLCHECK \(id) fail \(reason)"))
            fi
            """)
        }
        for entry in plan.networks {
            let network = entry.network
            let members = plan.vms.filter { vm in vm.nics.contains { $0.network == network.name } }
            let router = members.first { vm in
                !network.router.isEmpty && vm.nics.contains { $0.network == network.name && $0.ip == network.router }
            }
            let clients = members.filter { $0.name != router?.name }
            for (index, client) in clients.enumerated() {
                let vm = client.name
                if router != nil {
                    append(vm, "route", "\(vm) → default route via \(network.router)", """
                    routes=$(ip route show default 2>/dev/null)
                    routes=$(echo $routes)
                    case " $routes " in
                        *\(quote(" via \(network.router) "))*) printf '%s\\n' 'HLCHECK route ok' ;;
                        *) printf 'HLCHECK route fail %s\\n' "${routes:-no default route}" ;;
                    esac
                    """)
                    probe(vm, "router", "\(vm) → router \(network.router)",
                          command: "ping -c 2 -W 2 \(quote(network.router))", reason: "no reply")
                }
                if clients.count > 1 {
                    let peer = clients[(index + 1) % clients.count].name
                    probe(vm, "peer:\(peer)", "\(vm) → lima-\(peer)",
                          command: "ping -c 2 -W 2 \(quote("lima-" + peer))", reason: "no reply")
                }
            }
            if router != nil, let host = plan.verifyOutside {
                for vm in members where scripts[vm.name]?.checks.contains(where: { $0.id == "outside" }) != true {
                    probe(vm.name, "outside", "\(vm.name) → \(host)",
                          command: "wget -q -T 5 -O /dev/null \(quote("http://" + host))", reason: "wget failed")
                }
            }
        }
        return scripts
    }

    /// Execution errors override output, including any results printed before a timeout.
    public static func results(checks: [TrafficCheck], output: String, runError: String?) -> [TrafficCheckResult] {
        var parsed: [String: [(verified: Bool, reason: String?)]] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, fields[0] == "HLCHECK" else { continue }
            if fields[2] == "ok", fields.count == 3 {
                parsed[String(fields[1]), default: []].append((true, nil))
            } else if fields[2] == "fail", fields.count == 4, !fields[3].isEmpty {
                parsed[String(fields[1]), default: []].append((false, String(fields[3])))
            }
        }
        return checks.map { check in
            if let runError { return .init(check: check, verified: false, reason: runError) }
            // IDs can repeat when a VM belongs to more than one routed network.
            let result = parsed[check.id]?.isEmpty == false ? parsed[check.id]!.removeFirst() : (false, "no result")
            return .init(check: check, verified: result.verified, reason: result.reason)
        }
    }

    public static func summary(_ results: [TrafficCheckResult], outsideGiven: Bool) -> String {
        let unverified = results.filter { !$0.verified }
        var lines = ["verification\tverified=\(results.count - unverified.count)\tunverified=\(unverified.count + (outsideGiven ? 0 : 1))"]
        for result in unverified {
            lines.append(["unverified", result.check.vm, result.check.id, result.reason ?? "no result"].map(cell).joined(separator: "\t"))
        }
        if !outsideGiven { lines.append("unverified\t-\toutside\tno verifyOutside given") }
        return lines.joined(separator: "\n")
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func cell(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
