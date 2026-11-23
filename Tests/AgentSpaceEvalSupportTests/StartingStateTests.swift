import XCTest
@testable import AgentSpaceEvalSupport

final class StartingStateTests: XCTestCase {
    func testKinds() {
        XCTAssertEqual(StartingState.kinds(scenario: "S3", variant: "default"), ["textedit", "chrome"])
        XCTAssertEqual(StartingState.kinds(scenario: "S2", variant: "safari-range-insertion"), ["safari"])
        XCTAssertEqual(StartingState.kinds(scenario: "S5", variant: "default"), ["textedit"])
        XCTAssertEqual(StartingState.kinds(scenario: "S7", variant: "default"), [])
        XCTAssertNil(StartingState(rawValue: "invalid"))
    }
    func testColdRequiresNoProcesses() throws {
        try StartingState.cold.validate(kinds: ["chrome"], processes: [:], documents: [])
        XCTAssertThrowsError(try StartingState.cold.validate(kinds: ["chrome"], processes: ["chrome": 1], documents: []))
    }
    func testWarmRequiresProcessAndDocument() throws {
        try StartingState.warm.validate(kinds: ["safari"], processes: ["safari": 1], documents: ["safari"])
        XCTAssertThrowsError(try StartingState.warm.validate(kinds: ["safari"], processes: [:], documents: ["safari"]))
        XCTAssertThrowsError(try StartingState.warm.validate(kinds: ["safari"], processes: ["safari": 1], documents: []))
    }
    func testActualBehaviorRequiresVerifiedIdentity() {
        XCTAssertEqual(StartingState.behavior(reported: "1:2:3", before: ["1:2:3"], after: ["1:2:3"]), "reused")
        XCTAssertEqual(StartingState.behavior(reported: "1:2:4", before: ["1:2:3"], after: ["1:2:4"]), "launched")
        XCTAssertEqual(StartingState.behavior(reported: nil, before: [], after: []), "unverified")
        XCTAssertEqual(StartingState.behavior(reported: "1:2:3", before: [], after: []), "unverified")
    }
}
