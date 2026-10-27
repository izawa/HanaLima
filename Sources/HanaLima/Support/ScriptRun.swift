import Foundation
import LimaKit
import SwiftUI

/// A script run in a guest right now, with its output streamed to a sheet (as opposed to Lima's
/// provisioning, which runs at every boot). Also the engine for host commands aimed at a VM.
@MainActor
@Observable
final class ScriptRun: Identifiable {
    enum State: Equatable {
        case running
        case finished(exit: Int32)
        case cancelled
        case failed(String)
    }

    let id = UUID()
    let title: String
    let instance: String
    private(set) var lines: [OutputLine] = []
    private(set) var state: State = .running
    private(set) var startedAt = Date.now
    private(set) var finishedAt: Date?
    private var task: Task<Void, Never>?
    static let maxLines = 5000

    init(title: String, instance: String) {
        self.title = title
        self.instance = instance
    }

    var isRunning: Bool { state == .running }

    func start(_ stream: AsyncThrowingStream<OutputLine, Error>, completion: @escaping @MainActor (State) -> Void) {
        task = Task {
            var result: State = .finished(exit: 0)
            do {
                for try await line in stream {
                    lines.append(line)
                    if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
                }
            } catch let error as CommandError {
                result = .finished(exit: error.status)
            } catch is CancellationError {
                result = .cancelled
            } catch {
                result = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            if Task.isCancelled { result = .cancelled }
            state = result
            finishedAt = .now
            completion(result)
        }
    }

    func cancel() {
        guard isRunning else { return }
        task?.cancel()
    }

    var text: String { lines.map(\.text).joined(separator: "\n") }
}

extension AppModel {
    /// Runs `script` in `name` now (root for `asRoot`) and shows its output. The VM must be
    /// ready (SSH up). Counts as an operation while it runs, so start/stop wait.
    func runScript(_ script: String, in name: String, asRoot: Bool, title: String) {
        guard let client, isReady(name), !isBusy(name) else { return }
        let run = ScriptRun(title: title, instance: name)
        operations[name] = Operation(kind: .runScript)
        scriptRun = run
        run.start(client.runScript(in: name, script: script, asRoot: asRoot)) { [weak self] _ in
            guard let self, self.operations[name]?.kind == .runScript else { return }
            self.operations[name] = nil
        }
    }

    /// Provisioning entries run now, in order, as Lima's boot would (see `ProvisionScripts`).
    func runProvisionNow(_ entries: [ProvisionConfig], in name: String, title: String) {
        runScript(ProvisionScripts.combined(entries, user: NSUserName()), in: name, asRoot: true, title: title)
    }
}

/// The streamed output of a `ScriptRun`.
struct ScriptRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    let run: ScriptRun

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.headline).lineLimit(1)
                    Text("「\(run.instance)」で実行").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                status
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(run.lines.enumerated()), id: \.offset) { _, line in
                            Text(line.text)
                                .foregroundStyle(isError(line) ? Color.red : Color.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onChange(of: run.lines.count) { _, _ in proxy.scrollTo("end") }
            }
            Divider()
            HStack {
                Text(timing).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if run.isRunning {
                    Button("中止") { run.cancel() }
                } else {
                    Button("閉じる") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
        }
        .frame(width: 720, height: 480)
    }

    private func isError(_ line: OutputLine) -> Bool {
        if case .stderr = line { return true }
        return false
    }

    @ViewBuilder private var status: some View {
        switch run.state {
        case .running:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("実行中") }
        case .finished(let exit) where exit == 0:
            Label("成功", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .finished(let exit):
            Label("失敗（終了コード \(exit)）", systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .cancelled:
            Label("中止しました", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
        }
    }

    private var timing: String {
        let end = run.finishedAt ?? .now
        let seconds = Int(end.timeIntervalSince(run.startedAt))
        return run.isRunning ? String(localized: "\(seconds) 秒経過") : String(localized: "\(seconds) 秒で終了")
    }
}
