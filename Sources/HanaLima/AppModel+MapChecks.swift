import AgentKit
import Foundation
import LimaKit
import NetworkKit

/// Reachability checks for the network map (docs/16 §5): run on request, one VM at a time, and
/// kept in memory with the configuration they were made under.
struct MapCheckRequest: Identifiable, Equatable {
    enum Scope: Equatable { case all, vm(String), bus(id: String, name: String) }
    var scope: Scope
    var id: String {
        switch scope {
        case .all: "all"
        case .vm(let name): "vm:\(name)"
        case .bus(let id, _): "bus:\(id)"
        }
    }
}

/// A run in progress.
struct MapCheckRun: Equatable {
    var queue: [String]
    var current: String?
    var done = 0
    var total: Int
    var cancelled = false
}

/// One VM's last results, with what they were made under (`signature`).
struct MapCheckEntry: Equatable {
    var record: MapCheckRecord
    var signature: String
    /// Set once the signature stopped matching, and kept: pausing and resuming, or changing a
    /// network and changing it back, still broke what was checked.
    var stale = false
}

extension AppModel {
    /// The VMs a request would run in, and the ones left out with why.
    func mapCheckTargets(_ request: MapCheckRequest) -> (run: [String], skipped: [(vm: String, reason: String)]) {
        let map = networkMap
        let candidates: [String] = switch request.scope {
        case .all: map.rows.filter { !$0.ports.isEmpty || $0.usernet || $0.vzNAT }.map(\.name)
        case .vm(let name): [name]
        case .bus(let id, _): map.members(of: id).map(\.name)
        }
        var run: [String] = [], skipped: [(String, String)] = []
        for name in candidates {
            if let reason = mapCheckBlocker(name) { skipped.append((name, reason)) } else { run.append(name) }
        }
        return (run, skipped)
    }

    /// Why `name` can't be checked now, or nil.
    func mapCheckBlocker(_ name: String) -> String? {
        guard let inst = instance(named: name) else { return String(localized: "見つかりません") }
        if isHibernated(name) { return String(localized: "休止中") }
        if !inst.isRunning { return String(localized: "停止中") }
        if isPaused(name) { return String(localized: "一時停止中") }
        if isBusy(name) { return String(localized: "処理中") }
        if !isReady(name) { return String(localized: "起動中") }
        return nil
    }

