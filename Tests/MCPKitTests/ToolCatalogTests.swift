import Testing
@testable import MCPKit

@Test func catalogHasInspect() {
    #expect(ToolCatalog.tool(named: "inspect") != nil)
}
