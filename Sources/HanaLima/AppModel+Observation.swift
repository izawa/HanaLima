import AppKit
import Foundation
import NetworkKit

/// Observing guest-only networks (docs/17): the helpers' counters, read once a second while the
/// map shows, and their packet captures.
struct ObservationSample: Equatable {
    var current: NetworkObservation
    /// The sample before, from the same run of the helper (for rates).
    var previous: NetworkObservation?

    var seconds: Double? { previous.map { current.uptime - $0.uptime } }

    /// No new sample for three seconds when last read: the helper stopped or hangs. Shown as
    /// old, never as zero. Set at each poll, so the view hears when it turns.
    var isStale = false

    func rate(_ counter: KeyPath<NetworkObservation.Port, NetworkObservation.Counter>, port: Int) -> (frames: Double, bytes: Double)? {
        guard let seconds, let old = previous?.ports.first(where: { $0.id == port }),
              let new = current.ports.first(where: { $0.id == port }) else { return nil }
        return NetworkObservation.rate(new[keyPath: counter], old[keyPath: counter], seconds: seconds)
    }
}

extension AppModel {
    /// Reads the status files of the guest-only networks.
    func pollObservations() {
        var samples: [String: ObservationSample] = [:]
        var older: Set<String> = []
        for network in virtualNetworks where network.isGuestOnly {
            let current: NetworkObservation
            switch NetworkObservation.Reading.load(network: network.name) {
            case .sample(let sample): current = sample
            case .olderHelper: older.insert(network.name); continue
            case .notRunning: continue
            }
            // The sample before, if from the same run: a restarted helper counts from zero again.
            var previous: NetworkObservation?
            if let last = observations[network.name], last.current.runID == current.runID {
                previous = last.current.sequence < current.sequence ? last.current : last.previous
            }
            samples[network.name] = ObservationSample(current: current, previous: previous,
                                                      isStale: current.isStale(at: .now))
        }
        if samples != observations { observations = samples }
        if older != olderHelpers { olderHelpers = older }
    }

    func startCapture(_ network: String) {
        control(network, .init(op: .startCapture), failure: String(localized: "パケットの記録を始められませんでした"))
    }

    func stopCapture(_ network: String, id: String) {
        control(network, .init(op: .stopCapture, capture: id), failure: String(localized: "パケットの記録を止められませんでした"))
    }

    /// Starts a fault (docs/18). The control socket starts the helper if needed, so a fault can
    /// be in place before the VMs boot.
    func startFault(_ network: String, _ spec: NetworkFault.Spec) {
        control(network, .init(op: .startFault, fault: spec), failure: String(localized: "障害を入れられませんでした"))
    }

    /// Removes the fault `id`, or all of the network's faults with nil.
    func stopFault(_ network: String, id: String?) {
        control(network, .init(op: .stopFault, faultID: id), failure: String(localized: "障害を外せませんでした"))
    }

    /// Whether faults can be started on `network`: its helper says so, or no helper runs and the
    /// registration has the control socket (it then starts the current helper).
    func canStartFault(_ network: String) -> Bool {
        if let sample = observations[network] { return sample.current.supportsFaults }
        return !olderHelpers.contains(network) && NetworkDaemonStatus.load(for: network) == nil
            && FileManager.default.fileExists(atPath: NetworkPaths.control(for: network).path)
    }

    /// The fault in force on a VM's NIC with `macs`, or on the whole segment.
    func fault(on network: String, macs: [String]) -> NetworkFault? {
        observations[network]?.current.faults?.first { $0.spec.isSegment || macs.contains($0.spec.target) }
    }

    /// One request on the network's control socket, off the main actor; then the counters again.
    private func control(_ network: String, _ request: NetdControl.Request, failure: String) {
        let socket = NetworkPaths.control(for: network).path
        Task {
            do {
                _ = try await Task.detached { try NetdControl.send(request, to: socket) }.value
            } catch {
                alert = AlertMessage(title: failure, message: error.localizedDescription)
            }
            pollObservations()
        }
    }

    func openCapture(_ capture: NetworkObservation.Capture) {
        NSWorkspace.shared.open(URL(filePath: capture.file))
    }

    func revealCapture(_ capture: NetworkObservation.Capture) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: capture.file)])
    }
}

#if DEBUG
extension AppModel {
    /// Made-up counters for the screenshots (`HANALIMA_SNAPSHOT_OBSERVE=<network>`), with the
    /// map's VMs on that network as ports and a capture running.
    func fakeObservationForSnapshot(_ network: String) {
        let map = networkMap
        guard let bus = map.buses.first(where: { $0.name == network }) else { return }
        func sample(_ seq: UInt64, _ scale: UInt64) -> NetworkObservation {
            let ports = map.members(of: bus.id).enumerated().map { i, row in
                var p = NetworkObservation.Port(id: i + 1, macs: row.ports.first { $0.bus == bus.id }?.macs ?? [], connectedAt: .now)
                p.fromGuest = .init(frames: 120 * scale + UInt64(i) * 7, bytes: 9_800 * scale)
                p.toGuest = .init(frames: 110 * scale, bytes: 9_100 * scale)
                if i == 1 { p.droppedFull = .init(frames: 3, bytes: 4_500) }
                return p
            }
            var o = NetworkObservation(runID: "snap", sequence: seq, sampledAt: .now, uptime: Double(seq), ports: ports)
            o.answered = .init(frames: 14, bytes: 4_200)
            o.flooded = 31
            var c = NetworkObservation.Capture(id: "abcd1234", file: "/tmp/x.pcap", startedAt: .now.addingTimeInterval(-40))
            c.frames = 812; c.bytes = 96_000
            o.capture = c
            o.capabilities = [NetworkObservation.faultsCapability]
            if let mac = map.members(of: bus.id).first?.ports.first(where: { $0.bus == bus.id })?.macs.first {
                o.faults = [NetworkFault(id: "f1", spec: .init(target: mac, delayMs: 100, lossPercent: 1, seconds: 300),
                                         startedAt: .now.addingTimeInterval(-60), expiresAt: .now.addingTimeInterval(240))]
                if !ports.isEmpty {
                    o.ports[0].droppedLoss = .init(frames: 4, bytes: 380)
                    o.ports[0].delayed = .init(frames: 6, bytes: 600)
                }
            }
            return o
        }
        observations[network] = ObservationSample(current: sample(10, 10), previous: sample(9, 9))
    }
}
#endif
