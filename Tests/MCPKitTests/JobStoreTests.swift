import Foundation
import Testing
@testable import MCPKit

@MainActor
struct JobStoreTests {
    private func submit(_ store: JobStore, key: String = "key", approval: Bool = false) throws -> Job {
        try store.submit(key: key, tool: "start", input: ["targets": ["web1"]],
                         summary: "start web1", needsApproval: approval).job
    }

    @Test func keyReuseAndConflict() throws {
        let store = JobStore()
        let first = try store.submit(key: "key", tool: "start", input: ["key": "key", "targets": ["web1"]],
                                     summary: "start web1", needsApproval: true)
        #expect(first.isNew)
        #expect(first.job.id == "j1")
        #expect(first.job.input == ["targets": ["web1"]])
        let retry = try store.submit(key: "key", tool: "start", input: ["targets": ["web1"]],
                                     summary: "ignored", needsApproval: false)
        #expect(!retry.isNew)
        #expect(retry.job == first.job)
        #expect(throws: JobStoreError.keyConflict(jobID: "j1")) {
            try store.submit(key: "key", tool: "start", input: ["targets": ["web2"]],
                             summary: "start web2", needsApproval: false)
        }
        #expect(throws: JobStoreError.keyConflict(jobID: "j1")) {
            try store.submit(key: "key", tool: "stop", input: ["targets": ["web1"]],
                             summary: "stop web1", needsApproval: false)
        }
        #expect(try submit(store, key: "another").id == "j2")
    }

    @Test func transitionsAndNotifications() throws {
        let store = JobStore()
        var changes = 0
        store.onChange = { changes += 1 }
        let job = try submit(store, approval: true)
        #expect(job.seq == 1)
        #expect(!job.state.isFinished)
        store.setCurrent(job.id, "ignored")
        store.record(job.id, .init(target: "ignored", outcome: "done"))
        store.finish(job.id)
        #expect(store.job(job.id) == job)
        try store.approve(job.id)
        store.setCurrent(job.id, "web1")
        store.setCurrent(job.id, "web1")
        store.record(job.id, .init(target: "web1", outcome: "done"))
        store.finish(job.id)
        let finished = try #require(store.job(job.id))
        #expect(finished.state == .succeeded)
        #expect(finished.current == nil)
        #expect(finished.seq == 5)
        #expect(changes == 5)
        #expect(throws: JobStoreError.notAwaitingApproval) { try store.approve(job.id) }
        try store.deny(job.id)
        try store.cancel(job.id)
        store.setCurrent(job.id, "web2")
        store.record(job.id, .init(target: "web2", outcome: "failed"))
        store.finish(job.id)
        #expect(store.job(job.id) == finished)
        #expect(changes == 5)
        let denied = try submit(store, key: "denied", approval: true)
        try store.deny(denied.id)
        #expect(store.job(denied.id)?.state == .denied)
        #expect(store.job(denied.id)?.seq == 2)
        #expect(throws: JobStoreError.notFound) { try store.approve("unknown") }
        #expect(throws: JobStoreError.notFound) { try store.deny("unknown") }
        #expect(throws: JobStoreError.notFound) { try store.cancel("unknown") }
        store.finish("unknown")
        store.setCurrent("unknown", nil)
        store.record("unknown", .init(target: "x", outcome: "done"))
    }

    @Test(arguments: [
        ([String](), JobState.succeeded),
        (["done", "skipped"], .succeeded),
        (["failed", "failed"], .failed),
        (["done", "failed"], .partial),
        (["skipped", "failed"], .partial),
        (["notConfirmed"], .partial),
    ])
    func finishRules(outcomes: [String], expected: JobState) throws {
        let store = JobStore()
        let job = try submit(store)
        for (index, outcome) in outcomes.enumerated() {
            store.record(job.id, .init(target: "web\(index)", outcome: outcome))
        }
        store.finish(job.id)
        #expect(store.job(job.id)?.state == expected)
        #expect(expected.isFinished)
    }

    @Test func cancelApprovalAndRunning() throws {
        let store = JobStore()
        let pending = try submit(store, approval: true)
        try store.cancel(pending.id)
        #expect(store.job(pending.id)?.state == .cancelled)
        #expect(store.job(pending.id)?.seq == 2)
        let running = try submit(store, key: "running")
        store.setCurrent(running.id, "web1")
        try store.cancel(running.id)
        #expect(store.job(running.id)?.state == .running)
        #expect(store.job(running.id)?.cancelRequested == true)
        try store.cancel(running.id)
        #expect(store.job(running.id)?.seq == 3)
        store.record(running.id, .init(target: "web1", outcome: "done"))
        store.finish(running.id)
        #expect(store.job(running.id)?.state == .cancelled)
        #expect(store.job(running.id)?.current == nil)
    }

    @Test func waitReturnsImmediatelyWhenNeeded() async throws {
        let store = JobStore()
        #expect(await store.wait("unknown", after: 0, timeout: .seconds(1)) == nil)
        let pending = try submit(store, approval: true)
        #expect(await store.wait(pending.id, after: 0, timeout: .seconds(1)) == pending)
        // Awaiting approval, nothing new: waits for the approval (here, until the timeout).
        #expect(await store.wait(pending.id, after: pending.seq, timeout: .milliseconds(20)) == pending)
        let running = try submit(store, key: "running")
        #expect(await store.wait(running.id, after: 0, timeout: .seconds(1)) == running)
        store.finish(running.id)
        #expect(await store.wait(running.id, after: 100, timeout: .seconds(1))?.state == .succeeded)
    }

    @Test func waitReturnsOnChangeAndTimeout() async throws {
        let store = JobStore()
        let job = try submit(store)
        let change = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(10))
            store.setCurrent(job.id, "web1")
        }
        let updated = await store.wait(job.id, after: 1, timeout: .seconds(1))
        try await change.value
        #expect(updated?.seq == 2)
        #expect(updated?.current == "web1")
        let clock = ContinuousClock()
        let start = clock.now
        let timedOut = await store.wait(job.id, after: 2, timeout: .milliseconds(20))
        #expect(start.duration(to: clock.now) >= .milliseconds(20))
        #expect(timedOut == store.job(job.id))
    }

    @Test func waitReturnsOnFinishEvenWithFutureSequenceAndZeroRetention() async throws {
        let store = JobStore(keep: 0)
        let job = try submit(store)
        let finish = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(10))
            store.finish(job.id)
        }
        let result = await store.wait(job.id, after: 100, timeout: .seconds(1))
        try await finish.value
        #expect(result?.state == .succeeded)
        #expect(store.job(job.id) == nil)
    }

    @Test func multipleWaitersAndCancellation() async throws {
        let store = JobStore()
        let job = try submit(store)
        let first = Task { await store.wait(job.id, after: 1, timeout: .seconds(1)) }
        let second = Task { await store.wait(job.id, after: 1, timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10))
        store.setCurrent(job.id, "web1")
        #expect(await first.value?.seq == 2)
        #expect(await second.value?.seq == 2)
        let cancelled = Task { await store.wait(job.id, after: 2, timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        #expect(await cancelled.value == store.job(job.id))
    }

    @Test func expiryAndListingOrder() throws {
        var date = Date(timeIntervalSince1970: 0)
        let store = JobStore(now: { date }, approvalTimeout: 10)
        let first = try submit(store, key: "first", approval: true)
        let second = try submit(store, key: "second", approval: true)
        let running = try submit(store, key: "running")
        #expect(store.jobs.map(\.id) == [running.id, second.id, first.id])
        #expect(store.awaitingApproval.map(\.id) == [first.id, second.id])
        date = date.addingTimeInterval(10)
        store.expireStale()
        #expect(store.job(first.id)?.state == .awaitingApproval)
        date = date.addingTimeInterval(1)
        #expect(store.awaitingApproval.isEmpty)
        #expect(store.job(first.id)?.state == .expired)
        #expect(store.job(first.id)?.seq == 2)
        #expect(store.job(second.id)?.state == .expired)
        #expect(store.job(running.id)?.state == .running)
        store.expireStale()
        #expect(store.job(first.id)?.seq == 2)
        let third = try submit(store, key: "third", approval: true)
        date = date.addingTimeInterval(11)
        #expect(store.jobs.first?.state == .expired)
        #expect(store.job(third.id)?.state == .expired)
    }

    @Test func retentionDropsOldestFinishedOnly() throws {
        let store = JobStore(keep: 2)
        let pending = try submit(store, key: "pending", approval: true)
        let first = try submit(store, key: "first")
        let second = try submit(store, key: "second")
        let third = try submit(store, key: "third")
        store.finish(third.id)
        store.finish(second.id)
        store.finish(first.id)
        #expect(store.jobs.map(\.id) == [third.id, second.id, pending.id])
        #expect(store.job(first.id) == nil)
        #expect(try submit(store, key: "first").id == "j5")
        try store.deny(pending.id)
        #expect(store.job(pending.id) == nil)
    }

    @Test func textFormat() throws {
        let store = JobStore()
        let job = try submit(store, approval: true)
        #expect(JobStore.text(job, detail: false) == """
        job j1\tawaitingApproval\tseq=1\tstart web1
        waiting\tapproval in the HanaLima app (ask the user)
        """)
        try store.approve(job.id)
        store.setCurrent(job.id, "web4")
        store.record(job.id, .init(target: "web1", outcome: "done"))
        store.record(job.id, .init(target: "web2", outcome: "skipped"))
        store.record(job.id, .init(target: "web3", outcome: "failed", message: "already stopped"))
        store.record(job.id, .init(target: "web4", outcome: "notConfirmed"))
        let updated = try #require(store.job(job.id))
        #expect(JobStore.text(updated, detail: false) == """
        job j1\trunning\tseq=7\tstart web1
        current\tweb4
        target\toutcome\tmessage
        web2\tskipped\t
        web3\tfailed\talready stopped
        web4\tnotConfirmed\t
        done\t1
        """)
        #expect(JobStore.text(updated, detail: true) == """
        job j1\trunning\tseq=7\tstart web1
        current\tweb4
        target\toutcome\tmessage
        web1\tdone\t
        web2\tskipped\t
        web3\tfailed\talready stopped
        web4\tnotConfirmed\t
        """)
    }

    @Test func expiredJobCannotBeApproved() throws {
        var date = Date(timeIntervalSince1970: 0)
        let store = JobStore(now: { date }, approvalTimeout: 10)
        let job = try submit(store, approval: true)
        date += 11
        #expect(throws: JobStoreError.notAwaitingApproval) { try store.approve(job.id) }
        #expect(store.job(job.id)?.state == .expired)
    }

    @Test func existingFindsTheJobByKeyBeforeAnythingElse() throws {
        let store = JobStore()
        let job = try submit(store, key: "k")
        #expect(try store.existing(key: "k", tool: "start", input: ["targets": ["web1"], "key": "k"])?.id == job.id)
        #expect(try store.existing(key: "other", tool: "start", input: [:]) == nil)
        #expect(throws: JobStoreError.keyConflict(jobID: job.id)) { try store.existing(key: "k", tool: "start", input: ["targets": ["web2"]]) }
    }

    @Test func cancelReturnsTheJobEvenWhenRetentionDropsIt() throws {
        let store = JobStore(keep: 0)
        let pending = try submit(store, key: "p", approval: true)
        let cancelled = try store.cancel(pending.id)
        #expect(cancelled.state == .cancelled)
        #expect(store.job(pending.id) == nil)
    }
}
