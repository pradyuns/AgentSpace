import XCTest
@testable import AgentSpaceCore

final class MCPFramingTests: XCTestCase {
    func testFragmentedAndCoalescedMessages() throws {
        var framing = MCPFraming()
        XCTAssertTrue(try framing.append(Data("{\"id\":".utf8)).isEmpty)
        let lines = try framing.append(Data("1}\n{\"id\":\"two\"}\r\n".utf8))
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: lines[0]), .object(["id": .number(1)]))
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: lines[1]), .object(["id": .string("two")]))
        XCTAssertNoThrow(try framing.finish())
    }

    func testResponseRoundTripAndEscapedNewline() throws {
        var framing = MCPFraming()
        let response = MCPFraming.response(id: .string("request"), result: .string("line one\nline two"))
        let data = try MCPFraming.encode(response)
        XCTAssertEqual(data.filter { $0 == 10 }.count, 1)
        let lines = try framing.append(data)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(lines.first)), response)
        XCTAssertNoThrow(try framing.finish())
    }

    func testEmptyMalformedIncompleteAndOversizeFrames() throws {
        var empty = MCPFraming()
        XCTAssertTrue(try empty.append(Data()).isEmpty)
        XCTAssertNoThrow(try empty.finish())
        var malformed = MCPFraming()
        let lines = try malformed.append(Data("not json\n".utf8))
        XCTAssertThrowsError(try JSONDecoder().decode(JSONValue.self, from: XCTUnwrap(lines.first)))
        _ = try malformed.append(Data("{".utf8))
        XCTAssertThrowsError(try malformed.finish())
        var oversized = MCPFraming()
        XCTAssertThrowsError(try oversized.append(Data(repeating: 65, count: MCPFraming.maximumBytes + 1)))
        XCTAssertEqual(MCPFraming.error(id: .number(4), code: -32601, message: "missing"),
                       .object(["jsonrpc": .string("2.0"), "id": .number(4), "error": .object(["code": .number(-32601), "message": .string("missing")])]))
    }
}
