import XCTest
import AgentSpaceEvalSupport

final class CursorRestTests: XCTestCase {
    func testWaitsForDeliveryAndFullQuietInterval() {
        XCTAssertEqual(CursorRest.phase(requested: 10, delivered: nil, now: 10.15), .wait)
        XCTAssertEqual(CursorRest.phase(requested: 10, delivered: 10.4, now: 10.41), .wait)
        XCTAssertEqual(CursorRest.phase(requested: 10, delivered: 10.4, now: 10.56), .check)
    }
    func testMissingStaleAndLateDeliveryFail() {
        XCTAssertEqual(CursorRest.phase(requested: 10, delivered: nil, now: 12), .undelivered)
        XCTAssertEqual(CursorRest.phase(requested: 10, delivered: 9, now: 12), .undelivered)
        XCTAssertEqual(CursorRest.phase(requested: 10, delivered: 12.1, now: 12.2), .undelivered)
    }
}
