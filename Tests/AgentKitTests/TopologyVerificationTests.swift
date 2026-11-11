import Foundation
import Testing
import AgentKit
import LimaKit
import MCPKit

private func verificationPlan(outside: String? = nil) -> TopologyPlan {
    let spec = TopologySpec(verifyOutside: outside,
                            networks: [.init(ref: "lan", mode: "guestOnly", cidr: "10.20.0.0/24", router: "gw")],
                            vms: [.init(ref: "c1", nics: [.init(network: "lan")]),
                                  .init(ref: "gw", nics: [.init(network: "lan", ip: "10.20.0.1")]),
                                  .init(ref: "c2", nics: [.init(network: "lan")])])
    let facts = PlannerFacts(vms: [], networks: [], ownedNetworks: [], templates: [.init(name: "default")],
                             physicalMemory: 16 * 1_073_741_824, runningMemory: 0, hasDriver: true)
    return TopologyPlanner.plan(spec, facts: facts)
}

@Test func trafficChecksForTrial() throws {
    let plan = verificationPlan(outside: "example.com")
    #expect(plan.problems.isEmpty)
    #expect(plan.verifyOutside == "example.com")
    let scripts = TopologyVerification.scripts(for: plan)
    #expect(Set(scripts.keys) == ["gw", "c1", "c2"])
    #expect(scripts["gw"]?.checks.map(\.id) == ["outside"])
    #expect(scripts["c1"]?.checks.map(\.id) == ["route", "router", "peer:c2", "outside"])
    #expect(scripts["c2"]?.checks.map(\.id) == ["route", "router", "peer:c1", "outside"])
    let client = try #require(scripts["c1"])
    #expect(client.checks.allSatisfy { $0.vm == "c1" })
    #expect(client.checks[1].description == "c1 → router 10.20.0.1")
    #expect(client.script.contains("ip route show default"))
    #expect(client.script.contains("' via 10.20.0.1 '"))
    #expect(client.script.contains("ping -c 2 -W 2 '10.20.0.1'"))
    #expect(client.script.contains("ping -c 2 -W 2 'lima-c2'"))
    #expect(client.script.contains("wget -q -T 5 -O /dev/null 'http://example.com'"))
    let local = TopologyVerification.scripts(for: verificationPlan())
    #expect(local["gw"] == nil)
    #expect(local["c1"]?.checks.map(\.id) == ["route", "router", "peer:c2"])
    #expect(local["c2"]?.checks.map(\.id) == ["route", "router", "peer:c1"])
    #expect(local.values.allSatisfy { !$0.script.contains("wget") })
}

@Test func trafficChecksWithoutRouterAndWithSingleClient() {
    var plan = verificationPlan(outside: "example.com")
    plan.networks[0].network.router = ""
    let scripts = TopologyVerification.scripts(for: plan)
    #expect(scripts["gw"]?.checks.map(\.id) == ["peer:c1"])
    #expect(scripts["c1"]?.checks.map(\.id) == ["peer:c2"])
    #expect(scripts["c2"]?.checks.map(\.id) == ["peer:gw"])
    plan.vms.removeAll { $0.name != "c1" }
    #expect(TopologyVerification.scripts(for: plan).isEmpty)
    plan = verificationPlan()
    plan.vms.removeAll { $0.name == "c2" }
    #expect(TopologyVerification.scripts(for: plan)["c1"]?.checks.map(\.id) == ["route", "router"])
}

@Test func trafficResultParsing() throws {
    let checks = try #require(TopologyVerification.scripts(for: verificationPlan(outside: "example.com"))["c1"]?.checks)
    let output = """
    login noise
    HLCHECK unknown ok
    HLCHECK route ok
    HLCHECK router fail no reply
    HLCHECK peer:c2 ok trailing junk
    HLCHECK outside fail wget failed
    """
    let results = TopologyVerification.results(checks: checks, output: output, runError: nil)
    #expect(results == [.init(check: checks[0], verified: true),
                        .init(check: checks[1], verified: false, reason: "no reply"),
                        .init(check: checks[2], verified: false, reason: "no result"),
                        .init(check: checks[3], verified: false, reason: "wget failed")])
    for error in ["exec failed", "timed out"] {
        #expect(TopologyVerification.results(checks: checks, output: output, runError: error)
            == checks.map { .init(check: $0, verified: false, reason: error) })
    }
    #expect(TopologyVerification.results(checks: checks, output: "", runError: nil)
        == checks.map { .init(check: $0, verified: false, reason: "no result") })
}

@Test func trafficResultsForRepeatedIDs() {
    let checks = [TrafficCheck(vm: "c1", id: "route", description: "first network"),
                  TrafficCheck(vm: "c1", id: "route", description: "second network"),
                  TrafficCheck(vm: "c1", id: "route", description: "third network")]
    let results = TopologyVerification.results(checks: checks,
                                              output: "HLCHECK route fail wrong route\nHLCHECK route ok\n", runError: nil)
    #expect(results == [.init(check: checks[0], verified: false, reason: "wrong route"),
                        .init(check: checks[1], verified: true),
                        .init(check: checks[2], verified: false, reason: "no result")])
}

