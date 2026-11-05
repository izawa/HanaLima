import AppKit
import LimaKit

extension AppModel {
    /// Shows the window of a VM on HanaLima's own driver (`vmType: hanalima`), which the driver
    /// process keeps even when it's been closed. Lima's vz can't reopen its window.
    func openScreen(_ instance: LimaInstance) {
        let dir = instance.instanceDir
        let pid = instance.driverPID
        Task {
            do {
                _ = try await Task.detached { try DriverControl.send(DriverControl.Request(op: .openScreen), instanceDir: dir) }.value
                // The driver activates itself; from the active app this makes it reliable.
                if let pid { NSRunningApplication(processIdentifier: pid_t(pid))?.activate() }
            } catch {
                alert = AlertMessage(title: String(localized: "画面を開けませんでした"), message: "\(error)")
            }
        }
    }
}
