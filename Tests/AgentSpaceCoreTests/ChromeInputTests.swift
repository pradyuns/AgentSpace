import XCTest
@testable import AgentSpaceCore

final class ChromeInputTests: XCTestCase {
    func testKeyCodesAndUnsupportedKeys() throws {
        XCTAssertEqual(try CDPBrowser.keyParameters("backspace")["windowsVirtualKeyCode"], .number(8))
        XCTAssertEqual(try CDPBrowser.keyParameters("RETURN")["key"], .string("Enter"))
        XCTAssertThrowsError(try CDPBrowser.keyParameters(""))
        XCTAssertThrowsError(try CDPBrowser.keyParameters("cmd+c"))
    }
    @MainActor func testDebugEndpointIsBoundedToLoopbackBrowserPath() {
        XCTAssertEqual(CDPBrowser.debugEndpoint("1234\n/devtools/browser/abc-123\n")?.absoluteString, "ws://127.0.0.1:1234/devtools/browser/abc-123")
        for text in ["", "0\n/devtools/browser/id", "65536\n/devtools/browser/id", "1234\n/devtools/browser/", "1234\n/devtools/browser/id?other", "1234\n//remote/", "1\n/devtools/browser/x\nextra"] {
            XCTAssertNil(CDPBrowser.debugEndpoint(text), text)
        }
    }
    func testWindowToViewportCoordinatesAndZoom() throws {
        let viewport = WindowFrame(x: 0, y: 87, width: 1200, height: 900)
        XCTAssertEqual(try CDPBrowser.viewportPoint(CGPoint(x: 200, y: 187), viewport: viewport, width: 600, height: 450), CGPoint(x: 100, y: 50))
        for point in [CGPoint(x: 10, y: 20), CGPoint(x: 1200, y: 100), CGPoint(x: CGFloat.nan, y: 100)] {
            XCTAssertThrowsError(try CDPBrowser.viewportPoint(point, viewport: viewport, width: 1200, height: 900))
        }
        XCTAssertThrowsError(try CDPBrowser.viewportPoint(CGPoint(x: 10, y: 100), viewport: viewport, width: 0, height: 0))
    }
}
