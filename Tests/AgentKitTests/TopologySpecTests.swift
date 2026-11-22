import CryptoKit
import Foundation
import Testing
import AgentKit
import LimaKit
import MCPKit
import NetworkKit

private func facts() -> PlannerFacts {
    .init(vms: [], networks: [], ownedNetworks: [],
          templates: [.init(name: "default", resolvedImage: "ubuntu-26.04"), .init(name: "ubuntu-26.04"),
                      .init(name: "alpine", resolvedImage: "alpine-3.24"), .init(name: "alpine-3.24")],
          physicalMemory: 16 * 1_073_741_824, runningMemory: 0, hasDriver: true)
}

private func trial(bootstrap: Bool = true) -> TopologySpec {
    .init(group: "small-lab", defaults: .init(template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 10, usernet: false),
          networks: [.init(ref: "inner", mode: "guestOnly", cidr: "10.20.0.0/24", router: "router")],
          vms: [.init(ref: "client1", bootstrapUsernet: bootstrap, nics: [.init(network: "inner")]),
                .init(ref: "router", usernet: true, nics: [.init(network: "inner", ip: "10.20.0.1")], gatewayAllow: ["*", "example.com"]),
                .init(ref: "client2", bootstrapUsernet: bootstrap, nics: [.init(network: "inner", ip: "10.20.0.3")])],
          assumptions: [.init(path: "/defaults", reason: "Small lab")])
}

