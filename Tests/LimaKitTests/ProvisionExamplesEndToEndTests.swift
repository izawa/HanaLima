import Foundation
import Testing
@testable import LimaKit

/// Boots a VM with HanaLima's provisioning examples and checks each did its job, then boots it
/// again (the scripts run at every boot and must stay quick and harmless).
/// `HANALIMA_E2E_TEMPLATE` picks the guest (default ubuntu-lts); examples that don't support it
/// are skipped. Run with `HANALIMA_E2E=1 swift test --filter ProvisionExamplesEndToEnd`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct ProvisionExamplesEndToEndTests {
    static let template = ProcessInfo.processInfo.environment["HANALIMA_E2E_TEMPLATE"] ?? "ubuntu-lts"
    let vm = "hanalima-e2e-examples"
    let client = LimaClient(limactlURL: LimaClient.locate()!)

    /// Which examples to try on this guest.
    var examples: [ProvisionExample] {
        let alpine = Self.template.hasPrefix("alpine")
        return ProvisionExamples.all.filter { !alpine || $0.distributions.contains("Alpine") }
    }

    @Test(.timeLimit(.minutes(30)))
    func examplesWork() async throws {
        _ = try? await drain(client.delete(vm, force: true))
        defer { E2ECleanup.deleteInstances([vm]) }
        let entries = examples.flatMap(\.entries).map(\.json)
        _ = try await drain(client.create(CreateOptions(
            name: vm, template: Self.template, cpus: 2, memoryGiB: 4, diskGiB: 20, vmType: .vz, mountNone: true,
            setExpressions: [".provision = \(JSONValue.array(entries).jsonText)"])))

        let first = Date.now
        _ = try await drain(client.start(vm))
        let firstBoot = Date.now.timeIntervalSince(first)
        try await check()

        _ = try await drain(client.stop(vm))
        let second = Date.now
        _ = try await drain(client.start(vm))
        let secondBoot = Date.now.timeIntervalSince(second)
        print("\(Self.template): first boot \(Int(firstBoot)) s, second boot \(Int(secondBoot)) s")
        #expect(secondBoot < firstBoot)  // nothing is installed again
        try await check()
        _ = try await drain(client.stop(vm))
    }

    private func check() async throws {
        for example in examples {
            switch example.id {
            case .basicTools:
                #expect(try await sh("command -v git jq vim htop tmux unzip wget curl >/dev/null && echo ok") == "ok")
            case .dotfiles:
                #expect(try await sh("stat -c %U ~/.config/hanalima/shell.sh") == (try await sh("id -un")))
                #expect(try await sh(#"grep -c hanalima/shell.sh ~/.profile ~/.bashrc | cut -d: -f2 | sort -u"#) == "1")
                #expect(try await sh("sh -lc 'alias ll' >/dev/null 2>&1 && echo ok") == "ok")
            case .containerEngine:
                // The group database, not this session's groups: Lima reuses an ssh connection opened
                // before provisioning, so the new group shows only in later logins.
                #expect(try await sh("id -nG \"$(id -un)\" | tr ' ' '\\n' | grep -qx docker && echo ok") == "ok")
                #expect(try await sh("sudo docker run --rm hello-world 2>&1 | grep -q 'Hello from Docker' && echo ok") == "ok")
            case .xdp:
                let program = #"""
                #include <linux/bpf.h>
                #include <bpf/bpf_helpers.h>
                SEC("xdp") int pass(struct xdp_md *ctx) { return XDP_PASS; }
                char LICENSE[] SEC("license") = "GPL";
                """#
                _ = try await sh("mkdir -p /tmp/xdp && cat > /tmp/xdp/pass.c <<'EOF'\n\(program)\nEOF")
                #expect(try await sh("cd /tmp/xdp && clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c pass.c -o pass.o && echo ok") == "ok")
                #expect(try await sh("sudo xdp-loader load -m skb lo /tmp/xdp/pass.o && sudo xdp-loader status lo | grep -q pass && sudo xdp-loader unload -a lo && echo ok") == "ok")
                #expect(try await sh("sudo bpftool version >/dev/null && echo ok") == "ok")
            case .japan:
                #expect(try await sh("date +%Z") == "JST")
                #expect(try await sh("readlink -f /etc/localtime") == "/usr/share/zoneinfo/Asia/Tokyo")
                if !Self.template.hasPrefix("alpine") {
                    #expect(try await sh("locale -a | grep -qi '^ja_JP.utf-\\?8$' && echo ok") == "ok")
                    #expect(try await sh("LANG=ja_JP.UTF-8 date +%A | grep -q 曜日 && echo ok") == "ok")
                }
                // The system default is untouched.
                #expect(try await sh("cat /etc/default/locale /etc/locale.conf 2>/dev/null | grep -c ja_JP || true") == "0")
            case .noAutoUpdates:
                // No update timer is active (list-timers --all would still show masked ones), and the
                // ones we know of are masked.
                #expect(try await sh("systemctl list-timers --no-legend | grep -Ec 'apt-daily|dnf.*(automatic|makecache)' || true") == "0")
                #expect(try await sh("systemctl list-unit-files --no-legend --state=masked 'apt-daily*' 'dnf*makecache*' | wc -l | tr -d ' '") != "0")
            case .swap:
                #expect(try await sh("grep -q '^/swapfile[[:space:]]' /proc/swaps && echo ok") == "ok")
                #expect(try await sh("grep -c '^/swapfile[[:space:]]' /etc/fstab") == "1")
                #expect(try await sh("stat -c %a /swapfile") == "600")
            case .devLanguages:
                #expect(try await sh("/usr/local/bin/go version | grep -q '^go version go' && echo ok") == "ok")
                #expect(try await sh("node --version | grep -q '^v' && npm --version >/dev/null && echo ok") == "ok")
                #expect(try await sh("~/.local/bin/uv --version | grep -q '^uv ' && echo ok") == "ok")
                #expect(try await sh("~/.cargo/bin/cargo --version | grep -q '^cargo ' && echo ok") == "ok")
            case .fullUpgrade:
                // Ran once and left its stamp; the second boot didn't touch the stamp.
                #expect(try await sh("ls /var/lib/hanalima/once/*.done | wc -l | tr -d ' '") == "1")
                #expect(try await sh("sudo sh -c 'command -v apt-get >/dev/null && apt-get -s full-upgrade | grep -c \"^Inst \" || echo 0'") == "0")
            }
        }
    }

    /// Runs `script` in the guest as the user; returns trimmed stdout (errors become "").
    private func sh(_ script: String) async throws -> String {
        let out = try? await client.runner.run(["shell", vm, "sh", "-c", script])
        if out == nil { print("failed: \(script.prefix(80))") }
        return (out?.stdoutString ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
