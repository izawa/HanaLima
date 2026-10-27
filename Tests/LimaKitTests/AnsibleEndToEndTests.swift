import Foundation
import Testing
@testable import LimaKit

/// A playbook run from the host against a Lima VM with HanaLima's inventory (docs/08): ping,
/// facts, a `become` write, and nothing changed the second time. Needs `ansible-playbook`
/// (skipped when none runs; `HANALIMA_E2E_ANSIBLE=<path>` picks one). Alpine has no python3,
/// so the guest is Ubuntu LTS. Run with `HANALIMA_E2E=1 swift test --filter AnsibleEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct AnsibleEndToEndTests {
    let vm = "hanalima-e2e-ansible"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    @Test(.timeLimit(.minutes(15)))
    func playbookRunsAgainstTheVM() async throws {
        let env = ProcessInfo.processInfo.environment
        let preferred = env["HANALIMA_E2E_ANSIBLE"].map { URL(filePath: $0) }
        guard let tool = await Ansible.locate(preferred: preferred, environment: client.environment) else {
            print("skipped: no ansible-playbook on this Mac")
            return
        }
        print("using \(tool.url.path): \(tool.version)")

        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm]) }
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: "ubuntu-lts", cpus: 2, memoryGiB: 2, diskGiB: 10, vmType: .vz, mountNone: true)))
        _ = try await drain(client.start(vm))

        let support = FileManager.default.temporaryDirectory.appending(path: "hanalima-ansible-e2e-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: support) }
        let limaHome = try await client.limaHome()
        let inventory = try Ansible.writeInventory(
            instances: [(vm, limaHome.appending(path: vm, directoryHint: .isDirectory))], supportDirectory: support)
        let folder = support.appending(path: "playbook", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let playbook = folder.appending(path: "site.yml")
        try """
        - hosts: all
          become: true
          tasks:
            - ansible.builtin.ping:
            - ansible.builtin.copy:
                dest: /etc/hanalima-ansible-e2e
                content: "{{ ansible_facts['distribution'] }}\\n"
                mode: "0644"

        """.write(to: playbook, atomically: true, encoding: .utf8)

        let runner = ProcessRunner(executableURL: tool.url, environment: client.environment, currentDirectoryURL: folder)
        let args = Ansible.arguments(playbook: playbook, inventory: inventory, limitTo: vm)
        let first = try await runner.run(args).stdoutString
        #expect(first.contains("changed=1") && first.contains("failed=0"), "\(first)")
        let written = try await client.runner.run(["shell", vm, "cat", "/etc/hanalima-ansible-e2e"]).stdoutString
        #expect(written.trimmingCharacters(in: .whitespacesAndNewlines) == "Ubuntu")
        let second = try await runner.run(args).stdoutString
        #expect(second.contains("changed=0") && second.contains("failed=0"), "\(second)")
        _ = try await drain(client.stop(vm))
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