@Test func decodeValidDeclaration() throws {
    let json = try MCPKit.JSONValue.parse(#"""
    {"group":"small-lab","defaults":{"template":"alpine","cpus":1,"memoryGiB":1,"diskGiB":10,"usernet":false},
     "networks":[{"ref":"inner","mode":"guestOnly","cidr":"10.20.0.0/24","router":"router"}],
     "vms":[{"ref":"router","usernet":true,"nics":[{"network":"inner","ip":"10.20.0.1"}],"gateway":{"allow":["*"]}},
            {"ref":"client","bootstrapUsernet":true,"nics":[{"network":"inner"}]}],
     "assumptions":[{"path":"/defaults","reason":"Small lab"}]}
    """#)
    let decoded = TopologySpec.decode(json)
    #expect(decoded.problems.isEmpty)
    let spec = try #require(decoded.spec)
    #expect(spec.defaults.cpus == 1)
    #expect(spec.vms[1].bootstrapUsernet)
    #expect(spec.vms[0].gatewayAllow == ["*"])
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.isEmpty)
}

@Test(arguments: [
    (#"{"x/y~z":1}"#, "/x~1y~0z"),
    (#"{"defaults":{"extra":true}}"#, "/defaults/extra"),
    (#"{"networks":[{"ref":"n","mode":"guestOnly","cidr":"10.20.0.0/24","extra":1}]}"#, "/networks/0/extra"),
    (#"{"vms":[{"ref":"a","extra":1}]}"#, "/vms/0/extra"),
    (#"{"vms":[{"ref":"a","nics":[{"network":"n","extra":1}]}]}"#, "/vms/0/nics/0/extra"),
    (#"{"vms":[{"ref":"a","gateway":{"allow":[],"extra":1}}]}"#, "/vms/0/gateway/extra"),
    (#"{"assumptions":[{"path":"/a","reason":"b","extra":1}]}"#, "/assumptions/0/extra")
]) func decodeUnknownKeys(input: String, path: String) throws {
    let result = TopologySpec.decode(try MCPKit.JSONValue.parse(input))
    #expect(result.spec == nil)
    #expect(result.problems.contains { $0.code == "INVALID" && $0.path == path })
}

@Test(arguments: [
    ("[]", ""), (#"{"group":null}"#, "/group"), (#"{"defaults":[]}"#, "/defaults"),
    (#"{"defaults":{"cpus":1.5}}"#, "/defaults/cpus"), (#"{"defaults":{"memoryGiB":"1"}}"#, "/defaults/memoryGiB"),
    (#"{"defaults":{"diskGiB":true}}"#, "/defaults/diskGiB"), (#"{"defaults":{"usernet":1}}"#, "/defaults/usernet"),
    (#"{"networks":{}}"#, "/networks"), (#"{"networks":[{}]}"#, "/networks/0/ref"),
    (#"{"vms":[{"ref":1}]}"#, "/vms/0/ref"), (#"{"vms":[{"ref":"a","bootstrapUsernet":"true"}]}"#, "/vms/0/bootstrapUsernet"),
    (#"{"vms":[{"ref":"a","nics":{}}]}"#, "/vms/0/nics"),
    (#"{"vms":[{"ref":"a","nics":[{"network":"n","ip":1}]}]}"#, "/vms/0/nics/0/ip"),
    (#"{"vms":[{"ref":"a","gateway":{"allow":[true]}}]}"#, "/vms/0/gateway/allow/0"),
    (#"{"assumptions":[{"path":false,"reason":"a"}]}"#, "/assumptions/0/path")
]) func decodeTypes(input: String, path: String) throws {
    let result = TopologySpec.decode(try MCPKit.JSONValue.parse(input))
    #expect(result.spec == nil)
    #expect(result.problems.contains { $0.code == "INVALID" && $0.path == path })
}

@Test func decodeLimitsAndMode() {
    let tooManyVMs = MCPKit.JSONValue.object(["vms": .array((0..<17).map { .object(["ref": .string("vm\($0)")]) })])
    #expect(TopologySpec.decode(tooManyVMs).problems.contains { $0.path == "/vms" })
    let tooManyNetworks = MCPKit.JSONValue.object(["networks": .array((0..<5).map {
        .object(["ref": .string("net\($0)"), "mode": "guestOnly", "cidr": "10.20.0.0/24"])
    })])
    #expect(TopologySpec.decode(tooManyNetworks).problems.contains { $0.path == "/networks" })
    #expect(TopologySpec.decode(["vms": [["ref": "a", "usernet": false]]]).problems.contains { $0.path == "/vms/0/nics" })
    #expect(TopologySpec.decode(["vms": [["ref": "a", "usernet": true]]]).problems.isEmpty)
    let mode = TopologySpec.decode(["networks": [["ref": "n", "mode": "bridged", "cidr": "10.20.0.0/24"]]])
    #expect(mode.problems.contains { $0.code == "UNSUPPORTED" && $0.alternative == "guestOnly; bridges and other modes are made in the app" })
    #expect(TopologySpec.decode(["defaults": ["cpus": 0, "memoryGiB": -1, "diskGiB": 0]]).problems.count == 3)
}

@Test func trialRequiresExplicitBootstrap() {
    let plan = TopologyPlanner.plan(trial(bootstrap: false), facts: facts())
    #expect(plan.problems.count == 2)
    #expect(plan.problems.allSatisfy { $0.code == "UNSUPPORTED" && $0.path.hasSuffix("/bootstrapUsernet") })
    #expect(plan.problems.allSatisfy { $0.alternative?.contains("ubuntu-26.04") == true })
    #expect(plan.vms.count == 3)
    #expect(plan.networks.count == 1)
}

@Test func trialReadyAndDeterministic() throws {
    let plan = TopologyPlanner.plan(trial(), facts: facts())
    #expect(plan.problems.isEmpty)
    #expect(plan.approvals.isEmpty)
    #expect(plan.vms.map(\.name) == ["router", "client1", "client2"])
    #expect(plan == TopologyPlanner.plan(trial(), facts: facts()))
    let network = try #require(plan.networks.first?.network)
    #expect(network.gateway == "10.20.0.254")
    #expect(network.router == "10.20.0.1")
    #expect(network.reservations.count == 2)
    #expect(network.validate(against: []).isEmpty)
    #expect(network.reservations.first { $0.comment == "router" }?.ip == "10.20.0.1")
    #expect(plan.filled.contains("dhcpServer[inner]=10.20.0.254"))
    #expect(plan.filled.contains("shares=none"))
    for vm in plan.vms {
        #expect(vm.template == "alpine-3.24")
        #expect(vm.options.template == vm.template)
        #expect(vm.options.mountNone && vm.options.vmType == .hanalima)
        let nic = try #require(vm.nics.first)
        let digest = SHA256.hash(data: Data((vm.name + "/inner").utf8))
        #expect(nic.mac == "52:55:55:" + digest.prefix(3).map { String(format: "%02x", $0) }.joined(separator: ":"))
        let expression = try #require(vm.options.setExpressions.first { $0.hasPrefix(".networks += ") })
        let entries = try MCPKit.JSONValue.parse(String(expression.dropFirst(".networks += ".count)))
        #expect(entries.arrayValue?.first?["macAddress"]?.stringValue == nic.mac)
        #expect(entries.arrayValue?.first?["socket"]?.stringValue == network.socketPath)
        #expect(!vm.options.setExpressions.contains(".vmOpts.hanalima.usernet = false"))
    }
    let router = try #require(plan.vms.first)
    let expression = try #require(router.options.setExpressions.first { $0.hasPrefix(".provision += ") })
    let entries = try #require(try MCPKit.JSONValue.parse(String(expression.dropFirst(".provision += ".count))).arrayValue)
    #expect(entries.first?["content"]?.stringValue == "*\nexample.com\n")
    #expect(entries.first?["path"]?.stringValue == "/etc/hanalima/gateway.conf")
    #expect(entries.count == ProvisionExamples.example(.gateway).entries.count)
    #expect(entries.last?["script"]?.stringValue == ProvisionExamples.example(.gateway).entries.last?.script)
}

@Test func conflictsAndAlternatives() throws {
    var f = facts()
    f.networks = [.init(name: "taken", gateway: "10.20.0.1")]
    let overlap = TopologyPlanner.plan(trial(), facts: f)
    let p = try #require(overlap.problems.first { $0.code == "CONFLICT" && $0.path == "/networks/0/cidr" })
    #expect(p.alternative == "10.21.0.0/24")
    #expect(!IPv4Subnet(cidr: p.alternative!)!.overlaps(f.networks[0].subnet!))
    var spec = trial()
    spec.networks[0].cidr = "10.20.0.0/8"
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.contains { $0.code == "UNSUPPORTED" && $0.alternative == "10.20.0.0/16" })
    f = facts()
    f.vms = [.init(name: "router", id: nil, ownedByMCP: false), .init(name: "router-2", id: nil, ownedByMCP: false)]
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.contains { $0.code == "CONFLICT" && $0.message == "name taken" && $0.alternative == "router-3" })
}

/// What `facts()` would say about a VM MCP made from `vm` (and still as made).
private func made(_ vm: TopologyPlan.PlannedVM, usernet: Bool? = nil, group: String? = "small-lab",
                  bootstrapPending: Bool = false) -> PlannerFacts.ExistingVM {
    // A bootstrap VM's build removed NIC 0 after its first boot.
    let usesUsernet = usernet ?? !(vm.bootstrapUsernet || vm.options.setExpressions.contains(".vmOpts.hanalima.usernet = false"))
    return .init(name: vm.name, id: UUID(), ownedByMCP: true,
                 made: .init(fingerprint: vm.fingerprint, madeSettings: "s1", settings: "s1", usernet: usesUsernet,
                             group: group, bootstrapPending: bootstrapPending))
}

@Test func anExistingVMIsReusedOnlyForTheSameDeclaration() throws {
    let first = TopologyPlanner.plan(trial(), facts: facts())
    var f = facts()
    f.vms = first.vms.map { made($0) }
    let network = try #require(first.networks.first?.network)
    f.networks = [network]
    f.ownedNetworks = ["inner"]
    let replay = TopologyPlanner.plan(trial(), facts: f)
    #expect(replay.problems.isEmpty)
    #expect(replay.vms.allSatisfy { $0.action == .unchanged })
    #expect(replay.networks.first?.action == .unchanged && replay.networks.first?.network == network)

    // A bootstrap VM interrupted before NIC 0 came off is still the same VM: apply finishes it.
    f.vms[1] = made(first.vms[1], usernet: true, bootstrapPending: true)
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.isEmpty)
    // Once it was done, a NIC 0 attached again is a person's change, not left to finish.
    f.vms[1] = made(first.vms[1], usernet: true)
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.contains { $0.message.contains("NIC 0 is attached now") })
    f.vms[1] = made(first.vms[1])

    // A different declaration for the same name: the template, a size, the gateway's allow list.
    for change in [{ (s: inout TopologySpec) in s.vms[1].template = "ubuntu-26.04" },
                   { s in s.defaults.cpus = 2 },
                   { s in s.vms[1].gatewayAllow = ["*"] }] {
        var spec = trial()
        change(&spec)
        let plan = TopologyPlanner.plan(spec, facts: f)
        #expect(plan.problems.contains { $0.code == "CONFLICT" && $0.message.contains("different declaration")
            && $0.alternative?.contains("delete router") == true }, "\(plan.problems)")
    }

    // The same declaration, but the VM was changed since (by a person) or made before the record.
    var changed = f
    changed.vms[0].made?.settings = "s2"
    #expect(TopologyPlanner.plan(trial(), facts: changed).problems.contains { $0.message.contains("was changed since it was made") })
    changed = f
    changed.vms[0].made?.madeSettings = nil
    #expect(TopologyPlanner.plan(trial(), facts: changed).problems.contains { $0.message.contains("can't be compared") })
    changed = f
    changed.vms[0].made?.usernet = false  // the router keeps NIC 0
    #expect(TopologyPlanner.plan(trial(), facts: changed).problems.contains { $0.message.contains("NIC 0 was removed") })
    changed = f
    changed.vms[0].made?.fingerprint = nil
    #expect(TopologyPlanner.plan(trial(), facts: changed).problems.contains { $0.message.contains("before HanaLima recorded") })
    changed = f
    changed.vms[0].made?.group = "Small-Lab"  // a group's spelling changed: the same group
    #expect(TopologyPlanner.plan(trial(), facts: changed).problems.isEmpty)
    var regrouped = trial()
    regrouped.group = "other-lab"
    #expect(TopologyPlanner.plan(regrouped, facts: f).problems.contains { $0.message.contains("is in group small-lab") })
    var ungrouped = trial()
    ungrouped.group = nil
    #expect(TopologyPlanner.plan(ungrouped, facts: f).problems.contains { $0.message.contains("declared none") })
    var unloaded = f
    unloaded.templates = []  // the list failed to load: not a different declaration
    #expect(TopologyPlanner.plan(trial(), facts: unloaded).problems.contains { $0.message.contains("can't be resolved now") })
    var flipped = trial()
    flipped.vms[0].usernet = true  // with bootstrapUsernet: refused for an existing VM too
    #expect(TopologyPlanner.plan(flipped, facts: f).problems.contains { $0.path == "/vms/0/bootstrapUsernet" })
}

@Test func anExistingNetworkIsReusedOnlyAsDeclared() throws {
    let first = TopologyPlanner.plan(trial(), facts: facts())
    let network = try #require(first.networks.first?.network)
    var f = facts()
    f.networks = [network]
    f.ownedNetworks = ["inner"]
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.isEmpty)  // the network made, no VM yet

    var spec = trial()
    spec.networks[0].cidr = "10.21.0.0/24"
    spec.vms[1].nics[0].ip = "10.21.0.1"
    spec.vms[2].nics[0].ip = "10.21.0.3"
    #expect(TopologyPlanner.plan(spec, facts: f).problems.contains { $0.path == "/networks/0/cidr" && $0.alternative == "10.20.0.0/24" })
    spec = trial()
    spec.networks[0].router = nil
    #expect(TopologyPlanner.plan(spec, facts: f).problems.contains { $0.path == "/networks/0/router" })
    spec = trial()
    spec.vms[2].nics[0].ip = nil  // client2's reserved address, now declared without one
    #expect(TopologyPlanner.plan(spec, facts: f).problems.contains {
        $0.path == "/vms/2/nics/0/ip" && $0.message.contains("declared without an ip") && $0.alternative == "10.20.0.3" })
    f.networks[0].reservations.removeAll()
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.contains { $0.code == "CONFLICT" && $0.message.contains("missing reservation") })
    f.ownedNetworks = []
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.contains { $0.code == "CONFLICT" && $0.path == "/networks/0/ref" })
}

@Test func memoryApprovalCountsOnlyCreates() {
    var f = facts()
    f.physicalMemory = 4 * 1_073_741_824
    f.runningMemory = 2 * 1_073_741_824
    let plan = TopologyPlanner.plan(trial(), facts: f)
    #expect(plan.problems.isEmpty)
    #expect(plan.approvals.count == 1)
    #expect(plan.approvals[0].hasPrefix("memory: "))
    f.vms = TopologyPlanner.plan(trial(), facts: facts()).vms.filter { $0.name == "router" }.map { made($0) }
    #expect(TopologyPlanner.plan(trial(), facts: f).approvals.isEmpty)
    let defaults = TopologyPlanner.plan(.init(vms: [.init(ref: "a")]), facts: f)
    #expect(defaults.vms.first?.memoryBytes == Int64(4_294_967_296))
    #expect(defaults.approvals.count == 1)
}

@Test func invalidReferencesAndAddresses() {
    var spec = trial()
    spec.vms[0].nics = [.init(network: "missing")]
    spec.vms[2].nics[0].ip = "10.20.0.1"
    var plan = TopologyPlanner.plan(spec, facts: facts())
    #expect(plan.problems.contains { $0.path == "/vms/0/nics/0/network" })
    #expect(plan.problems.contains { $0.message == "Duplicate IP on this network" })
    spec = trial()
    spec.vms[1].nics[0].ip = nil
    plan = TopologyPlanner.plan(spec, facts: facts())
    #expect(plan.problems.contains { $0.path == "/networks/0/router" && $0.alternative == "give it an ip" })
    spec = trial()
    spec.vms[2].nics[0].ip = "10.20.0.254"
    plan = TopologyPlanner.plan(spec, facts: facts())
    #expect(plan.problems.isEmpty)
    #expect(plan.networks.first?.network.gateway == "10.20.0.253")
    for ip in ["10.20.0.0", "10.20.0.255", "10.21.0.1", "invalid"] {
        spec.vms[2].nics[0].ip = ip
        #expect(TopologyPlanner.plan(spec, facts: facts()).problems.contains { $0.path == "/vms/2/nics/0/ip" })
    }
}

@Test func usernetRulesAndDefaults() {
    var f = facts()
    f.hasDriver = false
    #expect(TopologyPlanner.plan(trial(), facts: f).problems.contains { $0.code == "UNSUPPORTED" && $0.path == "/vms/0/usernet" })
    var spec = trial()
    spec.vms[1].bootstrapUsernet = true
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.contains { $0.code == "INVALID" && $0.path == "/vms/1/bootstrapUsernet" })
    spec.vms[1].bootstrapUsernet = false
    spec.vms[1].usernet = false
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.contains { $0.code == "UNSUPPORTED" && $0.path == "/vms/1/gateway" })
    spec.defaults.template = "ubuntu-26.04"
    spec.vms[0].bootstrapUsernet = false
    let vm = TopologyPlanner.plan(spec, facts: facts()).vms.first { $0.name == "client1" }
    #expect(vm?.options.setExpressions.contains(".vmOpts.hanalima.usernet = false") == true)
    let defaults = TopologyPlanner.plan(.init(vms: [.init(ref: "plain")]), facts: facts())
    #expect(defaults.problems.isEmpty)
    #expect(defaults.vms[0].options.cpus == nil)
    #expect(defaults.vms[0].template == "ubuntu-26.04")
}

@Test func namesDuplicatesAndNetworkValidation() {
    var spec = trial()
    spec.group = String(repeating: "a", count: 41)
    spec.vms[0].ref = "Bad_name"
    spec.networks[0].ref = "bad-"
    let invalid = TopologyPlanner.plan(spec, facts: facts())
    #expect(invalid.problems.contains { $0.path == "/group" })
    #expect(invalid.problems.contains { $0.path == "/vms/0/ref" })
    #expect(invalid.problems.contains { $0.path == "/networks/0/ref" })
    spec = trial()
    spec.vms.append(spec.vms[0])
    spec.networks.append(spec.networks[0])
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.filter { $0.message.hasPrefix("Duplicate") }.count >= 2)
    spec = trial()
    spec.networks[0].cidr = "192.168.5.0/24"
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.contains { $0.code == "CONFLICT" && $0.path == "/networks/0/cidr" })
    spec.networks[0].cidr = "8.8.8.0/24"
    #expect(TopologyPlanner.plan(spec, facts: facts()).problems.contains { $0.code == "INVALID" && $0.path == "/networks/0/cidr" })
}

@Test func textAndFingerprint() {
    let plan = TopologyPlanner.plan(trial(), facts: facts())
    let date = Date(timeIntervalSince1970: 0)
    let text = plan.text(planID: "p1", expires: date)
    #expect(text.hasPrefix("plan p1\tready\texpires=1970-01-01T00:00:00Z\naction\ttarget\tdetail\ncreate\tinner\tguestOnly 10.20.0.0/24 router=10.20.0.1 dhcp=10.20.0.254"))
    #expect(text.contains("create\trouter\talpine-3.24 1cpu 1GiB nics=inner:10.20.0.1 usernet=on gateway"))
    #expect(text.contains("nics=inner:dhcp usernet=bootstrap→off"))
    #expect(text.contains("order\trouter → client1 → client2"))
    #expect(text.contains("filled\tdriver=hanalima; shares=none;"))
    #expect(text.contains("assumption\t/defaults\tSmall lab"))
    #expect(text.contains("approval\tnone"))
    #expect(text.hasSuffix("verify\tconfig, boot, DHCP lease, traffic (outside: not checked; give verifyOutside)"))
    let blocked = TopologyPlanner.plan(trial(bootstrap: false), facts: facts()).text(planID: "p2", expires: date)
    #expect(blocked.contains("plan p2\tblocked"))
    #expect(blocked.contains("problem\tUNSUPPORTED\t/vms/0/bootstrapUsernet\t"))
    #expect(blocked.contains("\talternative: set bootstrapUsernet: true"))
    #expect(plan.fingerprint.count == 64)
    #expect(plan.fingerprint == TopologyPlanner.plan(trial(), facts: facts()).fingerprint)
    var changed = plan
    changed.vms[0].options.cpus = 2
    #expect(changed.fingerprint != plan.fingerprint)
    changed = plan
    changed.group = "other"
    #expect(changed.fingerprint != plan.fingerprint)
    changed = plan
    changed.networks[0].network.router = "10.20.0.2"
    #expect(changed.fingerprint != plan.fingerprint)
    changed = plan
    changed.assumptions = [.init(path: "/x", reason: "a\tb\nc")]
    #expect(changed.fingerprint == plan.fingerprint)
    #expect(changed.text(planID: "p", expires: date).contains("assumption\t/x\ta\\tb\\nc"))
}
