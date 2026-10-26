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
