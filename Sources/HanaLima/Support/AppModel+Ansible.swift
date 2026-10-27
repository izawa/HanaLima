import Foundation
import LimaKit
import NetworkKit

/// Ansible from the host (docs/08): the inventory is written from the instance list, the
/// playbook runs through the same output sheet as "run now".
extension AppModel {
    /// The `ansible-playbook` HanaLima found (nil until probed, or when there is none).
    var ansibleTool: Ansible.Tool? { ansibleState.tool }

    /// Probes for `ansible-playbook`: the path from Settings first, then the usual places.
    func locateAnsible() async {
        ansibleState.probing = true
        let preferred = AppSettings.ansiblePath.map { URL(filePath: $0) }
        let tool = await Ansible.locate(preferred: preferred, environment: client?.environment ?? ProcessInfo.processInfo.environment)
        ansibleState = AnsibleState(tool: tool, probing: false, probed: true)
    }

    /// Writes `<support>/ansible/inventory.ini` with every instance; returns its URL.
    @discardableResult
    func writeAnsibleInventory() throws -> URL {
        try Ansible.writeInventory(instances: instances.map { ($0.name, URL(filePath: $0.dir, directoryHint: .isDirectory)) },
                                   supportDirectory: NetworkPaths.supportDirectory)
    }

    /// Records the playbook (and arguments) for `name`.
    func setAnsible(playbook: URL?, extraArguments: String, of name: String) {
        guard var meta = metadata[name] else { return }
        if let playbook {
            var record = meta.ansible ?? InstanceMetadata.AnsibleRecord(playbook: playbook)
            record.playbook = playbook.path(percentEncoded: false)
            record.extraArguments = extraArguments
            meta.ansible = record
        } else {
            meta.ansible = nil
        }
        guard meta != metadata[name] else { return }
        metadata[name] = meta
        try? meta.save()
    }

    /// Runs the VM's playbook now (the VM must be ready) and shows the output. The working
    /// directory is the playbook's folder, so roles and ansible.cfg next to it apply.
    func runAnsible(in name: String) {
        guard let tool = ansibleTool, let record = metadata[name]?.ansible, isReady(name), !isBusy(name) else { return }
        let inventory: URL
        do { inventory = try writeAnsibleInventory() } catch {
            alert = AlertMessage(title: String(localized: "Ansible のインベントリを書けませんでした"), message: error.localizedDescription)
            return
        }
        let playbook = record.playbookURL
        let runner = ProcessRunner(executableURL: tool.url,
                                   environment: client?.environment ?? ProcessInfo.processInfo.environment,
                                   currentDirectoryURL: playbook.deletingLastPathComponent())
        let arguments = Ansible.arguments(playbook: playbook, inventory: inventory, limitTo: name,
                                          extra: Ansible.splitArguments(record.extraArguments))
        let run = ScriptRun(title: "ansible-playbook \(playbook.lastPathComponent)", instance: name, highlightsStderr: false)
        operations[name] = Operation(kind: .runScript)
        scriptRun = run
        run.start(runner.lines(arguments, terminateOnCancel: true)) { [weak self] state in
            guard let self else { return }
            if self.operations[name]?.kind == .runScript { self.operations[name] = nil }
            guard var meta = self.metadata[name], var rec = meta.ansible else { return }
            rec.lastRunAt = .now
            if case .finished(let exit) = state { rec.lastExitStatus = exit } else { rec.lastExitStatus = nil }
            meta.ansible = rec
            self.metadata[name] = meta
            try? meta.save()
        }
    }
}

struct AnsibleState {
    var tool: Ansible.Tool?
    var probing = false
    var probed = false
}
