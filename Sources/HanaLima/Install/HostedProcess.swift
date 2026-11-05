import AppKit
import LimaKit

/// A Lima instance's VM booted outside Lima by HanaLima's driver (`lima-driver-hanalima
/// --hosted`, docs/07 and docs/09): the installer and the rescue boot. The VM runs in the
/// driver's own process with its own window, so it survives the app quitting; the app finds it
/// again on launch through the driver's pid file and control socket (`attach`).
///
/// Lima keeps the instance's files in `~/.lima/<name>/` and reuses `disk`, `vz-efi` and
/// `vz-identifier` as they are, so what happens here is what `limactl start` boots afterwards.
@MainActor
@Observable
final class HostedProcess {
    enum State: Equatable {
        case starting, running, stopped
        case failed(String)
    }

    /// What to attach besides the instance's disk (see the driver's `InstanceSpec.Hosted`).
    struct Options {
        /// The installer ISO (USB). Nil boots from the disk.
        var iso: URL?
        /// The fix-up ISO (USB, label HANALIMA).
        var helper: URL?
        /// Lima's `cidata.iso`, so cloud-init sees the same instance and does nothing new.
        var cidata = true
        /// The file in the instance directory that receives the guest's serial console.
        var serialLog = "hanalima-installer-serial.log"
    }

    let instanceDir: URL
    private(set) var state: State = .starting
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pid: Int32?
    @ObservationIgnored private var poll: Task<Void, Never>?

    private init(instanceDir: URL) { self.instanceDir = instanceDir }

    /// Launches the driver for a new hosted boot.
    static func start(instanceDir: URL, options: Options, cpus: Int, memoryBytes: UInt64) throws -> HostedProcess {
        guard let helpers = AppModel.driverDirectory else {
            throw NSError(domain: "HanaLima", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "このビルドには HanaLima のドライバーが入っていません。")])
        }
        let hosted = HostedProcess(instanceDir: instanceDir)
        let p = Process()
        p.executableURL = helpers.appending(path: "lima-driver-hanalima")
        var args = ["--hosted", instanceDir.path, "--cpus", "\(cpus)", "--memory", "\(memoryBytes)", "--serial-log", options.serialLog]
        if let iso = options.iso { args += ["--iso", iso.path] }
        if let helper = options.helper { args += ["--helper", helper.path] }
        if !options.cidata { args.append("--no-cidata") }
        p.arguments = args
        // limactl (for usernet) must be findable: Finder-launched apps don't carry Homebrew's PATH.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? ""].joined(separator: ":")
        p.environment = env
        let log = instanceDir.appending(path: "hanalima-hosted.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = try FileHandle(forWritingTo: log)
        p.terminationHandler = { [weak hosted] proc in
            let status = proc.terminationStatus
            Task { @MainActor in hosted?.ended(status: status) }
        }
        try p.run()
        hosted.process = p
        hosted.pid = p.processIdentifier
        hosted.startPolling()
        return hosted
    }

    /// A hosted boot of `instanceDir` that is already running (from before the app was quit).
    static func attach(instanceDir: URL) -> HostedProcess? {
        guard let pid = DriverControl.hostedPID(instanceDir: instanceDir) else { return nil }
        let hosted = HostedProcess(instanceDir: instanceDir)
        hosted.pid = pid
        hosted.state = .running
        hosted.startPolling()
        return hosted
    }

    var isRunning: Bool { state == .starting || state == .running }

    /// Asks the guest to shut down (ACPI power button); `force` pulls the plug.
    func stop(force: Bool = false) {
        guard isRunning else { return }
        let dir = instanceDir
        Task.detached {
            do {
                _ = try DriverControl.send(DriverControl.Request(op: force ? .forceStop : .stop), instanceDir: dir, timeout: 5)
            } catch {
                // No control socket (still starting, or gone): SIGTERM makes the driver power off.
                if let pid = await self.pid { kill(pid, SIGTERM) }
            }
        }
    }

    /// Shows the VM's window (the driver's) and brings it to the front.
    func openScreen() {
        let dir = instanceDir
        let pid = pid
        Task.detached {
            _ = try? DriverControl.send(DriverControl.Request(op: .openScreen), instanceDir: dir, timeout: 5)
            if let pid { await MainActor.run { NSRunningApplication(processIdentifier: pid)?.activate() } }
        }
    }

    private func ended(status: Int32) {
        poll?.cancel()
        if state == .starting || state == .running {
            let tail = (try? String(contentsOf: instanceDir.appending(path: "hanalima-hosted.log"), encoding: .utf8))?
                .split(separator: "\n").last.map(String.init) ?? ""
            state = status == 0 ? .stopped : .failed(String(localized: "ドライバーが終了しました（終了コード \(status)）。\(tail)"))
        }
    }

    /// Until the VM is reported running, then until the driver is gone (an attached boot has no
    /// Process to watch, so its pid is checked).
    private func startPolling() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                let dir = self.instanceDir
                let status = await Task.detached { try? DriverControl.send(DriverControl.Request(op: .status), instanceDir: dir, timeout: 3) }.value
                if let status {
                    if status.state == "running", self.state == .starting { self.state = .running }
                } else if self.process == nil, let pid = self.pid, kill(pid, 0) != 0 {
                    self.ended(status: 0)
                    return
                }
                if !self.isRunning { return }
            }
        }
    }
}
