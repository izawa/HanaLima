import Foundation
import Testing
@testable import LimaKit

@Suite struct LimaMACAddressTests {
    /// A vector taken from a real instance: the MAC in its cidata network-config, Lima 2.2.1.
    @Test func matchesLima() {
        #expect(LimaMACAddress.address(machineID: "DF5F7D36-0559-584E-8380-2B3DBFA3D0E2",
                                       instanceDir: "/Users/izawa/.lima/ubuntu-lts") == "52:55:55:52:85:c7")
    }

    @Test func machineIDIsAUUID() {
        let id = LimaMACAddress.machineID()
        #expect(id.map { UUID(uuidString: $0) != nil } == true)
    }

    @Test func instanceDirHasNoTrailingSlash() {
        let id = "DF5F7D36-0559-584E-8380-2B3DBFA3D0E2"
        let dir = URL(filePath: "/Users/izawa/.lima/ubuntu-lts/", directoryHint: .isDirectory)
        // Lima hashes inst.Dir as filepath.Join spells it, without the slash; a directory URL's
        // path has one.
        #expect(dir.path(percentEncoded: false).hasSuffix("/"))
        if LimaMACAddress.machineID() == id {
            #expect(LimaMACAddress.address(instanceDir: dir) == "52:55:55:52:85:c7")
        } else {
            #expect(LimaMACAddress.address(instanceDir: dir) != nil)
        }
    }

    /// Lima keeps `/private` in `/private/tmp/…` (LIMA_HOME under a temporary folder), and the
    /// MAC follows that spelling even when the folder exists.
    @Test func keepsPrivatePrefix() throws {
        let dir = URL(filePath: "/private/tmp/hanalima-mac-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LimaMACAddress.limaSpelling(of: dir) == dir.path(percentEncoded: false).dropLast().description)
        #expect(LimaMACAddress.limaSpelling(of: dir).hasPrefix("/private/tmp/"))
    }
}

@Suite struct LimaMountTagTests {
    /// The tag cidata wrote for the home share of a real instance (user-data `mounts:`).
    @Test func matchesLima() {
        #expect(LimaMACAddress.mountTag(location: "/Users/izawa", mountPoint: "/Users/izawa") == "lima-e93ad3b36ba19236")
    }
}
