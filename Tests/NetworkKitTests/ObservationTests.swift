import Foundation
import Testing
@testable import NetworkKit

struct ObservationTests {
    @Test func pcapHeaderAndRecord() {
        let header = PcapFormat.fileHeader()
        #expect(header.count == 24)
        #expect(Array(header.prefix(4)) == [0xd4, 0xc3, 0xb2, 0xa1])  // little-endian, microseconds
        #expect(Array(header.suffix(4)) == [1, 0, 0, 0])               // Ethernet
        let frame: [UInt8] = Array(repeating: 0xab, count: 60)
        let time = Date(timeIntervalSince1970: 1_700_000_000.25)
        let record = frame.withUnsafeBytes { PcapFormat.record($0, at: time) }
        #expect(record.count == 16 + 60)
        func u32(_ at: Int) -> UInt32 { record.subdata(in: at..<at + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        #expect(u32(0) == 1_700_000_000)
        #expect(u32(4) == 250_000)
        #expect(u32(8) == 60 && u32(12) == 60)
    }

    @Test func bufferNeverBlocksAndCountsWhatItDrops() {
        let buffer = CaptureBuffer(capacity: 100)
        #expect(buffer.offer(Data(count: 60)))
        #expect(!buffer.offer(Data(count: 60)))  // would exceed the capacity
        #expect(buffer.lost == 1)
        #expect(buffer.take()?.count == 1)
        #expect(buffer.offer(Data(count: 60)))   // room again after the writer took it
        buffer.close()
        #expect(!buffer.offer(Data(count: 1)))
        #expect(buffer.take()?.count == 1)       // what was buffered still comes out
        #expect(buffer.take() == nil)
    }

    @Test func olderStatusFilesStillDecode() throws {
        let json = #"{"pid": 12, "startedAt": "2026-11-16T00:00:00Z", "clients": []}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let status = try decoder.decode(NetworkDaemonStatus.self, from: Data(json.utf8))
        #expect(status.observation == nil)
    }

    @Test func ratesOnlyWithinARun() {
        let old = NetworkObservation.Counter(frames: 10, bytes: 1000)
        let new = NetworkObservation.Counter(frames: 30, bytes: 3000)
        let rate = NetworkObservation.rate(new, old, seconds: 2)
        #expect(rate?.frames == 10 && rate?.bytes == 1000)
        #expect(NetworkObservation.rate(old, new, seconds: 2) == nil)  // went down: a restart
    }

    @Test func guestOnlyAgentsGetAControlSocket() {
        let manager = LaunchAgentManager()
        let guestOnly = manager.sockets(for: VirtualNetwork(name: "g", mode: .guestOnly))
        #expect(guestOnly["Control"] != nil && guestOnly["Listener"] != nil)
        #expect(manager.sockets(for: VirtualNetwork(name: "n", mode: .shared))["Control"] == nil)
    }
}
