import Foundation
import XCTest
@testable import AgentSpaceCore

final class CoreTests:XCTestCase {
    func testCaptureWindowMatching() throws {
        let frame=WindowFrame(x:22,y:52,width:1200,height:1048)
        let candidate=CaptureCandidate(id:42,title:"Fixture",frame:frame)
        XCTAssertEqual(try WindowMatcher.resolve([candidate],title:"Fixture - Browser",frame:frame,previousID:nil),42)
        XCTAssertEqual(try WindowMatcher.resolve([candidate],title:"Fixture",frame:nil,previousID:nil),42)
        XCTAssertEqual(try WindowMatcher.resolve([candidate],title:"Different",frame:nil,previousID:42),42)
        XCTAssertThrowsError(try WindowMatcher.resolve([],title:"Fixture",frame:frame,previousID:nil))
        XCTAssertThrowsError(try WindowMatcher.resolve([candidate],title:"Missing",frame:nil,previousID:nil))
        let duplicate=CaptureCandidate(id:43,title:"Other",frame:frame)
        XCTAssertEqual(try WindowMatcher.resolve([candidate,duplicate],title:"Fixture",frame:frame,previousID:nil),42)
        XCTAssertThrowsError(try WindowMatcher.resolve([candidate,duplicate],title:"Ambiguous",frame:frame,previousID:nil))
    }
    func testInsertionVerification() {
        XCTAssertEqual(TextVerification.insertion(original:"abcd",text:"XY",location:1,length:2),"aXYd")
        XCTAssertEqual(TextVerification.insertion(original:"",text:"hello",location:0,length:0),"hello")
        XCTAssertEqual(TextVerification.insertion(original:"a😀b",text:"Z",location:1,length:2),"aZb")
        XCTAssertEqual(TextVerification.insertion(original:"abc",text:"",location:3,length:0),"abc")
        XCTAssertNil(TextVerification.insertion(original:"abc",text:"x",location:-1,length:0))
        XCTAssertNil(TextVerification.insertion(original:"abc",text:"x",location:3,length:1))
        XCTAssertNil(TextVerification.insertion(original:"abc",text:"x",location:Int.max,length:Int.max))
    }
    func testRefs() throws {
        XCTAssertEqual(try ElementRef("0").indices,[])
        XCTAssertEqual(try ElementRef("0.3.1").indices,[3,1])
        for invalid in ["","1","0.","0..2","0.-1","0.a","0.9999999999999999999999999"] {
            XCTAssertThrowsError(try ElementRef(invalid),invalid)
        }
    }
    func testSelectors() throws {
        let root=ElementNode(ref:"0",role:"AXWindow",children:[
            ElementNode(ref:"0.0",role:"AXButton",title:"Submit",label:"Send",value:"Ready"),
            ElementNode(ref:"0.1",role:"AXButton",title:"Cancel"),
            ElementNode(ref:"0.2",role:"AXButton",title:"Submit",value:"Later")])
        XCTAssertEqual(try Selector(role:"AXButton",title:"Submit",label:"Send",valueContains:"ead").resolve(in:root).ref,"0.0")
        XCTAssertEqual(try Selector(title:"Submit",index:1).resolve(in:root).ref,"0.2")
        XCTAssertThrowsError(try Selector(title:"Submit").resolve(in:root))
        XCTAssertThrowsError(try Selector(title:"Missing").resolve(in:root))
        XCTAssertThrowsError(try Selector(index:100).resolve(in:root))
        XCTAssertThrowsError(try Selector(index:-1).resolve(in:root))
        XCTAssertThrowsError(try Selector(role:"AXTextArea").resolve(in:ElementNode(ref:"0",role:"AXWindow")))
    }
    func testStateRoundTripAndLog() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentSpaceTest-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try StateStore(root:root)
        var workspace=try store.create("unit-test")
        defer {try? FileManager.default.removeItem(atPath:workspace.temporaryDirectory)}
        workspace.apps=[AppRecord(pid:123,bundleIdentifier:"example.fixture",launchDate:Date(timeIntervalSince1970:1234),owned:true,kind:"fixture")]
        workspace.target=WindowTarget(pid:123,windowID:42,title:"Disposable",index:0)
        try store.save(workspace)
        XCTAssertEqual(try store.load("unit-test"),workspace)
        XCTAssertEqual(try store.list(),["unit-test"])
        XCTAssertThrowsError(try store.create("unit-test"))
        XCTAssertThrowsError(try store.load("missing"))
        let snapshot=FocusSnapshot(frontmost:Frontmost(pid:1,bundleIdentifier:"example.human",name:"Human"),cursor:CursorPoint(x:10,y:20),axFocusedAppPID:1,axFocusedElementRole:"AXTextArea")
        let log=ActionLog(timestamp:Date(),action:"click",method:"AXPress",latencyMs:2.5,result:.object(["ok":.bool(true)]),before:snapshot,after:snapshot)
        try store.append(log,workspace:"unit-test")
        let recent=try store.recent("unit-test")
        XCTAssertEqual(recent.count,1)
        guard case .object(let object)=recent[0] else {return XCTFail("Expected JSON object")}
        for key in ["timestamp","action","method","latencyMs","result","before","after"] {XCTAssertNotNil(object[key])}
        XCTAssertFalse(log.focusChanged);XCTAssertFalse(log.cursorMoved)
        XCTAssertThrowsError(try StateStore.validate("../escape"))
        XCTAssertThrowsError(try StateStore.validate(""))
        XCTAssertThrowsError(try StateStore.validate("two words"))
    }
    func testJSONShapes() throws {
        let values:[JSONValue]=[.null,.bool(false),.number(1.5),.string("line\nquote\""),.array([]),.object(["nested":.array([.bool(true)])])]
        for value in values {XCTAssertEqual(try JSONDecoder().decode(JSONValue.self,from:JSONEncoder().encode(value)),value)}
        let node=ElementNode(ref:"0",role:"AXWindow",children:[])
        guard case .object(let object)=try JSONValue.encoded(node) else {return XCTFail("Expected object")}
        XCTAssertEqual(object["ref"],.string("0"));XCTAssertEqual(object["children"],.array([]))
        XCTAssertEqual(object["actions"],.array([]))
    }
    func testCoreIsolationSymbols() throws {
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source=root.appendingPathComponent("Sources/AgentSpaceCore")
        let files=(FileManager.default.enumerator(at:source,includingPropertiesForKeys:nil)?.allObjects as? [URL] ?? []).filter{$0.pathExtension=="swift"}
        XCTAssertFalse(files.isEmpty)
        let banned=[#"\.post\s*\(\s*tap\s*:"#,"CGEventPost(","CGWarpMouseCursorPosition","CGAssociateMouseAndMouseCursorPosition","AXRaise","AXMain","kAXFocusedWindowAttribute","\"AXFocusedWindow\""]
        var activationCount=0
        for file in files {
            let text=try String(contentsOf:file,encoding:.utf8)
            XCTAssertNil(text.range(of:#"\bCGEventPost\s*\("#,options:.regularExpression))
            for symbol in banned {
                if symbol==banned[0] {XCTAssertNil(text.range(of:symbol,options:.regularExpression),"Forbidden tap posting in \(file.lastPathComponent)")}
                else {XCTAssertFalse(text.contains(symbol),"Forbidden \(symbol) in \(file.lastPathComponent)")}
            }
            let activation=try NSRegularExpression(pattern:#"\.activate\s*\("#)
            let count=activation.numberOfMatches(in:text,range:NSRange(text.startIndex...,in:text))
            if file.lastPathComponent=="FocusRestoration.swift" {
                XCTAssertEqual(count,1);XCTAssertTrue(text.contains("guard enabled"));XCTAssertTrue(text.contains("--restore-focus"))
                activationCount+=count
            } else {XCTAssertEqual(count,0,"Unexpected activation in \(file.lastPathComponent)")}
            // Element focus is not used in core; this stronger ban also excludes window focus writes.
            XCTAssertFalse(text.contains("kAXFocusedAttribute"));XCTAssertFalse(text.contains("\"AXFocused\""))
        }
        XCTAssertEqual(activationCount,1)
    }
}
