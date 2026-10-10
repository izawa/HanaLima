import Foundation
import Testing
@testable import LimaKit

@Suite struct JSONValueTests {
    @Test func parsesYAMLScalarsByType() throws {
        let v = try JSONValue.parseYAML("""
        cpus: 2
        memory: 4GiB
        ratio: 1.5
        on: true
        nothing: null
        quoted: "8"
        list: [a, 1]
        """)
        #expect(v["cpus"] == .int(2))
        #expect(v["memory"] == .string("4GiB"))
        #expect(v["ratio"] == .double(1.5))
        #expect(v["on"] == .bool(true))
        #expect(v["nothing"] == .null)
        #expect(v["quoted"] == .string("8"))
        #expect(v["list"] == .array([.string("a"), .int(1)]))
    }

    @Test func jsonTextEscapesAndSortsKeys() {
        let v = JSONValue.object(["b": .string("x\"y\n"), "a": .array([.int(1), .bool(false), .null])])
        #expect(v.jsonText == #"{"a":[1,false,null],"b":"x\"y\n"}"#)
    }

    @Test func roundTripsThroughJSONDecoder() throws {
        let v = JSONValue.object(["n": .int(3), "s": .string("x"), "f": .double(2.5)])
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(v.jsonText.utf8))
        #expect(decoded == v)
    }
}

@Suite struct ByteSizeTests {
    @Test(arguments: [("4GiB", Int64(4) << 30), ("4G", Int64(4) << 30), ("512MiB", Int64(512) << 20),
                      ("100GB", Int64(100) << 30), ("1.5GiB", Int64(3) << 29), ("1024", Int64(1024))])
    func parses(text: String, bytes: Int64) {
        #expect(ByteSize.parse(text) == bytes)
    }

    @Test func gibRoundTrip() {
        #expect(ByteSize.gibValue("10GiB") == 10)
        #expect(ByteSize.gib(10) == "10GiB")
        #expect(ByteSize.gibValue("nonsense") == nil)
    }
}

@Suite struct InstanceConfigTests {
    static let raw = try! JSONValue.parseYAML("""
    cpus: 1
    memory: 1GiB
    mounts:
    - location: "~"
      sshfs:
        cache: false
    networks:
    - lima: shared
      macAddress: "52:55:55:00:00:01"
    portForwards:
    - guestPort: 80
      hostPort: 8080
    - guestPortRange: [1, 65535]
      ignore: true
    additionalDisks:
    - data
    """)

    static let effective = JSONValue.object([
        "cpus": .int(1), "memory": .string("1GiB"), "disk": .string("10GiB"),
        "mounts": .array([.object(["location": .string("/Users/u"), "mountPoint": .string("/Users/u"),
                                   "writable": .bool(false), "9p": .object(["cache": .string("fscache")])])]),
    ])

    @Test func listsComeFromRawYAML() {
        let c = InstanceConfig(raw: Self.raw, effective: Self.effective)
        #expect(c.cpus == 1)
        #expect(c.disk == "10GiB")
        #expect(c.mounts.map(\.location) == ["~"])
        #expect(c.networks.first?.kind == .lima("shared"))
        #expect(c.networks.first?.macAddress == "52:55:55:00:00:01")
        #expect(c.portForwards.count == 2)
        #expect(!c.portForwards[0].isAdvanced)
        #expect(c.portForwards[1].isAdvanced)
        #expect(c.additionalDisks.map(\.name) == ["data"])
    }

    @Test func effectiveListsAreStrippedOfDefaults() {
        let c = InstanceConfig(raw: .object([:]), effective: Self.effective)
        #expect(c.mounts.count == 1)
        #expect(c.mounts[0].json == .object(["location": .string("/Users/u")]))
    }

    @Test func noChangesMeansNoExpressions() {
        let c = InstanceConfig(raw: Self.raw, effective: Self.effective)
        #expect(c.setExpressions(comparedTo: c).isEmpty)
    }

    @Test func changedFieldsProduceExpressions() {
        let original = InstanceConfig(raw: Self.raw, effective: Self.effective)
        var c = original
        c.cpus = 2
        c.disk = "20GiB"
        c.mounts[0].writable = true
        c.networks.append(NetworkConfig(kind: .vzNAT))
        #expect(c.setExpressions(comparedTo: original) == [
            ".cpus = 2",
            #".disk = "20GiB""#,
            #".networks = [{"lima":"shared","macAddress":"52:55:55:00:00:01"},{"vzNAT":true}]"#,
            // Unmodelled keys (sshfs) survive.
            #".mounts = [{"location":"~","sshfs":{"cache":false},"writable":true}]"#,
        ])
    }

    @Test func unchangedAdvancedPortForwardIsPreserved() {
        let original = InstanceConfig(raw: Self.raw, effective: Self.effective)
        var c = original
        c.portForwards[0].hostPort = 9090
        let expr = c.setExpressions(comparedTo: original)
        #expect(expr == [#".portForwards = [{"guestPort":80,"hostPort":9090},{"guestPortRange":[1,65535],"ignore":true}]"#])
    }

    @Test func diskShorthandIsNormalized() {
        let original = InstanceConfig(raw: Self.raw, effective: Self.effective)
        var c = original
        c.additionalDisks.append(AdditionalDiskConfig(name: "logs"))
        #expect(c.setExpressions(comparedTo: original) == [#".additionalDisks = [{"name":"data"},{"name":"logs"}]"#])
    }
}

@Suite struct LimaDiskTests {
    @Test func decodesDiskList() throws {
        let data = Data("""
        {"name":"data","size":10737418240,"format":"qcow2","dir":"/Users/u/.lima/_disks/data","instance":"dev","instanceDir":"/Users/u/.lima/dev","mountPoint":"/mnt/lima-data"}
        {"name":"spare","size":1073741824,"format":"raw","dir":"/Users/u/.lima/_disks/spare","instance":"","instanceDir":"","mountPoint":"/mnt/lima-spare"}
        """.utf8)
        let disks = try LimaDisk.decodeList(data)
        #expect(disks.map(\.name) == ["data", "spare"])
        #expect(disks[0].attachedInstance == "dev")
        #expect(disks[1].attachedInstance == nil)
    }
}
