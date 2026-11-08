import Foundation
import Testing
@testable import LimaKit

/// Group-wide operations (docs/12 chapter 5) on real VMs: two Alpine VMs on HanaLima's driver
/// (`-a`, `-b`) and one on Lima's vz (`-c`), in the group order a, b, c. `GroupPlan` and
/// `GroupRunner` are what the app uses; the steps here call limactl and the driver's control
/// socket directly, as the app's do.
///
/// Start all boots a, b, c in that order; hibernate all skips c (not HanaLima's driver) and saves
/// b, then a; start all resumes a and b (c is running already); stop all stops c, b, a.
/// Needs `scripts/build-app.sh` first and the Mac unlocked (hibernation). Three VMs, a few minutes.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["HANALIMA_E2E"] == "1"))
struct GroupEndToEndTests {
    let names = ["hanalima-e2e-group-a", "hanalima-e2e-group-b", "hanalima-e2e-group-c"]
    static let helpers = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/HanaLima.app/Contents/Helpers")
    let client = LimaClient(limactlURL: LimaClient.locate()!,
                            environment: ProcessInfo.processInfo.environment.merging(["LIMA_DRIVERS_PATH": helpers.path]) { $1 })

    /// The order steps ran in, across concurrency domains.
    actor Log {
        var entries: [String] = []
        func add(_ s: String) { entries.append(s) }
    }

    @Test(.timeLimit(.minutes(20)))
    func startHibernateResumeStop() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: Self.helpers.appending(path: "lima-driver-hanalima").path),
                     "run scripts/build-app.sh first")
        for name in names { _ = try? await drain(client.delete(name, force: true)) }
        defer { E2ECleanup.deleteInstances(names, environment: ["LIMA_DRIVERS_PATH": Self.helpers.path]) }
        for (name, vmType) in zip(names, [CreateOptions.VMType.hanalima, .hanalima, .vz]) {
            _ = try await drain(client.create(CreateOptions(name: name, template: "alpine", cpus: 1, memoryGiB: 1, diskGiB: 5,
                                                            vmType: vmType, mountNone: true)))
        }
        let ids = Dictionary(uniqueKeysWithValues: names.map { ($0, UUID()) })

        // Start all: a, b, c in group order.
        var plan = GroupPlan.make(.start, members: try await facts(ids))
        #expect(plan.steps.map(\.name) == names)
        #expect(await run(plan).map(\.outcome) == [.done, .done, .done])
        #expect(try await status() == [.running, .running, .running])

        // Hibernate all: c is on Lima's vz, so only b then a.
        plan = GroupPlan.make(.hibernate, members: try await facts(ids))
        #expect(plan.steps.map(\.name) == [names[1], names[0]])
        #expect(plan.skipped == [GroupPlan.Skip(name: names[2], reason: .notHanaLimaDriver)])
        let log = Log()
        let hibernated = await run(plan, log: log)
        #expect(hibernated.map(\.outcome) == [.done, .done])
        #expect(await log.entries == ["hibernate \(names[1])", "hibernate \(names[0])"])
        for name in names.prefix(2) {
            #expect(SavedState.exists(instanceDir: try await dir(name)))
        }

        // Start all again: a and b resume from their saved states; c is already running.
        plan = GroupPlan.make(.start, members: try await facts(ids))
        #expect(plan.steps.map(\.name) == [names[0], names[1]])
        #expect(plan.steps.map(\.resumes) == [true, true])
        #expect(plan.skipped == [GroupPlan.Skip(name: names[2], reason: .alreadyRunning)])
        #expect(await run(plan).map(\.outcome) == [.done, .done])
        for name in names.prefix(2) {
            #expect(!SavedState.exists(instanceDir: try await dir(name)), "the saved state is used once")
        }

        // Stop all: c, b, a.
        plan = GroupPlan.make(.stop, members: try await facts(ids))
        #expect(plan.steps.map(\.name) == names.reversed())
        let stopLog = Log()
        #expect(await run(plan, log: stopLog).map(\.outcome) == [.done, .done, .done])
        #expect(await stopLog.entries == names.reversed().map { "stop \($0)" })
        #expect(try await status() == [.stopped, .stopped, .stopped])
    }

    /// The facts the app would gather (ready = running: limactl start returns when READY).
    private func facts(_ ids: [String: UUID]) async throws -> [GroupMemberFacts] {
        let list = try await client.list()
        return names.compactMap { name in
            guard let inst = list.first(where: { $0.name == name }) else { return nil }
            return GroupMemberFacts(name: name, id: ids[name]!, running: inst.isRunning, busy: false,
                                    hibernated: !inst.isRunning && SavedState.exists(instanceDir: inst.instanceDir),
                                    ready: inst.isRunning, hanaLimaDriver: inst.usesHanaLimaDriver,
                                    memory: inst.memory ?? 0, refusal: nil, deletedNetworks: [],
                                    networkConflict: nil, inOtherRun: false)
        }
    }

    private func run(_ plan: GroupPlan, log: Log = Log()) async -> [GroupStepResult] {
        let client = client
        return await GroupRunner.run(
            plan, approved: [:],
            isCancelled: { false },
            recheck: { _ in nil },
            perform: { step, _ in
                await log.add("\(plan.action.rawValue) \(step.name)")
                do {
                    switch plan.action {
                    case .start: try await drain(client.start(step.name))
                    case .stop: try await drain(client.stop(step.name))
                    case .hibernate:
                        let dir = try #require(try await client.list().first { $0.name == step.name }).instanceDir
                        _ = try DriverControl.send(DriverControl.Request(op: .hibernate), instanceDir: dir, timeout: 120)
                        // Lima sees an ordinary stop once the driver has powered off.
                        let started = Date()
                        while Date().timeIntervalSince(started) < 60,
                              try await client.list().first(where: { $0.name == step.name })?.status != .stopped {
                            try await Task.sleep(for: .seconds(1))
                        }
                    }
                    return .done
                } catch {
                    return .failed("\(error)")
                }
            },
            progress: { _ in })
    }

    private func status() async throws -> [InstanceStatus?] {
        let list = try await client.list()
        return names.map { name in list.first { $0.name == name }?.status }
    }

    private func dir(_ name: String) async throws -> URL {
        try #require(try await client.list().first { $0.name == name }).instanceDir
    }
}

@discardableResult
private func drain(_ s: AsyncThrowingStream<LogEntry, Error>) async throws -> [LogEntry] {
    var out: [LogEntry] = []
    for try await e in s { out.append(e) }
    return out
}
