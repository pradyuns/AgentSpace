import XCTest
import AgentSpaceEvalSupport

final class BenchmarkReadingTests: XCTestCase {
    func testStructuredReadbackDoesNotConsumeAXMetadata() {
        XCTAssertEqual(BenchmarkReading.typedValue(#"{"children":[{"value":"typed=VISUAL","role":"AXStaticText"}],"title":"typed=VISUAL;slider=97"}"#), "VISUAL")
        XCTAssertEqual(BenchmarkReading.typedValue(#"{"title":"typed=human;slider=0"}"#), "human")
        XCTAssertEqual(BenchmarkReading.typedValue(#"{"title":"typed=;slider=0"}"#), "")
        XCTAssertNil(BenchmarkReading.typedValue(#"{"value":"typed=truncated","role":"AXStaticText"}"#))
        XCTAssertNil(BenchmarkReading.typedValue(#"["typed=ONE;slider=0","typed=TWO;slider=0"]"#))
    }
    func testTypedReadback() {
        XCTAssertEqual(BenchmarkReading.typedValue("typed=VISUAL;slider=97;hovered=true"), "VISUAL")
        XCTAssertEqual(BenchmarkReading.typedValue("AXWindowTitle=typed=;slider=0"), "")
        XCTAssertEqual(BenchmarkReading.typedValue("typed=human;slider=0"), "human")
        XCTAssertNil(BenchmarkReading.typedValue(""))
        XCTAssertNil(BenchmarkReading.typedValue("typed=truncated"))
        XCTAssertNil(BenchmarkReading.typedValue("spaceo connection error"))
    }
}