    /// What a VM's results were made under: its boot (the host agent's pid changes at every
    /// start), its pauses (the epoch counts every pause and resume), its NICs and the networks
    /// they are on. A result whose signature no longer matches is stale.
    func mapCheckSignature(_ name: String) -> String {
        guard let inst = instance(named: name) else { return "" }
        let sockets = Set((inst.networks ?? []).compactMap(\.socket))
        let nets = virtualNetworks.filter { sockets.contains($0.socketPath) }.sorted { $0.name < $1.name }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let nics = (try? encoder.encode(inst.networks ?? [])).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let networks = (try? encoder.encode(nets)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return [inst.status.rawValue, "\(inst.hostAgentPID ?? 0)", "\(inst.driverPID ?? 0)", "\(isPaused(name))",
                "\(pauseEpochs[name, default: 0])", nics, networks].joined(separator: "\u{1}")
    }

    func isMapCheckStale(_ name: String) -> Bool {
        guard let entry = mapChecks[name] else { return false }
        return entry.stale || entry.signature != mapCheckSignature(name)
    }

    /// Marks results stale for good once their signature changed (called at every refresh), or
    /// for every VM on a network that was saved or deleted (its helper restarts).
    func invalidateMapChecks(onNetwork socket: String? = nil) {
        if socket != nil { mapCheckNetworkChanges += 1 }
        for (name, entry) in mapChecks where !entry.stale {
            let onIt = socket.map { s in instance(named: name)?.networks?.contains { $0.socket == s } == true } ?? false
            if onIt || entry.signature != mapCheckSignature(name) {
                mapChecks[name]?.stale = true
            }
        }
    }

    /// Runs `request`'s checks, one VM after another. `outside`: an IPv4 address, or nil.
    func runMapChecks(_ request: MapCheckRequest, outside: String?) {
        guard mapCheckRun == nil else { return }
        mapCheckOutside = outside
        let vms = mapCheckTargets(request).run
        guard !vms.isEmpty else { return }
        let onlyBus: String? = if case .bus(let id, _) = request.scope { id } else { nil }
        // The sheet offers no outside address for one network.
        let outside = onlyBus == nil ? outside : nil
        mapCheckRun = MapCheckRun(queue: vms, total: vms.count)
        Task {
            for name in vms {
                guard let run = mapCheckRun, !run.cancelled else { break }
                mapCheckRun?.current = name
                defer { mapCheckRun?.done += 1; mapCheckRun?.current = nil }
                // Checked again: the VM may have stopped or got busy since the sheet.
                guard mapCheckBlocker(name) == nil, let inst = instance(named: name) else { continue }
                let map = networkMap
                let dir = inst.instanceDir
                let probes = MapChecks.plan(map, vms: [name], bus: onlyBus, outside: outside) { _ in
                    LimaMACAddress.address(instanceDir: dir)
                }[name] ?? []
                let row = map.rows.first { $0.name == name }
                let macs = (row?.ports.flatMap(\.macs) ?? []) + [row?.vzNATMAC, LimaMACAddress.address(instanceDir: dir)].compactMap { $0 }
                // No ping to send still reads the guest's addresses (a bridge's, for one).
                guard !probes.isEmpty || !macs.isEmpty else { continue }
                let before = mapCheckSignature(name)
                let networkChanges = mapCheckNetworkChanges
                let result = await runGuestScript(name, script: MapChecks.script(probes: probes, macs: macs),
                                                  timeout: .seconds(60), keepBytes: 16_384) { [weak self] in
                    self?.mapCheckRun?.cancelled == true
                }
                // Cut short by cancel, or the configuration changed meanwhile: keep nothing.
                // A network saved meanwhile restarted its helper, even if it was changed back.
                if mapCheckRun?.cancelled == true || mapCheckSignature(name) != before
                    || mapCheckNetworkChanges != networkChanges { continue }
                let runError = result.error ?? result.exit.flatMap { $0 == 0 ? nil : "exit \($0)" }
                var record = MapChecks.record(probes: probes, output: result.output, runError: runError, at: .now)
                // A network-scoped run replaces only that network's probes.
                if let onlyBus, let old = mapChecks[name], !old.stale, old.signature == before {
                    let kept = old.record.probes.filter { $0.bus != onlyBus }
                    let renamed = kept.enumerated().map { i, p in var p = p; p.id = "k\(i)"; return p }
                    var outcomes = record.outcomes
                    for (o, n) in zip(kept, renamed) { outcomes[n.id] = old.record.outcomes[o.id] }
                    // Every NIC's addresses were read again: the new reading replaces the old one.
                    record = MapCheckRecord(probes: renamed + record.probes, outcomes: outcomes,
                                            observed: record.observed, at: record.at)
                }
                mapChecks[name] = MapCheckEntry(record: record, signature: before)
            }
            mapCheckRun = nil
        }
    }

    func cancelMapChecks() { mapCheckRun?.cancelled = true }
}

#if DEBUG
extension AppModel {
    /// Made-up results for the screenshots (`HANALIMA_SNAPSHOT_MAPCHECKS=1`): no guest runs anything.
    /// Every other probe fails, and the second VM's results are stale.
    func fakeMapChecksForSnapshot() {
        let map = networkMap
        let plans = MapChecks.plan(map, vms: map.rows.map(\.name), outside: "1.1.1.1") { _ in "52:55:55:00:00:00" }
        for (i, row) in map.rows.enumerated() {
            guard let probes = plans[row.name] else { continue }
            var outcomes: [String: MapCheckRecord.Outcome] = [:]
            for (j, p) in probes.enumerated() { outcomes[p.id] = .init(reached: (i + j) % 3 != 2, reason: "no reply") }
            let record = MapCheckRecord(probes: probes, outcomes: outcomes, observed: [:], at: .now.addingTimeInterval(-180))
            mapChecks[row.name] = MapCheckEntry(record: record, signature: i == 1 ? "old" : mapCheckSignature(row.name))
        }
        mapCheckOutside = "1.1.1.1"
    }
}
#endif
