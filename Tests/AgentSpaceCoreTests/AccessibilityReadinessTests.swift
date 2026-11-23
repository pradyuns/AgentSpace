import XCTest
@testable import AgentSpaceCore

final class AccessibilityReadinessTests:XCTestCase {
    @MainActor func testMissingElementCanBecomeReady() async throws {
        var calls=0
        let result=try await AX.resolveWhenReady(interval:.zero) { () throws -> String in
            calls+=1
            if calls<3 {throw AgentSpaceError("element_not_found","Loading")}
            return "exact element"
        }
        XCTAssertEqual(result,"exact element")
        XCTAssertEqual(calls,3)
    }
    @MainActor func testMissingElementIsBounded() async {
        var calls=0
        do {
            let _:String=try await AX.resolveWhenReady(attempts:2,interval:.zero) {
                calls+=1
                throw AgentSpaceError("element_not_found","Absent")
            }
            XCTFail("Expected missing element")
        } catch {XCTAssertEqual((error as? AgentSpaceError)?.code,"element_not_found")}
        XCTAssertEqual(calls,2)
    }
    @MainActor func testAmbiguityAndStaleTargetDoNotRetry() async {
        for code in ["ambiguous_selector","target_unavailable"] {
            var calls=0
            do {
                let _:String=try await AX.resolveWhenReady(interval:.zero) {
                    calls+=1
                    throw AgentSpaceError(code,"Refused")
                }
                XCTFail("Expected rejection")
            } catch {XCTAssertEqual((error as? AgentSpaceError)?.code,code)}
            XCTAssertEqual(calls,1)
        }
    }
    @MainActor func testExactFileDocumentIdentity() throws {
        let requested=FileManager.default.temporaryDirectory.appendingPathComponent("agentspace-\(UUID().uuidString).html")
        try "".write(to:requested,atomically:true,encoding:.utf8)
        defer {try? FileManager.default.removeItem(at:requested)}
        XCTAssertTrue(AX.documentURLMatches(requested.resolvingSymlinksInPath(),requested:requested))
        XCTAssertFalse(AX.documentURLMatches(nil,requested:requested))
        XCTAssertFalse(AX.documentURLMatches(URL(fileURLWithPath:"/var/agentspace-disposable-probe.html.other"),requested:requested))
    }
}
