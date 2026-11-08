import Foundation
import Testing
@testable import LimaKit

@Suite struct GroupRunTests {
    private func member(
        _ name: String, running: Bool = false, busy: Bool = false, hibernated: Bool = false,
        ready: Bool = true, driver: Bool = true, memory: Int64 = 10, refusal: String? = nil,
        deleted: [String] = [], conflict: String? = nil, otherRun: Bool = false
    ) -> GroupMemberFacts {
        .init(name: name, id: UUID(), running: running, busy: busy, hibernated: hibernated,
              ready: ready, hanaLimaDriver: driver, memory: memory, refusal: refusal,
              deletedNetworks: deleted, networkConflict: conflict, inOtherRun: otherRun)
    }

    @Test func startOrderSkipsAndPrecedence() {
        let first = member("first", memory: 20)
        let last = member("last", memory: 0)
        let plan = GroupPlan.make(.start, members: [
            first,
            member("running", running: true, busy: true, hibernated: true,
                   refusal: "disk", deleted: ["old"], otherRun: true),
            member("busy", busy: true, hibernated: true, refusal: "disk", deleted: ["old"], otherRun: true),
            member("other", hibernated: true, refusal: "disk", deleted: ["old"], otherRun: true),
            member("refused", hibernated: true, refusal: "disk", deleted: ["old"]),
            member("saved", hibernated: true, deleted: ["old"]),
            last,
        ])
        #expect(plan.action == .start)
        #expect(plan.steps == [first, last].map {
            .init(name: $0.name, id: $0.id, memory: $0.memory, confirmations: [:], resumes: false)
        })
        #expect(plan.skipped == [
            .init(name: "running", reason: .alreadyRunning),
            .init(name: "busy", reason: .busy),
            .init(name: "other", reason: .inOtherRun),
            .init(name: "refused", reason: .refused("disk")),
            .init(name: "saved", reason: .deletedNetworksWhileHibernated),
        ])
        #expect(plan.memoryToStart == 20)
    }

    @Test func resumeAndConfirmationDetails() {
        let plan = GroupPlan.make(.start, members: [
            member("resume", hibernated: true, memory: 30, conflict: "mixed networks"),
            member("edit", deleted: ["old", "older"], conflict: "conflict"),
            member("normal"),
        ])
        #expect(plan.steps.map(\.resumes) == [true, false, false])
        #expect(plan.steps.map(\.confirmations) == [
            [.allowNetworkConflict: "mixed networks"],
            [.removeDeletedNICs: "old, older", .allowNetworkConflict: "conflict"],
            [:],
        ])
        #expect(plan.memoryToStart == 50)
    }

    @Test func stopReversesOrderAndSkips() {
        let plan = GroupPlan.make(.stop, members: [
            member("first", running: true, ready: false, driver: false, refusal: "disk", deleted: ["old"]),
            member("stopped"),
            member("saved", hibernated: true),
            member("other", hibernated: true, otherRun: true),
            member("busy", busy: true, hibernated: true, otherRun: true),
            member("last", running: true, hibernated: true, conflict: "conflict"),
        ])
        #expect(plan.steps.map(\.name) == ["last", "first"])
        #expect(plan.skipped == [
            .init(name: "busy", reason: .busy),
            .init(name: "other", reason: .inOtherRun),
            .init(name: "saved", reason: .hibernated),
            .init(name: "stopped", reason: .alreadyStopped),
        ])
        #expect(plan.steps.allSatisfy { $0.confirmations.isEmpty && !$0.resumes })
        #expect(plan.memoryToStart == 0)
    }

    @Test func hibernateReversesOrderAndSkips() {
        let plan = GroupPlan.make(.hibernate, members: [
            member("first", running: true, refusal: "disk", deleted: ["old"], conflict: "conflict"),
            member("booting", running: true, ready: false),
            member("driver", running: true, ready: false, driver: false),
            member("stopped", ready: false, driver: false),
            member("saved", hibernated: true, ready: false, driver: false),
            member("other", hibernated: true, otherRun: true),
            member("busy", busy: true, hibernated: true, otherRun: true),
            member("last", running: true),
        ])
        #expect(plan.steps.map(\.name) == ["last", "first"])
        #expect(plan.skipped == [
            .init(name: "busy", reason: .busy),
            .init(name: "other", reason: .inOtherRun),
            .init(name: "saved", reason: .hibernated),
            .init(name: "stopped", reason: .alreadyStopped),
            .init(name: "driver", reason: .notHanaLimaDriver),
            .init(name: "booting", reason: .notReady),
        ])
        #expect(plan.steps.allSatisfy { $0.confirmations.isEmpty && !$0.resumes })
        #expect(plan.memoryToStart == 0)
    }

    private actor Recorder {
        var events: [String] = []
        var approvals: [Set<GroupConfirmation>] = []
        var results: [GroupStepResult] = []
        var cancelled = false

        func isCancelled() -> Bool { cancelled }
        func recheck(_ step: GroupPlan.Step, reason: String? = nil) -> String? {
            events.append("check \(step.name)")
            return reason
        }
        func perform(_ step: GroupPlan.Step, approved: Set<GroupConfirmation>,
                     report: GroupStepReport = .done, cancel: Bool = false) async -> GroupStepReport {
            events.append("begin \(step.name)")
            approvals.append(approved)
            if cancel { cancelled = true }
            await Task.yield()
            events.append("end \(step.name)")
            return report
        }
        func progress(_ result: GroupStepResult) {
            events.append("progress \(result.name)")
            results.append(result)
        }
    }

    @Test func runnerRunsSequentiallyAndContinuesAfterOrdinaryFailure() async {
        let plan = GroupPlan.make(.start, members: [member("a"), member("b"), member("c")])
        let recorder = Recorder()
        let results = await GroupRunner.run(
            plan, approved: [:], isCancelled: { await recorder.isCancelled() },
            recheck: { await recorder.recheck($0) },
            perform: { step, approved in
                await recorder.perform(step, approved: approved, report: step.name == "b" ? .failed("disk") : .done)
            },
            progress: { await recorder.progress($0) })
        #expect(results == [
            .init(name: "a", outcome: .done), .init(name: "b", outcome: .failed("disk")),
            .init(name: "c", outcome: .done),
        ])
        #expect(await recorder.events == [
            "check a", "begin a", "end a", "progress a",
            "check b", "begin b", "end b", "progress b",
            "check c", "begin c", "end c", "progress c",
        ])
        #expect(await recorder.results == results)
    }

    @Test func runnerRequiresAllConfirmationsBeforeRecheck() async {
        let plan = GroupPlan.make(.start, members: [
            member("missing", deleted: ["old"]),
            member("partial", deleted: ["old"], conflict: "mixed"),
            member("approved", deleted: ["old"], conflict: "mixed"),
            member("plain"),
        ])
        let recorder = Recorder()
        let both = Set(GroupConfirmation.allCases)
        let results = await GroupRunner.run(
            plan, approved: ["partial": [.removeDeletedNICs], "approved": both],
            isCancelled: { false }, recheck: { await recorder.recheck($0) },
            perform: { await recorder.perform($0, approved: $1) },
            progress: { await recorder.progress($0) })
        #expect(results.map(\.outcome) == [.notConfirmed, .notConfirmed, .done, .done])
        #expect(await recorder.approvals == [both, []])
        #expect(await recorder.events == [
            "progress missing", "progress partial",
            "check approved", "begin approved", "end approved", "progress approved",
            "check plain", "begin plain", "end plain", "progress plain",
        ])
        #expect(await recorder.results == results)
    }

    @Test func runnerRechecksIdentityAndSkipsChangedVM() async {
        let plan = GroupPlan.make(.start, members: [member("a"), member("b")])
        let recorder = Recorder()
        let results = await GroupRunner.run(
            plan, approved: [:], isCancelled: { false },
            recheck: { step in
                #expect(step.id == plan.steps.first { $0.name == step.name }?.id)
                return await recorder.recheck(step, reason: step.name == "a" ? "record replaced" : nil)
            },
            perform: { await recorder.perform($0, approved: $1) },
            progress: { await recorder.progress($0) })
        #expect(results.map(\.outcome) == [.skipped("record replaced"), .done])
        #expect(await recorder.events == ["check a", "progress a", "check b", "begin b", "end b", "progress b"])
        #expect(await recorder.results == results)
    }

    @Test func runnerCancellationLetsCurrentStepFinish() async {
        let plan = GroupPlan.make(.start, members: [member("a"), member("b"), member("c")])
        let recorder = Recorder()
        let results = await GroupRunner.run(
            plan, approved: [:], isCancelled: { await recorder.isCancelled() },
            recheck: { await recorder.recheck($0) },
            perform: { await recorder.perform($0, approved: $1, cancel: true) },
            progress: { await recorder.progress($0) })
        #expect(results.map(\.outcome) == [.done, .notRun, .notRun])
        #expect(await recorder.events == ["check a", "begin a", "end a", "progress a", "progress b", "progress c"])
        #expect(await recorder.results == results)
    }

    @Test func runnerFatalFailureStopsRemainingSteps() async {
        let plan = GroupPlan.make(.hibernate, members: [
            member("a", running: true), member("b", running: true), member("c", running: true),
        ])
        let recorder = Recorder()
        let results = await GroupRunner.run(
            plan, approved: [:], isCancelled: { false }, recheck: { await recorder.recheck($0) },
            perform: { await recorder.perform($0, approved: $1, report: .failedStoppingRun("locked")) },
            progress: { await recorder.progress($0) })
        #expect(results == [
            .init(name: "c", outcome: .failed("locked")), .init(name: "b", outcome: .notRun),
            .init(name: "a", outcome: .notRun),
        ])
        #expect(await recorder.events == ["check c", "begin c", "end c", "progress c", "progress b", "progress a"])
        #expect(await recorder.results == results)
    }

    @Test func runnerInitiallyCancelledAndEmptyPlan() async {
        for members in [[], [member("a"), member("b")]] {
            let recorder = Recorder()
            let results = await GroupRunner.run(
                .make(.start, members: members), approved: [:], isCancelled: { true },
                recheck: { await recorder.recheck($0) },
                perform: { await recorder.perform($0, approved: $1) },
                progress: { await recorder.progress($0) })
            #expect(results == members.map { .init(name: $0.name, outcome: .notRun) })
            #expect(await recorder.events == members.map { "progress \($0.name)" })
            #expect(await recorder.results == results)
        }
    }
}
