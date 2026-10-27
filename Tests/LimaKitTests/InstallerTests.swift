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
        var file = ProvisionConfig(mode: .data, owner: "{{.User}}")
        file.path = "{{.Home}}/it's.conf"
        file.content = "a=1"
        file.extra["permissions"] = .string("0644")
        var user = ProvisionConfig(mode: .user)
        user.script = "echo $HOME\n"
        var system = ProvisionConfig(mode: .system)
        system.script = "apk add x"
        let whole = ProvisionScripts.combined([file, user, system], instanceName: "vm")
        // The sequence is saved to a file and run with stdin closed.
        #expect(whole.hasPrefix("HL_ALL=$(mktemp); export HL_ALL; cat > \"$HL_ALL\" <<'HANALIMA_EOF_'\nset -e\n"))
        #expect(whole.hasSuffix("HANALIMA_EOF_\nexec sh \"$HL_ALL\" </dev/null\n"))
        let s = ProvisionScripts.sequence([file, user, system], instanceName: "vm")
        #expect(s.hasPrefix("set -e\n"))
        #expect(s.contains("HL_NAME='vm'"))
        #expect(s.contains("### 1/3 [data]"))
        // Bodies pass through a quoted heredoc, then the guest expands Lima's template fields.
        #expect(s.contains("hl_expand > \"$HL_TMP/data\" <<'HANALIMA_EOF'\na=1\nHANALIMA_EOF\n"))
        #expect(s.contains("HL_PATH=$(printf %s '{{.Home}}/it'\\''s.conf' | hl_expand)"))
        #expect(s.contains("HL_OWNER=\"$(printf %s '{{.User}}' | hl_expand)\"\nhl_mkdir \"$(dirname \"$HL_PATH\")\" \"$HL_OWNER\"\n"))
        #expect(s.contains("[ -n \"$HL_OWNER\" ] && sudo -- chown \"$HL_OWNER\" \"$HL_PATH\""))
        #expect(s.contains("sudo -- chmod '0644' \"$HL_PATH\""))
        // Run with the script's own interpreter (hl_run reads the #! line; sudo for system).
        #expect(s.contains("hl_expand > \"$HL_TMP/script\" <<'HANALIMA_EOF'\necho $HOME\nHANALIMA_EOF\nhl_run \"$HL_TMP/script\"\n"))
        #expect(s.contains("hl_expand > \"$HL_TMP/script\" <<'HANALIMA_EOF'\napk add x\nHANALIMA_EOF\nhl_run \"$HL_TMP/script\" sudo\n"))
        #expect(s.contains("hl_run() { HL_SH=$(sed -n '1s/^#![[:space:]]*//p' \"$1\"); ${2:-} ${HL_SH:-sh} \"$1\"; }"))
        #expect(s.range(of: "### 2/3 ")!.lowerBound > s.range(of: "### 1/3 ")!.lowerBound)
    }

    @Test func heredocTagAvoidsTheBody() {
        #expect(ProvisionScripts.heredocTag(for: "x HANALIMA_EOF y") == "HANALIMA_EOF_")
    }
}

@Suite struct ProvisionOnceTests {
    @Test func wrapAndParseRoundTrip() {
        let body = "#!/bin/sh\nset -eu\napt-get -y full-upgrade\n"
        let wrapped = ProvisionOnce.wrap(body: body, mode: .system, id: "abc")
        #expect(wrapped.hasPrefix("#!/bin/sh\n# hanalima: once abc\n"))
        #expect(wrapped.contains("HL_STAMP=\"/var/lib/hanalima/once/abc.done\"\n[ -e \"$HL_STAMP\" ] && exit 0\n"))
        #expect(wrapped.hasSuffix("}\n(hl_once) && mkdir -p \"$(dirname \"$HL_STAMP\")\" && touch \"$HL_STAMP\"\n"))
        let parsed = ProvisionOnce.parse(wrapped)
        #expect(parsed?.id == "abc")
        #expect(parsed?.body == "set -eu\napt-get -y full-upgrade\n")  // the shebang moves to the wrapper
        #expect(ProvisionOnce.parse(body) == nil)
        #expect(ProvisionOnce.wrap(body: "x", mode: .user, id: "u").contains("$HOME/.local/state/hanalima/once/u.done"))
        // Another interpreter is kept: it becomes the wrapper's #! and comes back with the body.
        let bash = ProvisionOnce.wrap(body: "#!/bin/bash\necho ${BASH_VERSION}\n", mode: .system, id: "b")
        #expect(bash.hasPrefix("#!/bin/bash\n# hanalima: once b\n"))
        #expect(ProvisionOnce.parse(bash)?.body == "#!/bin/bash\necho ${BASH_VERSION}\n")
    }

    @Test func summaryAndBodySeeThroughTheWrapper() {
        var e = ProvisionConfig(mode: .system)
        e.script = ProvisionOnce.wrap(body: "# upgrade everything\napt-get -y full-upgrade\n", mode: .system, id: "id1")
        #expect(e.onceID == "id1")
        #expect(e.summary == "# upgrade everything")
        #expect(e.scriptBody == "# upgrade everything\napt-get -y full-upgrade\n")
        #expect(ProvisionConfig(mode: .system, script: "echo hi").onceID == nil)
    }
}
