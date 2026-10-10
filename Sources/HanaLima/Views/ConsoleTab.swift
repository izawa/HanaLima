import AppKit
import LimaKit
import SwiftTerm
import SwiftUI

/// A `limactl shell` session in an embedded terminal. Sessions are cached per instance
/// so switching tabs or instances doesn't kill the shell.
@MainActor
@Observable
final class TerminalSession: NSObject, LocalProcessTerminalViewDelegate {
    let terminal: LocalProcessTerminalView
    private(set) var isRunning = false
    /// Shell-style exit code of the last session.
    private(set) var exitCode: Int32?
    private(set) var title = ""
    /// Set while waiting to retry a connection that failed right away.
    private(set) var retryAttempt: Int?

    /// A failure within this many seconds of connecting counts as "SSH not ready yet".
    private static let quickFailure: TimeInterval = 10
    private static let maxRetries = 10
    private static let retryDelay: Duration = .seconds(3)

    @ObservationIgnored private var client: LimaClient?
    @ObservationIgnored private var instance = ""
    @ObservationIgnored private var startedAt = Date.distantPast
    @ObservationIgnored private var attempts = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    /// Asked before an automatic retry; false once the VM has stopped.
    @ObservationIgnored var shouldRetry: @MainActor () -> Bool = { false }

    override init() {
        terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        super.init()
        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    /// Connects now. Resets the automatic-retry budget (this is also the "再接続" action).
    func start(client: LimaClient, instance: String) {
        retryTask?.cancel()
        retryAttempt = nil
        attempts = 0
        launch(client: client, instance: instance)
    }

    private func launch(client: LimaClient, instance: String) {
        guard !isRunning else { return }
        self.client = client
        self.instance = instance
        let (executable, args) = client.shellCommand(instance)
        var env = client.environment
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "ja_JP.UTF-8"
        exitCode = nil
        isRunning = true
        startedAt = .now
        attempts += 1
        terminal.startProcess(executable: executable, args: args,
                              environment: env.map { "\($0.key)=\($0.value)" })
    }

    func terminate() {
        retryTask?.cancel()
        retryAttempt = nil
        if isRunning { terminal.terminate() }
    }

    private func handleExit(_ code: Int32?) {
        isRunning = false
        exitCode = code
        // ssh exits with 255 when it can't connect, e.g. while the guest's sshd is still booting.
        let failedFast = code != 0 && Date.now.timeIntervalSince(startedAt) < Self.quickFailure
        guard failedFast, attempts <= Self.maxRetries, shouldRetry(), let client else { return }
        retryAttempt = attempts
        feed(String(localized: "\r\n[HanaLima] 接続できませんでした。3 秒後に再試行します（\(attempts)/\(Self.maxRetries)）…\r\n"))
        let instance = instance
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: Self.retryDelay)
            guard let self, !Task.isCancelled, self.shouldRetry() else { return }
            self.retryAttempt = nil
            self.launch(client: client, instance: instance)
        }
    }

    private func feed(_ text: String) {
        terminal.feed(text: text)
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in self.title = title }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // SwiftTerm reports the raw waitpid status.
        let code = exitCode.map { ExitStatus.decode(waitStatus: $0) }
        Task { @MainActor in self.handleExit(code) }
    }
}

@MainActor
@Observable
final class TerminalSessions {
    static let shared = TerminalSessions()
    private var sessions: [String: TerminalSession] = [:]

    func session(for name: String) -> TerminalSession {
        if let s = sessions[name] { return s }
        let s = TerminalSession()
        sessions[name] = s
        return s
    }

    /// Ends and forgets a session, so the next visit starts a fresh shell.
    func discard(_ name: String) {
        sessions.removeValue(forKey: name)?.terminate()
    }
}

struct ConsoleTab: View {
    @Environment(AppModel.self) private var model
    let instance: LimaInstance

    var body: some View {
        if instance.isRunning, let client = model.client {
            let session = TerminalSessions.shared.session(for: instance.name)
            let ready = model.isReady(instance.name)
            if !ready && !session.isRunning && session.exitCode == nil {
                // Lima lists the VM as Running as soon as it boots, but SSH comes up later.
                ContentUnavailableView {
                    Label("起動処理中です", systemImage: "hourglass")
                } description: {
                    Text("SSH の準備ができると自動で接続します。")
                } actions: {
                    Button("今すぐ接続") { connect(session, client) }
                }
                .onChange(of: ready) { _, isReady in
                    if isReady { connect(session, client) }
                }
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                        Text(status(of: session)).lineLimit(1)
                        Spacer()
                        if session.isRunning {
                            Button("切断") { session.terminate() }
                        } else if session.retryAttempt != nil {
                            ProgressView().controlSize(.small)
                            Button("中止") { session.terminate() }
                        } else {
                            Button("再接続") { connect(session, client) }
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    TerminalHost(terminal: session.terminal)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                }
                .onAppear {
                    if !session.isRunning && session.exitCode == nil && session.retryAttempt == nil {
                        connect(session, client)
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("仮想マシンは停止しています", systemImage: "terminal")
            } description: {
                Text("起動するとここでシェルを使えます。")
            } actions: {
                Button("起動") { model.start(instance.name) }
                    .disabled(model.isBusy(instance.name))
            }
            .onAppear {
                // A stale session from before the VM stopped should start fresh next time.
                TerminalSessions.shared.discard(instance.name)
            }
        }
    }

    private func connect(_ session: TerminalSession, _ client: LimaClient) {
        let name = instance.name
        session.shouldRetry = { [weak model] in model?.instance(named: name)?.isRunning == true }
        session.start(client: client, instance: name)
    }

    private func status(of session: TerminalSession) -> String {
        if session.isRunning {
            return session.title.isEmpty ? "limactl shell \(instance.name)" : session.title
        }
        if let attempt = session.retryAttempt {
            return String(localized: "接続を再試行しています（\(attempt) 回目の失敗）…")
        }
        return String(localized: "シェルは終了しました（終了コード \(session.exitCode.map(String.init) ?? "—")）")
    }
}

/// Hosts a cached terminal view; the view itself outlives this representable.
private struct TerminalHost: NSViewRepresentable {
    let terminal: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if terminal.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { container.window?.makeFirstResponder(terminal) }
    }
}
