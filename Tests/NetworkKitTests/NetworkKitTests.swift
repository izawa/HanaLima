import Foundation
import Testing
@testable import NetworkKit

@Suite struct IPv4Tests {
    @Test func parsesAndFormats() {
        #expect(IPv4("192.168.200.1")?.description == "192.168.200.1")
        #expect(IPv4("256.1.1.1") == nil)
        #expect(IPv4("1.2.3") == nil)
        #expect(IPv4("1.2.3.4.5") == nil)
        #expect(IPv4("a.b.c.d") == nil)
        #expect(IPv4.mask(prefixLength: 24).description == "255.255.255.0")
        #expect(IPv4.mask(prefixLength: 20).description == "255.255.240.0")
    }

    @Test func subnets() throws {
        let s = IPv4Subnet(containing: try #require(IPv4("192.168.200.1")), prefixLength: 24)
        #expect(s.description == "192.168.200.0/24")
        #expect(s.broadcast.description == "192.168.200.255")
        #expect(s.contains(IPv4("192.168.200.77")!))
        #expect(!s.contains(IPv4("192.168.201.1")!))
        #expect(s.overlaps(IPv4Subnet(cidr: "192.168.0.0/16")!))
        #expect(!s.overlaps(IPv4Subnet(cidr: "192.168.201.0/24")!))
        #expect(s.isPrivate)
        #expect(!IPv4Subnet(cidr: "8.8.8.0/24")!.isPrivate)
        #expect(IPv4Subnet(cidr: "172.20.0.0/16")!.isPrivate)
    }
}

@Suite struct VirtualNetworkTests {
    @Test func validNetworkPasses() {
        #expect(VirtualNetwork(name: "dev", gateway: "192.168.200.1").validate(against: []).isEmpty)
    }

    @Test func rejectsBadInput() {
        func errors(_ n: VirtualNetwork, others: [VirtualNetwork] = []) -> [VirtualNetwork.ValidationError] {
            n.validate(against: others)
        }
        #expect(errors(VirtualNetwork(name: "Dev")).contains(.invalidName))
        #expect(errors(VirtualNetwork(name: "1dev")).contains(.invalidName))
        #expect(errors(VirtualNetwork(name: "dev-")).contains(.invalidName))
        #expect(errors(VirtualNetwork(name: "dev", gateway: "192.168.200.0")).contains(.gatewayIsNetworkOrBroadcast))
        #expect(errors(VirtualNetwork(name: "dev", gateway: "192.168.200.255")).contains(.gatewayIsNetworkOrBroadcast))
        #expect(errors(VirtualNetwork(name: "dev", gateway: "nope")).contains(.invalidGateway))
        #expect(errors(VirtualNetwork(name: "dev", gateway: "8.8.8.1")).contains(.notPrivate))
        #expect(errors(VirtualNetwork(name: "dev", prefixLength: 30)).contains(.invalidPrefixLength))
        #expect(errors(VirtualNetwork(name: "dev", gateway: "192.168.5.1")).contains(.overlaps("Lima のユーザーモードネットワーク")))
        let other = VirtualNetwork(name: "lab", gateway: "192.168.200.1")
        #expect(errors(VirtualNetwork(name: "dev", gateway: "192.168.200.9"), others: [other])
            == [.overlaps("ネットワーク「lab」")])
        #expect(errors(VirtualNetwork(name: "lab", gateway: "192.168.210.1"), others: [other]).contains(.duplicateName))
    }

    @Test func suggestsFreeSubnet() {
        #expect(VirtualNetwork.suggestedGateway(avoiding: []) == "192.168.200.1")
        let taken = [VirtualNetwork(name: "a", gateway: "192.168.200.1"), VirtualNetwork(name: "b", gateway: "192.168.201.1")]
        #expect(VirtualNetwork.suggestedGateway(avoiding: taken) == "192.168.202.1")
    }

