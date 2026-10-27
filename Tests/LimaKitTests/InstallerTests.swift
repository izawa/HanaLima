import Foundation
import Testing
@testable import LimaKit

@Suite struct InstallerTests {
    @Test func fixupScriptCarriesTheCloudInitSteps() {
        let script = InstallerFixup.script
        #expect(script.hasPrefix("#!/bin/sh"))
        // The printf must reach the shell with a literal backslash-n (two characters).
        #expect(script.contains("printf 'datasource_list: [ NoCloud, None ]\\n' > /etc/cloud/cloud.cfg.d/95-hanalima.cfg"))
        #expect(script.contains("cloud-init clean --logs"))
        #expect(!script.contains("CLOUD_INIT_STEPS"))
        #expect(InstallerFixup.command == "sudo mount -L HANALIMA /mnt && sudo sh /mnt/limaify.sh")
    }

    @Test func autoinstallUserDataQuotesTheLateCommands() {
        let text = InstallerAutoinstall.userData(hostname: "autoinst", userName: "test", passwordHash: "$6$ab$cd")
        #expect(text.hasPrefix("#cloud-config\n"))
        #expect(text.contains("password: \"$6$ab$cd\""))
        // Each late command is one double-quoted YAML scalar; a bare `: ` inside would be parsed
        // as a mapping (which silently made the install interactive).
        let late = text.split(separator: "\n").filter { $0.contains("    - \"") }
        #expect(late.count == 2)
        #expect(late[0].contains("curtin in-target --target=/target -- sh -c '"))
        #expect(late[0].contains("cloud-init clean --logs"))
        #expect(late[0].contains("[ NoCloud, None ]\\\\n"))  // "\\n" in the scalar → \n for the shell
        #expect(late[0].hasSuffix("'\""))
        #expect(text.contains("shutdown: poweroff"))
    }

    @Test func grubConfigStartsTheISOKernelWithTheParameters() {
        #expect(InstallerAutoinstall.grubConfig.contains("linux (${iso})/casper/vmlinuz autoinstall --- console=tty0 console=hvc0"))
        #expect(InstallerAutoinstall.grubConfig.contains("search --set=iso --file /casper/vmlinuz"))
    }
}

@Suite struct ProvisionScriptsTests {
    @Test func shellArgumentsRunAScriptFromStdin() {
        #expect(LimaClient.scriptArguments(name: "vm", asRoot: true) == ["shell", "--tty=false", "vm", "sudo", "--", "sh", "-s"])
        #expect(LimaClient.scriptArguments(name: "vm", asRoot: false) == ["shell", "--tty=false", "vm", "sh", "-s"])
    }

    @Test func combinedScriptRunsEntriesInOrderAsTheRightUser() {
        var file = ProvisionConfig(mode: .data)
        file.path = "/etc/it's.conf"
        file.content = "a=1"
        file.extra["permissions"] = .string("0644")
        var user = ProvisionConfig(mode: .user)
        user.script = "echo $HOME\n"
        var system = ProvisionConfig(mode: .system)
        system.script = "apk add x"
        let s = ProvisionScripts.combined([file, user, system], user: "izawa")
        #expect(s.hasPrefix("set -e\n"))
        #expect(s.contains("### 1/3 [data]"))
        #expect(s.contains("cat > '/etc/it'\\''s.conf' <<'HANALIMA_EOF'\na=1\nHANALIMA_EOF\n"))
        #expect(s.contains("chmod '0644' '/etc/it'\\''s.conf'"))
        #expect(s.contains("sudo -u 'izawa' -i sh -s <<'HANALIMA_EOF'\necho $HOME\nHANALIMA_EOF\n"))
        #expect(s.contains("sh -s <<'HANALIMA_EOF'\napk add x\nHANALIMA_EOF\n"))
        #expect(s.range(of: "### 2/3 ")!.lowerBound > s.range(of: "### 1/3 ")!.lowerBound)
    }

    @Test func heredocTagAvoidsTheBody() {
        #expect(ProvisionScripts.heredocTag(for: "x HANALIMA_EOF y") == "HANALIMA_EOF_")
    }
}
