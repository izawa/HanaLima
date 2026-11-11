import Foundation
import Testing
@testable import MCPKit

@MainActor
struct AgentStateTests {
    @Test func keepsJobsAndLedgerAcrossLaunches() throws {
        let dir = try TestDirectory()
        let url = dir.url.appendingPathComponent("agent-state.json")
        let id = UUID()
        do {
            let state = AgentState(url: url)
            let (done, _) = try state.jobs.submit(key: "a", tool: "apply", input: [:], summary: "build", needsApproval: false)
            state.jobs.finish(done.id)
            _ = try state.jobs.submit(key: "b", tool: "apply", input: [:], summary: "build 2", needsApproval: false)
            state.recordVM(id, name: "router", job: done.id)
            state.recordNetwork("inner", job: done.id)
            #expect(state.saveError == nil)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let again = AgentState(url: url)
        #expect(again.ownsVM(id))
        #expect(again.ownsNetwork("inner"))
        let jobs = again.jobs.jobs
        #expect(jobs.map(\.state) == [.interrupted, .succeeded])
        // A retry of a finished request still finds its job; numbering goes on.
        #expect(try again.jobs.existing(key: "a", tool: "apply", input: [:])?.state == .succeeded)
        #expect(try again.jobs.submit(key: "c", tool: "apply", input: [:], summary: "c", needsApproval: false).job.id == "j3")
        again.forgetVM(id)
        #expect(AgentState(url: url).ownsVM(id) == false)
    }

    @Test func remembersGroupsAndReadsFilesWithoutThem() throws {
        let dir = try TestDirectory()
        let url = dir.url.appendingPathComponent("agent-state.json")
        // A file from before groups were recorded.
        try Data(#"{"version":1,"nextJobID":3,"jobs":[],"vms":[],"networks":{"inner":{"job":"j1"}}}"#.utf8).write(to: url)
        let state = AgentState(url: url)
        #expect(state.ownsNetwork("inner"))
        #expect(!state.ownsGroup("lab2"))
        state.recordGroup("lab2", job: "j2")
        #expect(AgentState(url: url).ownsGroup("lab2"))
        state.forgetGroup("lab2")
        #expect(!AgentState(url: url).ownsGroup("lab2"))
    }

    @Test func noteShowsInTheShortAnswer() throws {
        let state = AgentState(url: nil)
        let (job, _) = try state.jobs.submit(key: "k", tool: "apply", input: [:], summary: "build", needsApproval: false)
        state.jobs.setNote(job.id, "traffic checks verified 9 of 9")
        #expect(JobStore.text(try #require(state.jobs.job(job.id)), detail: false).contains("note\ttraffic checks verified 9 of 9"))
    }
}
