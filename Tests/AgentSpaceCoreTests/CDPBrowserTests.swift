import XCTest
@testable import AgentSpaceCore

final class CDPBrowserTests: XCTestCase {
    @MainActor func testSnapshotNormalEmptyAndBounded() throws {
        let data = Data(#"{"nodes":[{"backendDOMNodeId":12,"role":{"value":"textbox"},"name":{"value":"Message"},"value":{"value":"hello"},"properties":[{"name":"multiline","value":{"value":true}}]},{"backendDOMNodeId":14,"role":{"value":"checkbox"},"name":{"value":"Check"},"properties":[{"name":"checked","value":{"value":"true"}}]},{"backendDOMNodeId":15,"ignored":true,"role":{"value":"button"}}]}"#.utf8)
        let response = try JSONDecoder().decode(JSONValue.self, from: data)
        let tree = CDPBrowser.tree(response, limit: 100)
        XCTAssertEqual(tree.children.count, 2)
        XCTAssertEqual(tree.children[0].role, "AXTextArea")
        XCTAssertEqual(tree.children[0].value, "hello")
        XCTAssertEqual(tree.children[0].ref, "0.12")
        XCTAssertEqual(tree.children[1].value, "1")
        XCTAssertEqual(CDPBrowser.tree(response, limit: 1).children.count, 1)
        XCTAssertTrue(CDPBrowser.tree(.object([:]), limit: 100).children.isEmpty)
        XCTAssertThrowsError(try Selector(title: "Missing").resolve(in: tree))
    }
}
