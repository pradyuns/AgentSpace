import Foundation
import ApplicationServices
import XCTest
@testable import AgentSpaceCore

final class BackendRoutingTests:XCTestCase {
    private final class SignalRecorder: @unchecked Sendable {
        let lock = NSLock()
        private var values: [(Int32, Int32)] = []
        func append(_ value: (Int32, Int32)) { lock.withLock { values.append(value) } }
        func reset() { lock.withLock { values = [] } }
        var snapshot: [(Int32, Int32)] { lock.withLock { values } }
    }
    private func options(_ values:[String:String]=[:],flags:Set<String>=[]) -> CommandOptions {
        CommandOptions(values:values,flags:flags)
    }

    func testAutoRouting() throws {
        let chrome=try BackendRouter.resolve(request:.init(),app:"chrome")
        XCTAssertEqual(chrome.resolvedBackend,"cdp")
        XCTAssertEqual(chrome.resolvedInteraction,"semantic")
        XCTAssertEqual(chrome.requestedBackend,"auto")
        let native=try BackendRouter.resolve(request:.init(),app:"textedit")
        XCTAssertEqual(native.resolvedBackend,"ax")
        let visual=try BackendRouter.resolve(request:.init(interaction:"visual"),app:"chrome")
        XCTAssertEqual(visual.resolvedBackend,"virtual-display")
        XCTAssertEqual(visual.resolvedInteraction,"visual")
    }

    func testExplicitRouting() throws {
        let vd=try BackendRouter.resolve(request:.init(backend:"virtual-display"),app:"com.apple.TextEdit")
        XCTAssertEqual(vd.resolvedBackend,"virtual-display")
        XCTAssertEqual(vd.resolvedInteraction,"visual")
        let semantic=try BackendRouter.resolve(request:.init(backend:"virtual-display",interaction:"semantic"),app:"com.apple.TextEdit")
        XCTAssertEqual(semantic.resolvedInteraction,"semantic")
        let cdp=try BackendRouter.resolve(request:.init(backend:"cdp"),app:"chrome")
        XCTAssertEqual(cdp.resolvedBackend,"cdp")
        let ax=try BackendRouter.resolve(request:.init(backend:"ax"),app:"com.google.Chrome")
        XCTAssertEqual(ax.resolvedBackend,"ax")
    }

    func testInvalidRoutingFailsBeforeEffects() {
        XCTAssertThrowsError(try BackendRouter.resolve(request:.init(backend:"cdp"),app:"textedit")) { XCTAssertTrue(($0 as? AgentSpaceError)?.description.contains("cdp") ?? false) }
        XCTAssertThrowsError(try BackendRouter.resolve(request:.init(backend:"ax",interaction:"visual"),app:"textedit"))
        XCTAssertThrowsError(try BackendRouter.resolve(request:.init(backend:"cdp",interaction:"visual"),app:"chrome"))
        XCTAssertThrowsError(try BackendRouter.request(backend:"bogus",interaction:nil))
        XCTAssertThrowsError(try BackendRouter.request(backend:nil,interaction:"bogus"))
    }

    func testRequiresVisualDetection() {
        XCTAssertTrue(BackendRouter.requiresVisual(command:"click",options:options(["x":"10","y":"20"])))
        XCTAssertTrue(BackendRouter.requiresVisual(command:"click",options:options(["button":"right"])))
        XCTAssertTrue(BackendRouter.requiresVisual(command:"click",options:options(["count":"2"])))
        XCTAssertTrue(BackendRouter.requiresVisual(command:"move",options:options()))
        XCTAssertTrue(BackendRouter.requiresVisual(command:"drag",options:options()))
        XCTAssertTrue(BackendRouter.requiresVisual(command:"scroll",options:options(["dx":"0","dy":"-120"])))
        XCTAssertFalse(BackendRouter.requiresVisual(command:"click",options:options(["ref":"0.3"])))
        XCTAssertFalse(BackendRouter.requiresVisual(command:"scroll",options:options(["direction":"down"])))
        XCTAssertFalse(BackendRouter.requiresVisual(command:"type-text",options:options(["text":"hi"])))
    }

