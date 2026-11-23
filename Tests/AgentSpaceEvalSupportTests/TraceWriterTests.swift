import XCTest
@testable import AgentSpaceEvalSupport

final class TraceWriterTests: XCTestCase {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    func testConcurrentWritesFlushInSequence() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TraceWriter(url: url)
        DispatchQueue.concurrentPerform(iterations: 500) { i in
            writer.emit("test", trial: "concurrent", .number(Double(i)))
        }
        try writer.synchronize()
        let events = try TraceParser.parse(Data(contentsOf: url))
        XCTAssertEqual(events.map(\.sequence), Array(1...500))
        XCTAssertEqual(Set(events.compactMap { $0.payload.number }), Set((0..<500).map(Double.init)))
    }

    func testEmptyWriterFlushes() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TraceWriter(url: url)
        try writer.synchronize()
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    func testOverflowFailsInsteadOfSilentlyDroppingEvidence() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TraceWriter(url: url, bufferLimit: 0)
        writer.emit("test", trial: "overflow", .null)
        XCTAssertThrowsError(try writer.synchronize())
    }
}
