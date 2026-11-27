import Foundation
import Testing
@testable import LimaKit

@Suite struct GuestOSTests {
    private func name(_ text: String) -> String? { GuestOS.name(fromStdout: text.components(separatedBy: "\n")) }

    private func linux(_ release: String) -> String {
        "hanalima-os-uname=Linux\n" + release.split(separator: "\n").map { "hanalima-os-release:\($0)" }.joined(separator: "\n")
    }

    @Test func linuxUsesPrettyName() {
        #expect(name(linux("NAME=\"Ubuntu\"\nVERSION_ID=\"26.04\"\nPRETTY_NAME=\"Ubuntu 26.04 LTS\"")) == "Ubuntu 26.04 LTS")
        #expect(name(linux("NAME=\"Alpine Linux\"\nID=alpine\nVERSION_ID=3.22.1\nPRETTY_NAME=\"Alpine Linux v3.22\"")) == "Alpine Linux v3.22")
        #expect(name(linux("PRETTY_NAME=\"Debian GNU/Linux forky/sid\"\nNAME=\"Debian GNU/Linux\"")) == "Debian GNU/Linux forky/sid")
    }

    @Test func linuxWithoutPrettyName() {
        #expect(name(linux("NAME=Fedora\nVERSION_ID=44")) == "Fedora 44")
        #expect(name(linux("NAME='Arch Linux'")) == "Arch Linux")
        #expect(name("hanalima-os-uname=Linux") == "Linux")
    }

    @Test func otherSystems() {
        #expect(name("hanalima-os-uname=Darwin\nhanalima-os-version=27.0.1") == "macOS 27.0.1")
        #expect(name("hanalima-os-uname=FreeBSD\nhanalima-os-version=15.0-RELEASE-p1") == "FreeBSD 15.0-RELEASE-p1")
        #expect(name("hanalima-os-uname=Darwin\nhanalima-os-version=") == "macOS")
        #expect(name("hanalima-os-uname=OpenBSD") == "OpenBSD")
    }

    @Test func onlyTheScriptsLinesCount() {
        // stderr comes back as "2> …"; anything else the guest printed is ignored.
        #expect(name("2> hanalima-os-uname=Darwin\nhello") == nil)
        #expect(name("motd\nhanalima-os-uname=Linux\n2> hanalima-os-release:PRETTY_NAME=x\nhanalima-os-release:PRETTY_NAME=\"Ubuntu\"") == "Ubuntu")
    }

    @Test func valuesAreDataAndKeptShort() {
        #expect(name(linux("PRETTY_NAME=\"a \\\"quoted\\\" $(reboot)\"")) == "a \"quoted\" $(reboot)")
        #expect(name(linux("PRETTY_NAME=\"x\u{1b}[31my\u{07}\"")) == "x[31my")
        #expect(name(linux("PRETTY_NAME=\"\(String(repeating: "a", count: 500))\""))?.count == GuestOS.maxLength)
        #expect(name(linux("PRETTY_NAME=\"\"\nNAME=Fedora")) == "Fedora")
    }

    @Test func quotingFollowsTheShell() {
        #expect(GuestOS.unquote(#""Acme\Labs""#) == #"Acme\Labs"#)
        #expect(GuestOS.unquote(#""a\"b\\c""#) == #"a"b\c"#)
        #expect(GuestOS.unquote(#"'it\s'"#) == #"it\s"#)
        #expect(GuestOS.unquote(#"Acme\ Labs"#) == "Acme Labs")
    }

    @Test func theScriptRunsOnThisMac() throws {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-s"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        try p.run()
        input.fileHandleForWriting.write(Data(GuestOS.script.utf8))
        try input.fileHandleForWriting.close()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(name(text)?.hasPrefix("macOS ") == true)
    }
}
