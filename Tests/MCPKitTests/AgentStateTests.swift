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
}
