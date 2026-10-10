import Foundation
import Testing
@testable import LimaKit

@Suite struct SocketVMNetSetupTests {
    @Test func parsesChecksums() {
        let sums = """
        619263a86c7c0fd3a5659acffeadba92c8b61057d82c6a15c102ae8c447eaec7  build-env.txt
        c7bf62308fbcfdc29bdfb8373c9b1951f7ac2396446e4390919796a94972e6dc  socket_vmnet-1.2.2-arm64.tar.gz
        2968a82c97e692c2d36f87230152e8018e00589c1b598e8257775adfe83800a1 *socket_vmnet-1.2.2-x86_64.tar.gz
        """
        #expect(SocketVMNetSetup.checksum(for: "socket_vmnet-1.2.2-arm64.tar.gz", in: sums)
                == "c7bf62308fbcfdc29bdfb8373c9b1951f7ac2396446e4390919796a94972e6dc")
        #expect(SocketVMNetSetup.checksum(for: "socket_vmnet-1.2.2-x86_64.tar.gz", in: sums)?.hasPrefix("2968a8") == true)
        #expect(SocketVMNetSetup.checksum(for: "missing.tar.gz", in: sums) == nil)
    }

    @Test func verifiesDownloads() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hanalima-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello\n".utf8).write(to: file)
        // `printf 'hello\n' | shasum -a 256`
        try SocketVMNetSetup.verify(file, sha256: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
        #expect(throws: SetupError.self) { try SocketVMNetSetup.verify(file, sha256: String(repeating: "0", count: 64)) }
    }

    @Test func scriptsAreValidShell() async throws {
        for script in [SocketVMNetSetup.installScript, SocketVMNetSetup.sudoersScript, SocketVMNetSetup.uninstallScript] {
            let sh = ProcessRunner(executableURL: URL(fileURLWithPath: "/bin/sh"), environment: [:])
            _ = try await sh.run(["-n", "-c", script])
        }
        #expect(SocketVMNetSetup.installScript.contains("visudo -cf"))
        #expect(SocketVMNetSetup.installScript.contains("shasum -a 256 -c"))
    }

    /// Runs the generated AppleScript *without* administrator privileges to prove that the
    /// script and awkward arguments survive AppleScript + sh quoting intact.
    @Test func appleScriptQuotingRoundTrips() async throws {
        let args = ["with space", #"quo"te's"#, "$HOME `x` \\ back", "日本語"]
        let script = #"for a in "$@"; do printf '[%s]\n' "$a"; done; echo "\$0=$0""#
        let source = SocketVMNetSetup.appleScript(for: script, arguments: args, prompt: "unused", privileged: false)
        let osa = ProcessRunner(executableURL: URL(fileURLWithPath: "/usr/bin/osascript"), environment: [:])
        let out = try await osa.run(["-e", source]).stdoutString
        #expect(out.split(separator: "\r").map(String.init)
                == args.map { "[\($0)]" } + ["$0=hanalima-setup\n"])
    }

    @Test func privilegedAppleScriptAsksForAdmin() {
        let src = SocketVMNetSetup.appleScript(for: "true", arguments: [], prompt: "p")
        #expect(src.hasSuffix("with prompt \"p\" with administrator privileges"))
    }

    @Test func parsesHardwarePorts() {
        let text = """
        Hardware Port: Ethernet
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:ff

        Hardware Port: Wi-Fi
        Device: en1
        """
        #expect(SocketVMNetSetup.parseHardwarePorts(text) == ["en0": "Ethernet", "en1": "Wi-Fi"])
    }

    @Test func setsBridgedInterface() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hanalima-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "networks.yaml")
        try """
        # comment
        paths:
          socketVMNet: "/opt/socket_vmnet/bin/socket_vmnet"
        group: admin
        networks:
          shared:
            mode: shared
            gateway: 192.168.105.1
          bridged:
            mode: bridged
            interface: en0
        """.write(to: url, atomically: true, encoding: .utf8)
        try SocketVMNetSetup.setBridgedInterface("en1", configURL: url)
        let nets = LimaNetworks.load(from: url)
        #expect(nets.network(named: "bridged")?.interface == "en1")
        #expect(nets.network(named: "shared")?.gateway == "192.168.105.1")
        #expect(nets.socketVMNetPath == "/opt/socket_vmnet/bin/socket_vmnet")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("bak").path))
    }

    @Test func statusReflectsThisMachine() async throws {
        let client = LimaClient(limactlURL: try #require(LimaClient.locate()))
        let st = await SocketVMNetSetup(client: client).status()
        #expect(st.binaryPath.hasSuffix("socket_vmnet"))
        if !st.binaryInstalled { #expect(!st.isReady) }
    }
}

@Suite struct SudoersPermissionTests {
    /// Regression: 0440 root:wheel made `limactl sudoers --check` fail for non-wheel admins.
    @Test func sudoersIsWorldReadable() {
        #expect(SocketVMNetSetup.sudoersScript.contains("-m 0444"))
        #expect(!SocketVMNetSetup.installScript.contains("0440"))
    }
}