    @Test func bridgedNetworkSkipsAddressing() {
        let lan = VirtualNetwork(name: "lan", mode: .bridged, gateway: "192.168.200.1", bridgedInterface: "en0")
        #expect(lan.subnet == nil)
        #expect(lan.menuDescription == "lan（ブリッジ en0）")
        // It neither needs a subnet nor blocks other networks from using that gateway's subnet.
        #expect(lan.validate(against: []).isEmpty)
        #expect(VirtualNetwork(name: "dev", gateway: "192.168.200.1").validate(against: [lan]).isEmpty)
        #expect(VirtualNetwork(name: "lan2", mode: .bridged, bridgedInterface: "").validate(against: [])
            == [.missingInterface])
        #expect(VirtualNetwork(name: "lan2", mode: .bridged, bridgedInterface: "en0; rm").validate(against: [])
            == [.missingInterface])
    }

    @Test func decodesFilesWithoutBridgedInterface() throws {
        let json = #"{"name":"dev","mode":"shared","gateway":"192.168.200.1","prefixLength":24}"#
        let n = try JSONDecoder().decode(VirtualNetwork.self, from: Data(json.utf8))
        #expect(n.bridgedInterface == "en0")
        #expect(n.reservations.isEmpty)
    }

    @Test func socketPathFitsSunPath() {
        // sockaddr_un.sun_path is 104 bytes including the terminator.
        let n = VirtualNetwork(name: String(repeating: "a", count: 24))
        #expect(n.socketPath.utf8.count < 104)
    }
}

@Suite struct NetworkStoreTests {
    @Test func roundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "hanalima-\(UUID().uuidString)/networks.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try NetworkStore.load(from: url).isEmpty)
        let nets = [VirtualNetwork(name: "zeta", mode: .host, gateway: "10.20.0.1", prefixLength: 16, comment: "x"),
                    VirtualNetwork(name: "alpha")]
        try NetworkStore.save(nets, to: url)
        #expect(try NetworkStore.load(from: url).map(\.name) == ["alpha", "zeta"])
        #expect(try NetworkStore.network(named: "zeta", in: url)?.mode == .host)
    }
}

@Suite struct HelperInstallerTests {
    @Test func installsEachVersionUnderItsOwnName() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "hanalima-helper-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let dir = root.appending(path: "bin")
        let v1 = root.appending(path: "v1"), v2 = root.appending(path: "v2")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: v1)
        try Data("two".utf8).write(to: v2)
        #expect(NetworkPaths.currentHelper(in: dir).lastPathComponent == "hanalima-netd")

        let first = try HelperInstaller.installIfNeeded(from: v1, into: dir)
        #expect(first.lastPathComponent.hasPrefix("hanalima-netd-"))
        #expect(NetworkPaths.currentHelper(in: dir) == first)
        #expect(try HelperInstaller.installIfNeeded(from: v1, into: dir) == first)

        // A new build gets a new file; the old one stays for agents registered against it.
        let second = try HelperInstaller.installIfNeeded(from: v2, into: dir)
        #expect(second != first)
        #expect(NetworkPaths.currentHelper(in: dir) == second)
        #expect(fm.fileExists(atPath: first.path))

        try Data("legacy".utf8).write(to: dir.appending(path: "hanalima-netd"))
        HelperInstaller.removeUnusedCopies(in: dir, inUse: [first.path])
        #expect(fm.fileExists(atPath: first.path))
        #expect(fm.fileExists(atPath: second.path))
        #expect(!fm.fileExists(atPath: dir.appending(path: "hanalima-netd").path))
        HelperInstaller.removeUnusedCopies(in: dir, inUse: [])
        #expect(!fm.fileExists(atPath: first.path))
        #expect(fm.fileExists(atPath: second.path))
    }
}

@Suite struct LaunchAgentTests {
    @Test func plistHasSocketActivation() throws {
        let n = VirtualNetwork(name: "dev")
        let p = LaunchAgentManager().plist(for: n, helper: URL(fileURLWithPath: "/x/hanalima-netd"))
        #expect(p["Label"] as? String == "org.izawa.HanaLima.net.dev")
        #expect(p["ProgramArguments"] as? [String] == ["/x/hanalima-netd", "--network", "dev"])
        let sockets = try #require(p["Sockets"] as? [String: [String: Any]])
        #expect(sockets["Listener"]?["SockPathName"] as? String == n.socketPath)
        #expect(PropertyListSerialization.propertyList(p, isValidFor: .xml))
    }