    func testCoordinateOptionValidation() throws {
        XCTAssertEqual(try options(["x":"10.5","y":"4"]).point()?.x,10.5)
        XCTAssertNil(try options().point())
        XCTAssertThrowsError(try options(["x":"10"]).point())
        XCTAssertThrowsError(try options(["x":"-1","y":"4"]).point())
        XCTAssertThrowsError(try options(["x":"abc","y":"4"]).point())
        XCTAssertThrowsError(try options(["to-x":"1"]).point("to-x","to-y"))
        XCTAssertEqual(try options(["button":"right"]).button(),"right")
        XCTAssertNil(try options().button())
        XCTAssertThrowsError(try options(["button":"fourth"]).button())
        XCTAssertEqual(try options(["count":"2"]).clickCount(),2)
        XCTAssertThrowsError(try options(["count":"9"]).clickCount())
        XCTAssertEqual(try options(["modifiers":"cmd, shift"]).modifierList(),["cmd","shift"])
        XCTAssertThrowsError(try options(["modifiers":"cmd,hyper"]).modifierList())
    }

    func testScrollDeltaMapping() throws {
        let down=try VirtualDisplay.scrollDelta(options(["direction":"down"]))
        XCTAssertEqual(down.dy ?? 0,-320)
        XCTAssertNil(down.dx)
        let up=try VirtualDisplay.scrollDelta(options(["direction":"up","amount":"1","unit":"pages"]))
        XCTAssertEqual(up.dy ?? 0,800)
        let explicit=try VirtualDisplay.scrollDelta(options(["dx":"0","dy":"-120","ticks":"4"]))
        XCTAssertEqual(explicit.dx,0);XCTAssertEqual(explicit.dy,-120);XCTAssertEqual(explicit.ticks,4)
        XCTAssertThrowsError(try VirtualDisplay.scrollDelta(options(["dx":"1","direction":"down"])))
        XCTAssertThrowsError(try VirtualDisplay.scrollDelta(options(["dy":"20000"])))
        XCTAssertThrowsError(try VirtualDisplay.scrollDelta(options(["dx":"1","dy":"1","ticks":"0"])))
        XCTAssertThrowsError(try VirtualDisplay.scrollDelta(options(["unit":"bogus"])))
        XCTAssertThrowsError(try VirtualDisplay.scrollDelta(options(["amount":"0"])))
    }

