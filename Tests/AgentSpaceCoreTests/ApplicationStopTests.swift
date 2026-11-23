import XCTest
@testable import AgentSpaceCore

final class ApplicationStopTests: XCTestCase {
    @MainActor func testAlreadyExited() async throws {
        let exited = try await WorkspaceController.waitForExit(attempts: 1, interval: .zero) { false }
        XCTAssertTrue(exited)
    }

    @MainActor func testWaitsForAsynchronousExit() async throws {
        var polls = 0
        let exited = try await WorkspaceController.waitForExit(attempts: 5, interval: .zero) {
            polls += 1
            return polls < 4
        }
        XCTAssertTrue(exited)
        XCTAssertEqual(polls, 4)
    }

    @MainActor func testLiveProcessIsNotReportedAsExited() async throws {
        let exited = try await WorkspaceController.waitForExit(attempts: 2, interval: .zero) { true }
        XCTAssertFalse(exited)
    }
}