    @Test func parsesLaunchctlPrint() {
        #expect(LaunchAgentManager.parseState("""
        gui/501/org.izawa.HanaLima.net.dev = {
            state = running
            pid = 4242
        }
        """) == .running(pid: 4242))
        #expect(LaunchAgentManager.parseState("    state = waiting\n") == .waiting)
        #expect(LaunchAgentManager.parseState("    state = waiting\n    last exit code = 1\n") == .failed(exitCode: 1))
        #expect(LaunchAgentManager.parseState("    state = waiting\n    last exit code = (never exited)\n") == .waiting)
        #expect(LaunchAgentManager.parseState("    state = waiting\n    last exit code = 0\n") == .waiting)
    }
}

@Suite struct DHCPLeasesTests {
    static let sample = """
    {
    	name=lima-dev
    	ip_address=192.168.200.3
    	hw_address=ff,55:d3:dd:1f:0:1
    	identifier=ff,55:d3:dd:1f:0:1
    	lease=0x6ac8ab5d
    }
    {
    	name=lima-dev
    	ip_address=192.168.200.2
    	hw_address=1,52:55:55:d3:dd:1f
    	identifier=1,52:55:55:d3:dd:1f
    	lease=0x6ac80000
    }
    {
    	name=other-host
    	ip_address=192.168.64.5
    	hw_address=1,aa:bb:cc:dd:ee:ff
    	lease=0x6ac8ab5d
    }
    """

    @Test func parsesLeases() {
        let leases = DHCPLeases.parse(Self.sample)
        #expect(leases.count == 3)
        #expect(leases[0].limaInstance == "dev")
        #expect(leases[2].limaInstance == nil)
        #expect(leases[0].expires == Date(timeIntervalSince1970: 0x6ac8ab5d))
    }

    @Test func picksNewestLeaseInSubnet() {
        let leases = DHCPLeases.parse(Self.sample)
        #expect(DHCPLeases.address(of: "dev", in: IPv4Subnet(cidr: "192.168.200.0/24")!, leases: leases) == "192.168.200.3")
        #expect(DHCPLeases.address(of: "dev", in: IPv4Subnet(cidr: "192.168.201.0/24")!, leases: leases) == nil)
    }

    @Test func readsSystemLeaseFile() {
        // World-readable on macOS; may be empty on a fresh machine.
        _ = DHCPLeases.load()
    }
}

@Suite struct NetworkConflictTests {
    typealias A = NetworkConflict.Attachment

    @Test func singleKindIsFine() {
        #expect(NetworkConflict.check(vm: "a", attachments: [.legacyVmnet("bridged")], running: []) == nil)
        #expect(NetworkConflict.check(vm: "a", attachments: [.virtualNetwork("demo"), .other], running: []) == nil)
        #expect(NetworkConflict.check(vm: "a", attachments: [.legacyVmnet("shared"), .legacyVmnet("bridged")],
                                      running: [("b", [.legacyVmnet("bridged")])]) == nil)
    }

    @Test func mixedOnOneVM() throws {
        let c = try #require(NetworkConflict.check(vm: "a", attachments: [.virtualNetwork("demo"), .legacyVmnet("bridged")],
                                                   running: []))
        #expect(c.legacyNetworks == ["bridged"])
        #expect(c.virtualNetworks == ["demo"])
        #expect(c.runningVMs.isEmpty)
        #expect(c.message.contains("「a」自身"))
    }

    @Test func mixedAcrossVMs() throws {
        let running: [(name: String, attachments: [A])] = [
            ("web", [.virtualNetwork("demo")]), ("db", [.other]), ("lab", [.virtualNetwork("lab")]),
        ]
        let c = try #require(NetworkConflict.check(vm: "router", attachments: [.legacyVmnet("bridged")], running: running))
        #expect(c.runningVMs == ["web", "lab"])
        #expect(c.virtualNetworks == ["demo", "lab"])

        let back = try #require(NetworkConflict.check(vm: "web", attachments: [.virtualNetwork("demo")],
                                                      running: [("router", [.legacyVmnet("bridged")])]))
        #expect(back.runningVMs == ["router"])
    }

    @Test func ignoresItselfInRunningList() {
        // Restarting a VM: it appears in the running list with its own NICs.
        #expect(NetworkConflict.check(vm: "a", attachments: [.virtualNetwork("demo")],
                                      running: [("a", [.virtualNetwork("demo")])]) == nil)
    }
}
