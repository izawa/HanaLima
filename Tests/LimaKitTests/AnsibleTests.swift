import Foundation
import Testing
@testable import LimaKit

@Suite struct AnsibleTests {
    @Test func inventoryPointsSSHAtLimasConfig() {
        let dir = URL(filePath: "/Users/me/.lima/dev", directoryHint: .isDirectory)
        #expect(Ansible.inventoryLine(instance: "dev", instanceDir: dir)
                == "lima-dev ansible_ssh_common_args='-F /Users/me/.lima/dev/ssh.config'")
        // A space in the path is quoted inside the ssh arguments.
        let spaced = URL(filePath: "/Users/my name/.lima/dev", directoryHint: .isDirectory)
        #expect(Ansible.inventoryLine(instance: "dev", instanceDir: spaced).contains("-F \"/Users/my name/.lima/dev/ssh.config\""))
        let inv = Ansible.inventory(instances: [("b", dir), ("a", dir)])
        #expect(inv.contains("[hanalima]\nlima-a ") && inv.contains("\nlima-b "))
    }

    @Test func argumentsLimitToTheInstanceAndEndWithThePlaybook() {
        let args = Ansible.arguments(playbook: URL(filePath: "/p/site.yml"), inventory: URL(filePath: "/i/inventory.ini"),
                                     limitTo: "dev", extra: ["--tags", "x"])
        #expect(args == ["-i", "/i/inventory.ini", "--limit", "lima-dev", "--tags", "x", "/p/site.yml"])
    }

    @Test func splitArgumentsHandlesQuotes() {
        #expect(Ansible.splitArguments("-e 'a=b c' --tags \"x,y\" -v") == ["-e", "a=b c", "--tags", "x,y", "-v"])
        #expect(Ansible.splitArguments("  ") == [])
        #expect(Ansible.splitArguments("-e ''") == ["-e", ""])
    }

    @Test func candidatesPreferHomebrewAndTheUsersTools() {
        let home = URL(filePath: "/Users/me", directoryHint: .isDirectory)
        let c = Ansible.candidates(home: home, environment: ["PATH": "/usr/bin:/opt/homebrew/bin"]).map(\.path)
        #expect(c.prefix(4) == ["/opt/homebrew/bin/ansible-playbook", "/Users/me/.pyenv/shims/ansible-playbook",
                                "/Users/me/.local/bin/ansible-playbook", "/usr/local/bin/ansible-playbook"])
        #expect(c.filter { $0 == "/opt/homebrew/bin/ansible-playbook" }.count == 1)
        #expect(c.contains("/usr/bin/ansible-playbook"))
    }

    @Test func probeRejectsWhatCannotRun() async {
        #expect(await Ansible.probe(URL(filePath: "/nonexistent/ansible-playbook")) == nil)
        // Runs, but isn't ansible.
        #expect(await Ansible.probe(URL(filePath: "/usr/bin/true")) == nil)
    }

    @Test func metadataKeepsTheRecord() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "ansible-meta-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var meta = InstanceMetadata(instanceDir: dir)
        meta.ansible = .init(playbook: URL(filePath: "/p/site.yml"), extraArguments: "-v")
        try meta.save()
        let loaded = InstanceMetadata.load(instanceDir: dir)
        #expect(loaded?.ansible?.playbookURL.path == "/p/site.yml")
        #expect(loaded?.ansible?.extraArguments == "-v")
        #expect(loaded?.ansible?.lastRunAt == nil)
    }
}
