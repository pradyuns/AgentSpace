import XCTest
import CoreGraphics
import AgentSpaceCore
@testable import AgentSpaceEvalSupport

final class EvaluationTests: XCTestCase {
    func testPointerAttribution() {
        for type: CGEventType in [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel] {
            XCTAssertTrue(Evaluation.untaggedPointer(type: type.rawValue, marker: 0, humanMarker: 42))
            XCTAssertFalse(Evaluation.untaggedPointer(type: type.rawValue, marker: 42, humanMarker: 42))
        }
        XCTAssertFalse(Evaluation.untaggedPointer(type: CGEventType.keyDown.rawValue, marker: 0, humanMarker: 42))
        XCTAssertFalse(Evaluation.untaggedPointer(type: UInt32.max, marker: 0, humanMarker: 42))
    }
    func testWilsonNormalAndEdges() throws {
        let normal = try XCTUnwrap(Evaluation.wilson(passed: 3, total: 5))
        XCTAssertEqual(normal.lower, 0.230724281, accuracy: 1e-8)
        XCTAssertEqual(normal.upper, 0.882379226, accuracy: 1e-8)
        let all = try XCTUnwrap(Evaluation.wilson(passed: 5, total: 5))
        XCTAssertEqual(all.lower, 0.565517535, accuracy: 1e-8)
        XCTAssertEqual(all.upper, 1, accuracy: 1e-12)
        let none = try XCTUnwrap(Evaluation.wilson(passed: 0, total: 5))
        XCTAssertEqual(none.lower, 0, accuracy: 1e-12)
        XCTAssertEqual(none.upper, 0.434482465, accuracy: 1e-8)
        XCTAssertNil(Evaluation.wilson(passed: 0, total: 0))
        XCTAssertNil(Evaluation.wilson(passed: -1, total: 5))
        XCTAssertNil(Evaluation.wilson(passed: 6, total: 5))
    }
    func testStatusRules() {
        XCTAssertEqual(Evaluation.status([]), "UNTESTED")
        XCTAssertEqual(Evaluation.status([nil, nil]), "UNTESTED")
        XCTAssertEqual(Evaluation.status([true, true]), "PASS")
        XCTAssertEqual(Evaluation.status([false, false]), "FAIL")
        XCTAssertEqual(Evaluation.status([true, false]), "PARTIAL")
        XCTAssertEqual(Evaluation.status([true, nil]), "PARTIAL")
        XCTAssertEqual(Evaluation.status([false, nil]), "FAIL")
    }
    func testDeviationExactTimingAllowanceAndRealDeviation() throws {
        let path = [PointSample(time: 0, x: 0, y: 0), PointSample(time: 1, x: 100, y: 0)]
        let exact = try XCTUnwrap(Evaluation.deviation(samples: [PointSample(time: 0.5, x: 0, y: 0), PointSample(time: 1.1, x: 100, y: 0)], path: path, tolerance: 0.04))
        XCTAssertEqual(exact.raw, 0); XCTAssertEqual(exact.adjusted, 0)
        let delayed = try XCTUnwrap(Evaluation.deviation(samples: [PointSample(time: 1.01, x: 0, y: 0)], path: path, tolerance: 0.04))
        XCTAssertEqual(delayed.raw, 100); XCTAssertEqual(delayed.adjusted, 0)
        let actual = try XCTUnwrap(Evaluation.deviation(samples: [PointSample(time: 1.1, x: 0, y: 0)], path: path, tolerance: 0.04))
        XCTAssertEqual(actual.adjusted, 100)
        let between = try XCTUnwrap(Evaluation.deviation(samples: [PointSample(time: 1, x: 50, y: 0)], path: path, tolerance: 0.04))
        XCTAssertEqual(between.adjusted, 50)
        XCTAssertNil(Evaluation.deviation(samples: [], path: path, tolerance: 0.04))
        XCTAssertNil(Evaluation.deviation(samples: path, path: [], tolerance: 0.04))
        XCTAssertNil(Evaluation.deviation(samples: path, path: path, tolerance: -1))
        XCTAssertNil(Evaluation.deviation(samples: [PointSample(time: -1, x: 0, y: 0)], path: path, tolerance: 0.04))
    }
    func testTraceRoundTripAndErrors() throws {
        let event = TraceEvent(sequence: 1, time: 2.5, trial: "s1", kind: "human.keyDown", payload: .object(["text": .string("α\nβ")]))
        var data = try JSONEncoder().encode(event); data.append(10)
        let parsed = try TraceParser.parse(data)
        XCTAssertEqual(parsed.count, 1); XCTAssertEqual(parsed[0].payload["text"].string, "α\nβ")
        XCTAssertEqual(try TraceParser.parse(Data()).count, 0)
        XCTAssertThrowsError(try TraceParser.parse(Data("{}\n".utf8)))
        XCTAssertThrowsError(try TraceParser.parse(data + Data("broken\n".utf8))) { error in
            XCTAssertTrue(String(describing: error).contains("line 2"))
        }
    }
    func testCursorOriginIsHeldUntilFirstHIDMoveArrives() throws {
        let path = [PointSample(time: 0, x: 327, y: 735), PointSample(time: 0.001, x: 150, y: 730)]
        let pending = try XCTUnwrap(Evaluation.deviation(samples: [PointSample(time: 0.002, x: 327, y: 735)], path: path, tolerance: 0.04))
        XCTAssertGreaterThan(pending.raw, 170)
        XCTAssertEqual(pending.adjusted, 0)
        let overdue = try XCTUnwrap(Evaluation.deviation(samples: [PointSample(time: 0.1, x: 327, y: 735)], path: path, tolerance: 0.04))
        XCTAssertGreaterThan(overdue.adjusted, 170)
    }
    func testPercentilesAndJSONAccess() {
        XCTAssertEqual(Evaluation.percentile([4, 1, 3, 2], 0.5), 2)
        XCTAssertEqual(Evaluation.percentile([4, 1, 3, 2], 0.95), 4)
        XCTAssertNil(Evaluation.percentile([], 0.5))
        XCTAssertNil(Evaluation.percentile([1], -1))
        XCTAssertNil(Evaluation.percentile([.infinity], 0.5))
        XCTAssertEqual(JSONValue.null["absent"], .null)
    }
    func testTraceWriterIncludesAllEvents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("trace.jsonl")
        let writer = try TraceWriter(url: url)
        DispatchQueue.concurrentPerform(iterations: 20) { i in writer.emit("sample", trial: "trial", .number(Double(i))) }
        try writer.synchronize()
        let parsed = try TraceParser.parse(Data(contentsOf: url))
        XCTAssertEqual(parsed.map(\.sequence), Array(1...20))
        XCTAssertEqual(Set(parsed.compactMap { $0.payload.number }).count, 20)
        XCTAssertThrowsError(try TraceWriter(url: directory.appendingPathComponent("missing/trace.jsonl")))
    }
}