    func testPointerWindowAttribution() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: .zero, mouseButton: .left))
        try VirtualDisplay.stampPointer(event, windowID: 42)
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 91)!), 42)
        XCTAssertEqual(event.getIntegerValueField(CGEventField(rawValue: 92)!), 42)
        XCTAssertThrowsError(try VirtualDisplay.stampPointer(event, windowID: 0))
    }

    func testDisplaySerialIsStableAndWorkspaceSpecific() {
        XCTAssertEqual(DisplayHost.displaySerial(for: "abc"), 0xba7816bf)
        XCTAssertEqual(DisplayHost.displaySerial(for: ""), 0xe3b0c442)
        XCTAssertNotEqual(DisplayHost.displaySerial(for: "workspace-one"), DisplayHost.displaySerial(for: "workspace-two"))
    }

    func testLegacyWorkspaceDecoding() throws {
        // Workspaces written before backend routing existed must decode unchanged.
        let old="""
        {"name":"legacy","createdAt":740000000,"temporaryDirectory":"/tmp/AgentSpace-x","apps":[],"target":null,"stopped":false}
        """
        let workspace=try JSONDecoder().decode(Workspace.self,from:Data(old.utf8))
        XCTAssertNil(workspace.backend)
        XCTAssertNil(workspace.interaction)
        XCTAssertNil(workspace.virtualDisplay)
        XCTAssertEqual(workspace.interactionMode,.semantic)
        XCTAssertNil(workspace.backendKind)
        let roundTrip=try JSONDecoder().decode(Workspace.self,from:JSONEncoder().encode(workspace))
        XCTAssertEqual(roundTrip,workspace)
    }

    /// A workspace record written by the previous external integration decodes
    /// as `.legacy` so status/abandon can describe it - never so actions run.
    func testLegacyVirtualDisplayRecordDecodesAsLegacy() throws {
        let old="""
        {"sessionID":"s1","lease":"L","controllerID":"c1","executablePath":"/tmp/something","createdAt":740000000}
        """
        let state=try JSONDecoder().decode(VirtualDisplayState.self,from:Data(old.utf8))
        XCTAssertEqual(state.backend,.legacy)
        XCTAssertEqual(state.legacySessionID,"s1")
        XCTAssertEqual(state.legacyControllerID,"c1")
        XCTAssertNil(state.hostPID)
    }

    /// The native record round-trips: pid+start identity, socket, token,
    /// display id/bounds and the pinned observation all survive.
    func testNativeVirtualDisplayStateRoundTrips() throws {
        var state=VirtualDisplayState(hostPID:4242,hostStart:1234.5,socketPath:"/tmp/dh.sock",
            token:"tok",workspaceUUID:"u-1",displayID:7,
            bounds:WindowFrame(x:-1920,y:0,width:1920,height:1080),preset:"1080p")
        state.observation=VirtualDisplayObservation(generation:3,
            elements:[ObservedElement(ref:"0.1",role:"AXButton",title:"Save")],at:Date())
        let decoded=try JSONDecoder().decode(VirtualDisplayState.self,from:JSONEncoder().encode(state))
        XCTAssertEqual(decoded.backend,.native)
        XCTAssertEqual(decoded.hostPID,4242)
        XCTAssertEqual(decoded.displayID,7)
        XCTAssertEqual(decoded.observation?.generation,3)
        XCTAssertEqual(decoded.observation?.elements.first?.ref,"0.1")
    }

    /// A native record missing its identity fields is corrupt, not silently
    /// nil - unless it is a pending-create record, where a missing or
    /// unsignalable identity normalizes to nil rather than a dangerous value.
    func testNativeVirtualDisplayStateRequiresIdentity() throws {
        let bad="""
        {"kind":"native","socketPath":"/tmp/s.sock"}
        """
        XCTAssertThrowsError(try JSONDecoder().decode(VirtualDisplayState.self,from:Data(bad.utf8)))
        func decode(_ json:String)throws->VirtualDisplayState{try JSONDecoder().decode(VirtualDisplayState.self,from:Data(json.utf8))}
        // pending: no identity at all is legal (spawn interrupted pre-launch)
        let pendingNoPID=try decode("""
        {"backend":"native","pendingCreate":true,"socketPath":"/tmp/s","token":"t","workspaceUUID":"u"}
        """)
        XCTAssertNil(pendingNoPID.hostPID)
        // pending: a pid that can never name a process (<=1) or an identity
        // missing its start is normalized to nil, never kept
        for pid in ["-1","0","1"] {
            let s=try decode("""
            {"backend":"native","pendingCreate":true,"hostPID":\(pid),"hostStart":500,
             "socketPath":"/tmp/s","token":"t","workspaceUUID":"u"}
            """)
            XCTAssertNil(s.hostPID,"pending pid \(pid) must normalize to nil")
        }
        let missingStart=try decode("""
        {"backend":"native","pendingCreate":true,"hostPID":4242,"hostStart":null,
         "socketPath":"/tmp/s","token":"t","workspaceUUID":"u"}
        """)
        XCTAssertNil(missingStart.hostPID)
        // established: a usable pid+start identity is mandatory
        for pid in ["null","-1","0","1"] {
            XCTAssertThrowsError(try decode("""
            {"backend":"native","pendingCreate":false,"hostPID":\(pid),"hostStart":500,
             "socketPath":"/tmp/s","token":"t","workspaceUUID":"u"}
            """),"established pid \(pid) must fail to decode")
        }
        XCTAssertThrowsError(try decode("""
        {"backend":"native","pendingCreate":false,"hostPID":4242,"hostStart":null,
         "socketPath":"/tmp/s","token":"t","workspaceUUID":"u"}
        """))
        let ok=try decode("""
        {"backend":"native","pendingCreate":false,"hostPID":4242,"hostStart":500,
         "socketPath":"/tmp/s","token":"t","workspaceUUID":"u"}
        """)
        XCTAssertEqual(ok.hostPID,4242)
        XCTAssertEqual(ok.hostStart,500)
    }

    /// The signal policy never sends a real signal to a pid<=1, to a missing
    /// or non-finite start, or to a pid whose start time no longer matches -
    /// the injected probe proves no dangerous call ever left the process.
    func testDisplayHostSignalPolicy() {
        let sent = SignalRecorder()
        let probe=DisplayHost.Probe(startTime:{_ in 500},
                                    signal:{pid,sig in sent.append((pid,sig));return 0})
        for pid:Int32 in [-1,-42,0,1] {
            XCTAssertFalse(DisplayHost.canSignal(pid))
            XCTAssertFalse(DisplayHost.alive(pid,start:500,probe:probe))
            XCTAssertFalse(DisplayHost.terminate(pid,start:500,signal:SIGTERM,probe:probe))
        }
        for bad:TimeInterval? in [nil,0,-3,.nan,.infinity] {
            XCTAssertFalse(DisplayHost.alive(4242,start:bad,probe:probe))
        }
        sent.reset()
        XCTAssertFalse(DisplayHost.alive(4242,start:999,probe:probe),"recycled pid must fail the identity check")
        XCTAssertTrue(sent.snapshot.allSatisfy{$0.1==0},"only the harmless kill(pid,0) probe may fire")
        sent.reset()
        XCTAssertTrue(DisplayHost.terminate(4242,start:500,signal:SIGTERM,probe:probe))
        XCTAssertEqual(sent.snapshot.count,2)
        XCTAssertEqual(sent.snapshot[0].1,0)
        XCTAssertEqual(sent.snapshot[1].1,SIGTERM)
    }

    /// The fake-display test hook is stripped from every child environment the
    /// production spawn path builds - fake helpers are a test fixture, never
    /// something the CLI can inherit.
    func testSpawnEnvironmentStripsFakeFlag() {
        let clean=DisplayHost.sanitizedEnvironment(["AGENTSPACE_DISPLAY_FAKE":"1","PATH":"/bin"])
        XCTAssertNil(clean["AGENTSPACE_DISPLAY_FAKE"])
        XCTAssertEqual(clean["PATH"],"/bin")
    }

    /// A host reporting a synthetic display is evidence of a test fixture,
    /// never a usable seat - verifyHello rejects it explicitly.
    @MainActor
    func testVerifyHelloRejectsFakeDisplay() {
        let state=VirtualDisplayState(hostPID:4242,hostStart:500,socketPath:"/tmp/s",
            token:"t",workspaceUUID:"u",displayID:nil,bounds:nil,preset:nil)
        let fakeReply:JSONValue = .object(["ok":.bool(true),"display":.object([
            "id":.number(1094862676),"fake":.bool(true),
            "bounds":.object(["x":.number(0),"y":.number(0),"width":.number(640),"height":.number(480)])])])
        XCTAssertThrowsError(try VirtualDisplay.verifyHello(state,reply:fakeReply)){error in
            XCTAssertEqual((error as? AgentSpaceError)?.code,"synthetic_display")
        }
        let missingReply:JSONValue = .object(["ok":.bool(true),"display":.null])
        XCTAssertThrowsError(try VirtualDisplay.verifyHello(state,reply:missingReply)){error in
            XCTAssertEqual((error as? AgentSpaceError)?.code,"display_lost")
        }
    }

    func testRoutingStatePersists() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentSpaceTest-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try StateStore(root:root)
        var workspace=try store.create("route-test",backend:"virtual-display",interaction:"visual")
        defer {try? FileManager.default.removeItem(atPath:workspace.temporaryDirectory)}
        XCTAssertEqual(workspace.requestedBackend,"virtual-display")
        let decision=try BackendRouter.resolve(request:.init(backend:"virtual-display"),app:"com.apple.TextEdit")
        workspace.backend=decision.resolvedBackend
        workspace.interaction=decision.resolvedInteraction
        workspace.routing=decision
        workspace.virtualDisplay=VirtualDisplayState(hostPID:4242,hostStart:1.0,
            socketPath:"/tmp/dh-x.sock",token:"tok",workspaceUUID:"u-1",displayID:3,
            bounds:WindowFrame(x:-1920,y:0,width:1920,height:1080),preset:"1080p")
        try store.save(workspace)
        let loaded=try store.load("route-test")
        XCTAssertEqual(loaded.backend,"virtual-display")
        XCTAssertEqual(loaded.backendKind,.virtualDisplay)
        XCTAssertEqual(loaded.interactionMode,.visual)
        XCTAssertEqual(loaded.routing?.requestedBackend,"virtual-display")
        XCTAssertEqual(loaded.virtualDisplay?.backend,.native)
        XCTAssertEqual(loaded.virtualDisplay?.hostPID,4242)
        XCTAssertEqual(loaded.virtualDisplay?.workspaceUUID,"u-1")
    }

    /// The helper binary location is deterministic: the sibling of the real
    /// executable path (never argv[0]-relative), plus an explicit override.
    /// Nothing external is discovered through PATH.
    func testDisplayHostLocationIsDeterministic() throws {
        // In a test bundle the sibling may or may not exist; either way the
        // result must be the sibling of the running executable, or nil.
        let found=DisplayHost.locate(environment:[:])
        if let found {
            XCTAssertTrue(found.path.hasSuffix("/agentspace-display-host"))
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath:found.path))
        }
        let missing=DisplayHost.locate(environment:["AGENTSPACE_DISPLAY_HOST":"/nonexistent/host"])
        XCTAssertNil(missing)
        let tmp=FileManager.default.temporaryDirectory.appendingPathComponent("host-\(UUID().uuidString)")
        FileManager.default.createFile(atPath:tmp.path,contents:Data(),attributes:[.posixPermissions:0o755])
        defer {try? FileManager.default.removeItem(at:tmp)}
        XCTAssertEqual(DisplayHost.locate(environment:["AGENTSPACE_DISPLAY_HOST":tmp.path])?.path,tmp.path)
    }

    /// The digest feeding the short socket directory name is CryptoKit's
    /// SHA-256 truncated to 8 bytes - not a hand-rolled hash.
    func testSocketHashIsSHA256Prefix() {
        XCTAssertEqual(DisplayHost.socketHash("abc"),"ba7816bf8f01cfea")
        XCTAssertEqual(DisplayHost.socketHash(""),"e3b0c44298fc1c14")
    }

    /// Socket paths never embed the state root: a deep root plus an 80-char
    /// workspace name still lands under the short private socket parent.
    func testSocketPathStaysShortWithDeepRootAndLongName() throws {
        let outer=FileManager.default.temporaryDirectory.appendingPathComponent("as-deep-\(UUID().uuidString)")
        var deep=outer
        for _ in 0..<6 {deep=deep.appendingPathComponent("component-with-a-rather-long-name-xx")}
        let store=try StateStore(root:deep)
        defer {try? FileManager.default.removeItem(at:outer)}
        let long=String(repeating:"w",count:80)
        let path=try DisplayHost.socketPath(for:long,store:store)
        XCTAssertLessThan(path.utf8.count,104)
        XCTAssertFalse(path.contains(deep.path),"the socket path must not embed the state root")
        // The state lock fd must not survive exec into a spawned helper.
        XCTAssertTrue(store.lockFileDescriptorIsCloseOnExec())
    }

    @MainActor
    func testVirtualDisplayLaunchPreflightLeavesNoPin() async throws {
        guard DisplayHost.locate(environment:[:])==nil else {throw XCTSkip("a display host binary is present; missing-binary path not exercised")}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentSpaceTest-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try StateStore(root:root)
        let controller=WorkspaceController(store:store)
        let created=await controller.run("create-workspace",workspace:"vd-test",options:options())
        XCTAssertEqual(created.object?["ok"],.bool(true))
        let launched=await controller.run("launch-app",workspace:"vd-test",options:options(["app":"textedit","backend":"virtual-display"]))
        XCTAssertEqual(launched.object?["ok"],.bool(false))
        guard case .object(let fields)=launched,case .object(let error)=fields["error"] else {return XCTFail("missing error object")}
        XCTAssertEqual(error["code"],.string("virtual_display_unavailable"))
        // Preflight failed before pinning: the workspace keeps no backend, so it is not trapped
        // by a route it can never satisfy - a later launch resolves cleanly instead of hitting
        // backend_locked.
        let workspace=try store.load("vd-test")
        XCTAssertNil(workspace.backend)
        XCTAssertNil(workspace.virtualDisplay)
        // Coordinate commands on the still-unpinned workspace fail the routing check honestly.
        let move=await controller.run("move",workspace:"vd-test",options:options(["x":"10","y":"10"]))
        if case .object(let fields)=move,case .object(let error)=fields["error"] {
            XCTAssertEqual(error["code"],.string("interaction_required"))
        } else {XCTFail("expected interaction_required")}
    }

    /// A workspace whose persisted virtual-display record is legacy refuses
    /// every command with legacy_backend_state - no migration, no action.
    @MainActor
    func testLegacyBackendStateRefused() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentSpaceTest-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try StateStore(root:root)
        let controller=WorkspaceController(store:store)
        _=await controller.run("create-workspace",workspace:"vd-legacy",options:options())
        var workspace=try store.load("vd-legacy")
        let decision=try BackendRouter.resolve(request:.init(backend:"virtual-display"),app:"com.apple.TextEdit")
        workspace.backend=decision.resolvedBackend;workspace.interaction=decision.resolvedInteraction;workspace.routing=decision
        let legacy="""
        {"sessionID":"s1","lease":"L","controllerID":"c1","executablePath":"/tmp/something","createdAt":740000000}
        """
        workspace.virtualDisplay=try JSONDecoder().decode(VirtualDisplayState.self,from:Data(legacy.utf8))
        try store.save(workspace)
        for command in [["observe",[:]],["click",["x":"1","y":"1"]],["type-text",["text":"hi"]]] {
            let result=await controller.run(command[0] as! String,workspace:"vd-legacy",options:options(command[1] as! [String:String]))
            guard case .object(let fields)=result,case .object(let error)=fields["error"] else {return XCTFail("missing error for \(command[0])")}
            XCTAssertEqual(error["code"],.string("legacy_backend_state"),"\(command[0])")
        }
    }

    @MainActor
    func testSemanticWorkspaceRejectsCoordinatesBeforeEffects() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("AgentSpaceTest-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        let store=try StateStore(root:root)
        let controller=WorkspaceController(store:store)
        _=await controller.run("create-workspace",workspace:"ax-test",options:options())
        // Pin to ax/semantic via a failed native launch is not possible without permissions; pin
        // the routing state directly to simulate a live semantic workspace.
        var workspace=try store.load("ax-test")
        let decision=try BackendRouter.resolve(request:.init(backend:"ax"),app:"textedit")
        workspace.backend=decision.resolvedBackend;workspace.interaction=decision.resolvedInteraction;workspace.routing=decision
        try store.save(workspace)
        let click=await controller.run("click",workspace:"ax-test",options:options(["x":"10","y":"10"]))
        guard case .object(let fields)=click,case .object(let error)=fields["error"] else {return XCTFail("missing error")}
        XCTAssertEqual(error["code"],.string("interaction_required"))
        XCTAssertTrue(error["message"]?.string?.contains("virtual-display") ?? false)
        let move=await controller.run("move",workspace:"ax-test",options:options(["x":"1","y":"1"]))
        if case .object(let fields)=move,case .object(let error)=fields["error"] {
            XCTAssertEqual(error["code"],.string("interaction_required"))
        } else {XCTFail("expected interaction_required")}
    }

    func testVirtualDisplayPreValidation() {
        // Ambiguous addressing fails before any host call or AX effect.
        func expect(_ code:String,_ command:String,_ values:[String:String],file:StaticString=#filePath,line:UInt=#line) {
            XCTAssertThrowsError(try VirtualDisplay.preValidate(command,options:options(values)),file:file,line:line) {
                XCTAssertEqual(($0 as? AgentSpaceError)?.code,code,file:file,line:line)
            }
        }
        expect("invalid_option","click",["x":"1","y":"2","ref":"0.3"])
        expect("invalid_option","click",["x":"1","y":"2","role":"AXButton"])
        expect("invalid_option","click",["x":"1","y":"2","button":"bogus"])
        expect("invalid_option","move",[:])
        expect("invalid_option","drag",["from-ref":"0.1","to-ref":"0.2","x":"1","y":"2","to-x":"3","to-y":"4"])
        expect("invalid_option","drag",["from-ref":"0.1"])
        expect("invalid_option","drag",["x":"1","y":"2"])
        expect("missing_option","type-text",["title":"Notes"])
        expect("invalid_option","key",[:])
        expect("invalid_ref","click",["ref":"0.w"])
        expect("invalid_option","observe",["depth":"65"])
        expect("invalid_option","observe",["max-nodes":"20000"])
        // Elements and coordinates are both valid addressing for pointer actions.
        XCTAssertNoThrow(try VirtualDisplay.preValidate("click",options:options(["ref":"0.3"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("click",options:options(["title":"Save","role":"AXButton"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("click",options:options(["x":"1","y":"2","button":"right","count":"2"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("type-text",options:options(["text":"hi","role":"AXTextArea","title":"Notes"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("type-text",options:options(["text":"hi","ref":"0.2"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("key",options:options(["key":"return","role":"AXTextField","label":"Address"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("key",options:options(["key":"return","ref":"0.4"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("move",options:options(["x":"1","y":"2"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("move",options:options(["role":"AXButton"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("move",options:options(["ref":"0.1"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("scroll",options:options(["x":"1","y":"2","direction":"down"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("scroll",options:options(["ref":"0.1","direction":"up"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("drag",options:options(["x":"1","y":"2","to-x":"3","to-y":"4"])))
        XCTAssertNoThrow(try VirtualDisplay.preValidate("drag",options:options(["from-ref":"0.1","to-ref":"0.2"])))
    }

    func testSharedCommandContract() {
        // CLI and MCP both consume AgentSpaceCommands; new commands and routing options must exist once here.
        for command in ["move","drag","self-test","launch-app","click"] {
            XCTAssertTrue(AgentSpaceCommands.commands.contains(command),command)
        }
        for option in ["backend","interaction","preset"] {
            XCTAssertTrue(AgentSpaceCommands.allowed["launch-app"]?.contains(option) ?? false,option)
        }
        for option in ["x","y","button","count","modifiers"] {
            XCTAssertTrue(AgentSpaceCommands.allowed["click"]?.contains(option) ?? false,option)
        }
        for option in ["dx","dy","ticks","x","y"] {
            XCTAssertTrue(AgentSpaceCommands.allowed["scroll"]?.contains(option) ?? false,option)
        }
        for option in ["from-ref","to-ref","to-x","to-y"] {
            XCTAssertTrue(AgentSpaceCommands.allowed["drag"]?.contains(option) ?? false,option)
        }
        XCTAssertTrue(AgentSpaceCommands.flags.contains("screenshot"))
        XCTAssertTrue(AgentSpaceCommands.flags.contains("replace"))
    }

    func testCapabilitiesReport() {
        let vd=BackendRouter.capabilities(backend:.virtualDisplay,interaction:.visual)
        XCTAssertEqual(vd.object?["coordinate"],.bool(true))
        XCTAssertEqual(vd.object?["drag"],.bool(true))
        let ax=BackendRouter.capabilities(backend:.ax,interaction:.semantic)
        XCTAssertEqual(ax.object?["coordinate"],.bool(false))
        let vdSemantic=BackendRouter.capabilities(backend:.virtualDisplay,interaction:.semantic)
        XCTAssertEqual(vdSemantic.object?["coordinate"],.bool(false))
    }
}

private extension JSONValue {
    var object:[String:JSONValue]? { if case .object(let value)=self {return value};return nil }
    var string:String? { if case .string(let value)=self {return value};return nil }
}