@Test func trafficSummary() {
    let checks = [TrafficCheck(vm: "c1", id: "router", description: "router"),
                  TrafficCheck(vm: "c2", id: "outside", description: "outside")]
    let results = [TrafficCheckResult(check: checks[0], verified: true),
                   TrafficCheckResult(check: checks[1], verified: false, reason: "wget failed")]
    #expect(TopologyVerification.summary(results, outsideGiven: true)
        == "verification\tverified=1\tunverified=1\nunverified\tc2\toutside\twget failed")
    #expect(TopologyVerification.summary(results, outsideGiven: false)
        == "verification\tverified=1\tunverified=2\nunverified\tc2\toutside\twget failed\nunverified\t-\toutside\tno verifyOutside given")
    #expect(TopologyVerification.summary([], outsideGiven: true) == "verification\tverified=0\tunverified=0")
    #expect(TopologyVerification.summary([.init(check: checks[0], verified: false, reason: "a\tb\nc\r")], outsideGiven: true)
        == "verification\tverified=0\tunverified=1\nunverified\tc1\trouter\ta\\tb\\nc\\r")
}

@Test(arguments: ["example.com", "Host-1.example.com", "10.20.0.1", String(repeating: "a", count: 253)])
func decodeVerifyOutside(host: String) throws {
    let decoded = TopologySpec.decode(["verifyOutside": .string(host)])
    #expect(decoded.problems.isEmpty)
    #expect(try #require(decoded.spec).verifyOutside == host)
}

@Test(arguments: ["", "-host", "https://example.com", "a/b", "a b", "a\n", "a'", "a;id", "$(id)", "é", "a_b", String(repeating: "a", count: 254)])
func rejectInvalidVerifyOutside(host: String) {
    let decoded = TopologySpec.decode(["verifyOutside": .string(host)])
    #expect(decoded.spec == nil)
    #expect(decoded.problems.contains { $0.code == "INVALID" && $0.path == "/verifyOutside" })
}

@Test func verifyOutsideTypesAndFingerprint() {
    for value: MCPKit.JSONValue in [.null, 1, .bool(true), .array([])] {
        #expect(TopologySpec.decode(["verifyOutside": value]).problems.contains { $0.path == "/verifyOutside" })
    }
    #expect(TopologySpec.decode([:]).spec?.verifyOutside == nil)
    let plan = verificationPlan()
    let outside = verificationPlan(outside: "example.com")
    #expect(plan.fingerprint != outside.fingerprint)
    #expect(outside.fingerprint != verificationPlan(outside: "other.example.com").fingerprint)
    #expect(outside.text(planID: "p", expires: .distantFuture)
        .hasSuffix("verify\tconfig, boot, DHCP lease, traffic (outside: example.com)"))
    var spec = TopologySpec(verifyOutside: "-invalid")
    spec.vms = [.init(ref: "c1")]
    let facts = PlannerFacts(vms: [], networks: [], ownedNetworks: [], templates: [.init(name: "default")],
                             physicalMemory: 16 * 1_073_741_824, runningMemory: 0, hasDriver: true)
    #expect(TopologyPlanner.plan(spec, facts: facts).problems.contains { $0.path == "/verifyOutside" })
}

/// Exercise the generated POSIX script with command stubs, without accessing a guest or network.
@Test func trafficScriptExecution() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let commands = [
        "ip": "#!/bin/sh\nprintf '%s\\n' \"$TEST_ROUTE\"\n",
        "ping": "#!/bin/sh\nexit \"$TEST_PING_STATUS\"\n",
        "wget": "#!/bin/sh\nexit \"$TEST_WGET_STATUS\"\n"
    ]
    for (name, script) in commands {
        let file = directory.appendingPathComponent(name)
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
    }
    let generated = try #require(TopologyVerification.scripts(for: verificationPlan(outside: "example.com"))["c1"])
    let scriptURL = directory.appendingPathComponent("checks.sh")
    try generated.script.write(to: scriptURL, atomically: true, encoding: .utf8)
    for (route, ping, wget, expected) in [
        ("default via 10.20.0.1 dev eth0", "0", "0", [true, true, true, true]),
        ("default via 10.20.0.10 dev eth0", "1", "1", [false, false, false, false]),
        ("default via 10.21.0.1 dev eth0\ndefault via 10.20.0.1 dev eth1", "0", "1", [true, true, true, false]),
        ("", "0", "0", [false, true, true, true])
    ] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.environment = ["PATH": directory.path, "TEST_ROUTE": route, "TEST_PING_STATUS": ping, "TEST_WGET_STATUS": wget]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.split(separator: "\n").count == generated.checks.count)
        let results = TopologyVerification.results(checks: generated.checks, output: text, runError: nil)
        #expect(results.map(\.verified) == expected)
        if expected[0] == false { #expect(results[0].reason == (route.isEmpty ? "no default route" : route)) }
    }
}
