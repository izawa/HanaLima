import Testing
@testable import LimaKit

@Suite struct HostInterfacesTests {
    @Test func parsesHardwarePorts() {
        let text = """
        Hardware Port: Ethernet
        Device: en0
        Ethernet Address: aa:bb:cc:dd:ee:ff

        Hardware Port: Wi-Fi
        Device: en1
        """
        #expect(HostInterfaces.parseHardwarePorts(text) == ["en0": "Ethernet", "en1": "Wi-Fi"])
    }
}
