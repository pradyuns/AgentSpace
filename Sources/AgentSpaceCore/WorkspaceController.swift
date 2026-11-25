import AppKit
import ApplicationServices
import ScreenCaptureKit

public struct CommandOptions: Sendable {
    public var values: [String:String]
    public var flags: Set<String>
    public init(values:[String:String]=[:],flags:Set<String>=[]) {self.values=values;self.flags=flags}
    public subscript(_ name:String)->String? {values[name]}
    public func has(_ name:String)->Bool {flags.contains(name)}
    public func required(_ name:String) throws -> String {
        guard let v=values[name] else {throw AgentSpaceError("missing_option","Missing --\(name)")};return v
    }
    public func integer(_ name:String, default fallback:Int, range:ClosedRange<Int>) throws -> Int {
        guard let text=values[name] else {return fallback}
        guard let v=Int(text),range.contains(v) else {throw AgentSpaceError("invalid_option","--\(name) must be in \(range)")};return v
    }
    public func selector() throws -> Selector {
        let index=try values["index"].map { text -> Int in
            guard let n=Int(text),n>=0 else {throw AgentSpaceError("invalid_option","--index must be nonnegative")};return n
        }
        return Selector(role:self["role"],title:self["title"],label:self["label"],valueContains:self["value-contains"],index:index)
    }
}

@MainActor
public final class WorkspaceController {
    public let store:StateStore
    public init(store:StateStore) {self.store=store}

    public func run(_ command:String, workspace name:String, options:CommandOptions) async -> JSONValue {
        let previousWorkspace=try? store.load(name)
        let sessionWorkspace=options["chrome-session"] != nil || command == "session-handoff" || command == "session-resume"
            || previousWorkspace?.chromeSession != nil || previousWorkspace?.abandonedChromeSession != nil
        let before=FocusGuard.snapshot();let start=ContinuousClock.now
        var method="none"
        var ok=true
        var result:JSONValue
        do {
            try StateStore.validate(name)
            let response=try await dispatch(command,name:name,options:options)
            method=response.0;result=response.1
        } catch {
            ok=false
            let error=error as? AgentSpaceError ?? AgentSpaceError("operation_failed",String(describing:error))
            result = .object(["code":.string(error.code),"message":.string(error.description)])
            if let details = error.details {
                result = .object(["code":.string(error.code),"message":.string(error.description),"details":details])
            }
        }
        let after=FocusGuard.snapshot()
        let elapsed=start.duration(to:.now)
        let ms=Double(elapsed.components.seconds)*1000+Double(elapsed.components.attoseconds)/1e15
        let details=sessionWorkspace ? ChromeSession.project(result) : result
        let log=ActionLog(timestamp:Date(),action:command,method:method,latencyMs:ms,result:.object(["ok":.bool(ok),"details":details]),before:before,after:after)
        do {
            if (try? store.load(name)) != nil {try store.append(log,workspace:name)}
        } catch {
            return .object(["ok":.bool(false),"command":.string(command),"workspace":.string(name),
                            "error":.object(["code":.string("log_failed"),"message":.string(String(describing:error))]),
                            "actionResult":result,"guard":(try? .encoded(log)) ?? .null])
        }
        return .object(["ok":.bool(ok),"command":.string(command),"workspace":.string(name),"method":.string(method),
                        ok ? "result":"error":result,"guard":(try? .encoded(log)) ?? .null,
                        "focusChanged":.bool(log.focusChanged),"cursorMoved":.bool(log.cursorMoved)])
    }

    private func dispatch(_ command:String,name:String,options o:CommandOptions) async throws -> (String,JSONValue) {
        if command=="create-workspace" {
            let request=try BackendRouter.request(o)
            return ("state",try .encoded(store.create(name,backend:request.backend,interaction:request.interaction)))
        }
        if command=="list-workspaces" {return ("state",try .encoded(store.list()))}
        if command=="self-test" {return ("self-test",try await SelfTest.run())}
        if command=="prepare" {
            guard AXIsProcessTrusted() else {throw AgentSpaceError("accessibility_permission","Accessibility permission is required before preparing Chrome")}
            var prepared=try store.create(name)
            var options=o;options.values["app"]="chrome"
            // prepare's contract is a visible native Chrome ahead of human work; keep AX the
            // default even though `auto` alone would route Chrome to headless CDP.
            if options.values["backend"] == nil && prepared.requestedBackend == nil {options.values["backend"]="ax"}
            return try await launchApp(&prepared,options:options)
        }
        var workspace=try store.load(name)
        if command=="get-status" {
            let backend=workspace.backendKind ?? (CDPBrowser.active(workspace) ? .cdp:.ax)
            let interaction=workspace.interactionMode
            // The session-status probe is computed once and shared with readiness so it reports
            // on live daemon evidence instead of re-asking - one query per get-status.
            let vdStatus=await VirtualDisplay.sessionStatus(workspace)
            return ("state",.object(["workspace":try .encoded(workspace),"apps":.array(try workspace.apps.map {
                .object(["record":try .encoded($0),"alive":.bool(AX.isAlive($0))])
            }),"window":try (try? AX.target(workspace)).map {try .encoded(AX.node($0,ref:"0"))} ?? .null,
                "permissions":.object(["accessibility":.bool(AXIsProcessTrusted()),"screenCapture":.bool(CGPreflightScreenCaptureAccess())]),
                "backend":.string(backend.rawValue),"interaction":.string(interaction.rawValue),
                "routing":(try? .encoded(workspace.routing)) ?? .null,
                "capabilities":BackendRouter.capabilities(backend:backend,interaction:interaction),
                "readiness":backendReadiness(backend:backend,workspace:workspace,sessionStatus:vdStatus),
                "displayHost":.object(["executable":DisplayHost.locate().map{.string($0.path)} ?? .null,
                                 "virtualDisplayAPI":.string(SelfTest.virtualDisplayAPIStatus()),
                                 "note":.string("AgentSpace-owned helper, built next to agentspace")]),
                "virtualDisplay":vdStatus,
                "chromeSession":ChromeSession.status(workspace,store:store),
                "lastActions":.array(try store.recent(name))]))
        }
        if command=="stop-workspace" {return try await stop(&workspace,options:o)}
        guard !workspace.stopped else {throw AgentSpaceError("workspace_stopped","Create a new workspace; this workspace has been stopped")}
        if command=="launch-app" {return try await launchApp(&workspace,options:o)}
        if command=="session-handoff" {return try await ChromeSession.handoff(&workspace,store:store)}
        if command=="session-resume" {return try await ChromeSession.resume(&workspace,store:store)}
        if workspace.chromeSession != nil {
            guard ["observe","click","type-text","key","scroll"].contains(command) else {
                throw AgentSpaceError("unsupported",
                    "'\(command)' is not available on a chrome-session workspace "
                    + "(observe/click/type-text/key/scroll, session-handoff, session-resume, "
                    + "get-status and stop-workspace are)")
            }
            return try await ChromeSession.perform(command,workspace:&workspace,options:o,store:store)
        }
        let backend:BackendKind
        if let raw=workspace.backend {
            guard let kind=BackendKind(rawValue:raw) else {throw AgentSpaceError("state_invalid","workspace.json records unknown backend '\(raw)'")}
            backend=kind
        } else {backend=CDPBrowser.active(workspace) ? .cdp:.ax}
        // Options that only the virtual-display backend understands are rejected rather than
        // silently ignored on the semantic routes.
        if backend != .virtualDisplay {
            for name in ["preset", "window"] where o[name] != nil {
                throw AgentSpaceError("unsupported_option","--\(name) is only supported on the virtual-display backend")
            }
        }
        // Pointer-seat intent (coordinates, buttons, wheel deltas, move/drag) is checked before
        // any effect so a coordinate action can never start on a semantic-route workspace.
        if BackendRouter.requiresVisual(command:command,options:o) {try requireVisualRouting(workspace,command:command)}
        switch backend {
        case .virtualDisplay:return try await VirtualDisplay.perform(command,workspace:&workspace,options:o,store:store)
        case .cdp:return try await CDPBrowser.perform(command,workspace:&workspace,options:o,store:store)
        case .ax:break
        }
        guard AXIsProcessTrusted() else {throw AgentSpaceError("accessibility_permission","Accessibility permission is required; grant it to the host process in System Settings")}
        switch command {
        case "target-window":return try target(&workspace,options:o)
        case "observe":
            let root=try AX.target(workspace)
            let depth=try o.integer("depth",default:16,range:0...30)
            let limit=try o.integer("max-nodes",default:1000,range:1...10000)
            let (tree,truncated)=AX.tree(root,depth:depth,limit:limit)
            var result:[String:JSONValue]=["tree":try .encoded(tree),"truncated":.bool(truncated)]
            if o.has("screenshot") {result["screenshot"]=try await capture(&workspace,root:root)}
            return (o.has("screenshot") ? "AXTree+ScreenCaptureKit":"AXTree",.object(result))
        case "click":
            let e=try AX.resolve(root:AX.target(workspace),ref:o["ref"],selector:o.selector())
            let actions=AX.actions(e)
            var attempts:[JSONValue]=[]
            for action in ["AXPress","AXConfirm","AXPick"] where actions.contains(action) {
                let status=AX.perform(e,action)
                attempts.append(.object(["method":.string(action),"axError":.number(Double(status.rawValue))]))
                if status == .success {return (action,.object(["dispatched":.bool(true),"verified":.bool(false),"attempts":.array(attempts)]))}
            }
            throw AgentSpaceError("unsupported","No successful AXPress/AXConfirm/AXPick action. Coordinate-based background clicking is not supported")
        case "type-text":return try await typeText(workspace,options:o)
        case "key":
            let root=try AX.target(workspace)
            let key=try o.required("key")
            let parts=key.lowercased().split(separator:"+").map(String.init)
            let selector=try o.selector()
            if ["cmd+a","command+a"].contains(key.lowercased()),o["ref"] != nil || !selector.isEmpty {
                let e=try AX.resolve(root:root,ref:o["ref"],selector:o.selector())
                guard let text=AX.string(e,kAXValueAttribute) else {throw AgentSpaceError("unsupported","Select-all requires a readable text element")}
                var range=CFRange(location:0,length:text.utf16.count)
                guard let value=AXValueCreate(.cfRange,&range) else {throw AgentSpaceError("unsupported","Cannot create text range")}
                let status=AX.set(e,kAXSelectedTextRangeAttribute,value)
                var actual=CFRange()
                let raw=AX.value(e,kAXSelectedTextRangeAttribute)
                let verified=raw.map { CFGetTypeID($0)==AXValueGetTypeID() && AXValueGetValue(unsafeDowncast($0,to:AXValue.self),.cfRange,&actual) && actual.location==0 && actual.length==range.length } ?? false
                guard status == .success,verified else {throw AgentSpaceError("unsupported","AX select-all could not be verified")}
                return ("AXSelectedTextRange",.object(["verified":.bool(true),"selectedUTF16Length":.number(Double(range.length))]))
            }
            try TargetedKeyboard.key(key,pid:workspace.target!.pid)
            try await Task.sleep(for:.milliseconds(120))
            let modifiers=Set(parts.dropLast())
            var result:[String:JSONValue]=["dispatched":.bool(true),"verified":.bool(false)]
            if !modifiers.isDisjoint(with:["cmd","command","ctrl","control"]) {result["warning"] = .string("unverified_modifier_combo")}
            return ("postToPid",.object(result))
        case "scroll":return try await scroll(workspace,options:o)
        default:throw AgentSpaceError("unknown_command","Unknown command '\(command)'")
        }
    }

    private func launch(_ workspace:inout Workspace,options o:CommandOptions) async throws -> (String,JSONValue) {
        let rawApp=try o.required("app")
        let kind=rawApp.lowercased()
        let strategy=o["chrome-launch-strategy"] ?? "standard"
        guard ["hide-unhide","open-background","no-startup-window","standard"].contains(strategy) else {throw AgentSpaceError("invalid_option","Unknown Chrome launch strategy")}
        let named=["textedit":"com.apple.TextEdit","safari":"com.apple.Safari","browser":"com.apple.Safari","chrome":"com.google.Chrome"]
        // Anything containing a dot is treated as a bundle identifier so generic native apps
        // work through the same AX path; alias names keep their special-cased flows.
        let bundle=named[kind] ?? (rawApp.contains(".") ? rawApp : nil)
        guard let bundle,let appURL=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else {throw AgentSpaceError("app_unavailable","Supported apps: textedit, safari (browser), chrome, or an installed bundle identifier like com.apple.Calculator")}
        // Every option is validated BEFORE a single side effect (no temp file, no open call):
        // mutually exclusive choices and options this route does not implement are rejected
        // rather than silently ignored.
        guard !(o["url"] != nil && o["file"] != nil) else {
            throw AgentSpaceError("invalid_option","Use --url or --file, not both")
        }
        guard kind == "textedit" || o["format"] == nil else {
            throw AgentSpaceError("unsupported_option","--format only applies to textedit")
        }
        guard kind != "textedit" || (o["url"] == nil && o["file"] == nil) else {
            throw AgentSpaceError("unsupported_option","textedit creates its own workspace document; --url/--file are not supported for it")
        }
        let temp=URL(fileURLWithPath:workspace.temporaryDirectory,isDirectory:true)
        var url:URL?
        if kind=="textedit" {
            let ext=o["format"] ?? "txt"
            guard ["txt","rtf"].contains(ext) else {throw AgentSpaceError("invalid_option","--format must be txt or rtf")}
            let file=temp.appendingPathComponent("AgentSpace-\(UUID().uuidString).\(ext)")
            try (ext=="rtf" ? "{\\rtf1\\ansi }":"").write(to:file,atomically:true,encoding:.utf8)
            url=file
        } else if let raw=o["url"] ?? o["file"] {
            var parsed:URL
            if o["file"] != nil {parsed=URL(fileURLWithPath:raw)}
            else {guard let candidate=URL(string:raw),["file","http","https"].contains(candidate.scheme?.lowercased() ?? "") else {throw AgentSpaceError("invalid_url","Expected a file, http or https URL")};parsed=candidate}
            if parsed.isFileURL {
                guard FileManager.default.fileExists(atPath:parsed.path) else {throw AgentSpaceError("file_not_found","Local browser file does not exist")}
                let copy=temp.appendingPathComponent("Page-\(UUID().uuidString).html")
                try FileManager.default.copyItem(at:parsed,to:copy);parsed=copy
            }
            url=parsed
        } else if named[kind] != nil {
            throw AgentSpaceError("missing_option","Browser launch needs --url or --file")
        }
        let wanted=url?.lastPathComponent
        let previousPIDs=Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        // A bare launch of a generic bundle id would open inside the user's already-running
        // process: owned=false, every existing window adoptable, and the open itself may send
        // the app reopen events. Refuse BEFORE NSWorkspace delivers any side effects - open a
        // document with --file/--url so only the new document window is claimable.
        if url == nil,
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle && !$0.isTerminated }) {
            throw AgentSpaceError("app_already_running",
                "\(bundle) is already running; a bare launch would adopt the user's process and "
                + "act in its existing windows — open a document with --file or --url instead")
        }
        let config=NSWorkspace.OpenConfiguration();config.activates=false;config.addsToRecentItems=false
        config.createsNewApplicationInstance = kind=="textedit" || kind=="chrome"
        if kind=="chrome" {
            config.hides=true
            config.arguments=["--user-data-dir=\(temp.appendingPathComponent("ChromeProfile").path)","--no-first-run","--no-default-browser-check","--force-renderer-accessibility"]
            if strategy=="standard" {
                config.hides=false
                config.arguments += ["--no-startup-window","--remote-debugging-port=0","--remote-debugging-address=127.0.0.1"]
            }
        }
        let before=FocusGuard.snapshot()
        let previousPID=before.frontmost.map(\.pid) ?? -1
        let watch=ActivationWatch()
        var launchedPIDs=Set<pid_t>()
        var app:NSRunningApplication
        do {
            if kind=="chrome",strategy=="standard" {
                app=try await NSWorkspace.shared.openApplication(at:appURL,configuration:config)
            } else if kind=="chrome",strategy=="no-startup-window" {
                config.arguments.append("--no-startup-window")
                app=try await NSWorkspace.shared.openApplication(at:appURL,configuration:config)
                launchedPIDs.insert(app.processIdentifier)
                workspace.apps.append(AppRecord(pid:app.processIdentifier,bundleIdentifier:bundle,launchDate:app.launchDate,owned:!previousPIDs.contains(app.processIdentifier),kind:kind))
                try store.save(workspace)
                try await Task.sleep(for:.milliseconds(500))
                let second=NSWorkspace.OpenConfiguration();second.activates=false;second.addsToRecentItems=false
                second.createsNewApplicationInstance=true
                second.arguments=config.arguments.filter{$0 != "--no-startup-window"}
                let opener=try await NSWorkspace.shared.open([url!],withApplicationAt:appURL,configuration:second)
                launchedPIDs.insert(opener.processIdentifier)
                if opener.processIdentifier != app.processIdentifier {
                    workspace.apps.append(AppRecord(pid:opener.processIdentifier,bundleIdentifier:bundle,launchDate:opener.launchDate,owned:!previousPIDs.contains(opener.processIdentifier),kind:"chrome-opener"))
                    try store.save(workspace)
                }
            } else if let url {
                app=try await NSWorkspace.shared.open([url],withApplicationAt:appURL,configuration:config)
            } else {
                // Generic apps without a document open in place: an already-running instance is
                // adopted (owned=false below) and no existing user window is raised.
                app=try await NSWorkspace.shared.openApplication(at:appURL,configuration:config)
            }
        }
        catch {_=watch.stop();throw error}
        launchedPIDs.insert(app.processIdentifier)
        var record=AppRecord(pid:app.processIdentifier,bundleIdentifier:bundle,launchDate:app.launchDate,
                             owned:!previousPIDs.contains(app.processIdentifier),kind:kind)
        // The running-app snapshot is a point in time: openApplication can still resolve to an
        // instance the user started between the snapshot and the call. A bare launch must never
        // end up owning nothing yet acting in that process - refuse before it is recorded or
        // any window is targeted. (Document launches are handled below: unowned apps can only
        // ever match the window of the exact document opened.)
        if url == nil, !record.owned {
            _=watch.stop()
            throw AgentSpaceError("app_already_running",
                "\(bundle) launch resolved to an already-running process (pid \(record.pid)); "
                + "AgentSpace will not target a process it did not start")
        }
        if !workspace.apps.contains(where:{$0.pid==record.pid && $0.launchDate==record.launchDate}) {workspace.apps.append(record)}
        // Persist ownership before observing windows so a later failure remains cleanable.
        try store.save(workspace)
        if kind=="chrome",strategy=="standard",let url {
            guard record.owned else {throw AgentSpaceError("app_already_running","Chrome did not launch an owned instance")}
            try await CDPBrowser.openWindow(workspace,profile:temp.appendingPathComponent("ChromeProfile"),url:url)
        }
        var readinessAttempts:[JSONValue]=[]
        var windows:[AXUIElement]=[]
        var index:Int?
        for round in 0..<(kind=="textedit" ? 2:1) {
            let deadline=ContinuousClock.now.advanced(by:.seconds(5))
            repeat {
                windows=AX.windows(app.processIdentifier)
                // For an unowned (already-running) app only the window of the exact document
                // opened is claimable - never the user's pre-existing windows, however few.
                index=windows.firstIndex{
                    (wanted == nil && record.owned) ||
                    ((record.owned || url?.isFileURL == true) && wanted != nil &&
                     AX.string($0,kAXTitleAttribute)?.contains(wanted!)==true)
                    || (url?.isFileURL==true && AX.containsDocument($0,url:url!))
                }
                    ?? (record.owned && windows.count==1 ? 0:nil)
                readinessAttempts.append(.object(["round":.number(Double(round)),"windowCount":.number(Double(windows.count)),"matched":.bool(index != nil)]))
                if index != nil {break}
                try await Task.sleep(for:.milliseconds(100))
            } while ContinuousClock.now < deadline
            if index != nil {break}
            if kind=="textedit",round==0 {
                let reopen=NSWorkspace.OpenConfiguration();reopen.activates=false;reopen.addsToRecentItems=false
                let reopened=try await NSWorkspace.shared.open([url!],withApplicationAt:appURL,configuration:reopen)
                if reopened.processIdentifier != app.processIdentifier {
                    app=reopened
                    record=AppRecord(pid:app.processIdentifier,bundleIdentifier:bundle,launchDate:app.launchDate,owned:!previousPIDs.contains(app.processIdentifier),kind:kind)
                    workspace.apps.append(record);try store.save(workspace)
                }
            }
        }
        var unhidden:Bool?
        if kind=="chrome",strategy=="hide-unhide",index != nil {unhidden=app.unhide()}
        try await Task.sleep(for:.milliseconds(1500))
        let activations=watch.stop()
        let after=FocusGuard.snapshot()
        let currentPID=after.frontmost.map(\.pid) ?? -1
        let launchedPID=app.processIdentifier
        let theft=previousPID != launchedPID && (activations.contains(where:{launchedPIDs.contains($0)}) || launchedPIDs.contains(currentPID))
        var restored=false
        var restorationVerified=false
        if theft {
            let event=ActionLog(timestamp:Date(),action:"focus_theft",method:"NSWorkspace.didActivateApplication",latencyMs:1500,
                                result:.object(["pid":.number(Double(app.processIdentifier)),"activations":try .encoded(activations),"mitigationRequested":.bool(o.has("restore-focus"))]),before:before,after:after)
            try store.append(event,workspace:workspace.name)
            if launchedPIDs.contains(currentPID) {
                restored=FocusRestoration.restore(previous:before.frontmost,enabled:o.has("restore-focus"))
                if o.has("restore-focus") {
                    try await Task.sleep(for:.milliseconds(150))
                    restorationVerified=FocusGuard.snapshot().frontmost?.pid==previousPID
                    try store.append(ActionLog(timestamp:Date(),action:"focus_restoration",method:"explicit_restore_focus",latencyMs:150,
                        result:.object(["requested":.bool(true),"activationAccepted":.bool(restored),"verified":.bool(restorationVerified)]),before:after,after:FocusGuard.snapshot()),workspace:workspace.name)
                }
            }
        }
        workspace.target=nil
        if let index {workspace.target=WindowTarget(pid:app.processIdentifier,windowID:nil,title:AX.string(windows[index],kAXTitleAttribute) ?? "",index:index)}
        try store.save(workspace)
        return ("NSWorkspace.activates=false",.object(["app":try .encoded(record),"openedURL":url.map{.string($0.absoluteString)} ?? .null,
            "launchStrategy":.string(kind=="chrome" ? strategy:"background"),"unhideAccepted":unhidden.map(JSONValue.bool) ?? .null,
            "windowReadinessAttempts":.array(readinessAttempts),
            "warnings":.array((["safari","browser"].contains(kind) ? [.string("background_web_text_input_limited: range-selected AX insertion only; PID fallback is not reliable; Chrome recommended")]:[])
                + (record.owned ? []:[.string("adopted_existing_app: the app was already running; only the window of the exact document opened was targeted — the app's other windows are not workspace-owned")])),
            "target":try .encoded(workspace.target),"focusTheft":.bool(theft),"restorationAccepted":.bool(restored),"restorationVerified":.bool(restorationVerified),
            "activations":try .encoded(activations),"targetReady":.bool(index != nil)]))
    }

    private func target(_ workspace:inout Workspace,options o:CommandOptions) throws -> (String,JSONValue) {
        let pid:pid_t
        if let raw=o["pid"] {guard let value=Int32(raw),workspace.apps.contains(where:{$0.pid==value && AX.isAlive($0)}) else {throw AgentSpaceError("unowned_app","PID is not a live workspace app")};pid=value}
        else if let last=workspace.apps.last(where:{AX.isAlive($0)}) {pid=last.pid}
        else {throw AgentSpaceError("app_unavailable","No live workspace app")}
        let windows=AX.windows(pid)
        let candidates=windows.enumerated().filter{o["title"]==nil || AX.string($0.element,kAXTitleAttribute)==o["title"]}
        let index=try o.integer("index",default:0,range:0...10000)
        guard index<candidates.count else {throw AgentSpaceError("window_not_found","No matching window at index \(index); \(candidates.count) matches")}
        let chosen=candidates[index]
        workspace.target=WindowTarget(pid:pid,windowID:nil,title:AX.string(chosen.element,kAXTitleAttribute) ?? "",index:chosen.offset)
        try store.save(workspace)
        return ("AXWindows",try .encoded(workspace.target))
    }

    private func capture(_ workspace:inout Workspace,root:AXUIElement) async throws -> JSONValue {
        guard CGPreflightScreenCaptureAccess() else {throw AgentSpaceError("screen_capture_permission","Screen Recording permission is required")}
        let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:false)
        let frame=AX.frame(root)
        let matches=content.windows.filter{$0.owningApplication?.processID==workspace.target?.pid && $0.windowLayer==0 && $0.frame.height>30}
        let candidates=matches.map {CaptureCandidate(id:$0.windowID,title:$0.title,frame:WindowFrame(x:$0.frame.minX,y:$0.frame.minY,width:$0.frame.width,height:$0.frame.height))}
        let id=try WindowMatcher.resolve(candidates,title:workspace.target?.title ?? "",frame:frame,previousID:workspace.target?.windowID)
        guard let window=matches.first(where:{$0.windowID==id}) else {throw AgentSpaceError("capture_window_not_found","Target window disappeared")}
        let config=SCStreamConfiguration();config.width=max(1,Int(window.frame.width));config.height=max(1,Int(window.frame.height));config.showsCursor=false
        let start=ContinuousClock.now
        let image=try await SCScreenshotManager.captureImage(contentFilter:SCContentFilter(desktopIndependentWindow:window),configuration:config)
        let elapsed=start.duration(to:.now)
        let ms=Double(elapsed.components.seconds)*1000+Double(elapsed.components.attoseconds)/1e15
        let path=try store.directory(workspace.name).appendingPathComponent("capture-\(UUID().uuidString).png")
        guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else {throw AgentSpaceError("png_encoding","Cannot encode screenshot")}
        try data.write(to:path,options:.atomic)
        workspace.target?.windowID=window.windowID
        try store.save(workspace)
        return .object(["path":.string(path.path),"latencyMs":.number(ms),"windowID":.number(Double(window.windowID)),"width":.number(Double(image.width)),"height":.number(Double(image.height))])
    }

    private func typeText(_ workspace:Workspace,options o:CommandOptions) async throws -> (String,JSONValue) {
        let text=try o.required("text")
        guard text.utf16.count<=100_000 else {throw AgentSpaceError("text_too_large","Text is limited to 100000 UTF-16 units")}
        let root=try AX.target(workspace)
        let selector=try o.selector()
        let addressed=o["ref"] != nil || !selector.isEmpty
        let e:AXUIElement?
        if addressed,o["ref"]==nil,workspace.apps.contains(where:{$0.pid==workspace.target?.pid && $0.bundleIdentifier=="com.apple.Safari"}) {
            e=try await AX.resolveWhenReady {try AX.resolve(root:AX.target(workspace),ref:nil,selector:selector)}
        } else {
            e=addressed ? try AX.resolve(root:root,ref:o["ref"],selector:selector):nil
        }
        if o.has("replace") {
            guard let e else {throw AgentSpaceError("element_required","--replace requires an addressed text element")}
            let status=AX.set(e,kAXValueAttribute,text as CFString)
            try await Task.sleep(for:.milliseconds(180))
            guard status == .success,AX.string(e,kAXValueAttribute)==text else {throw AgentSpaceError("verification_failed","AXValue replacement did not produce the requested text; no keyboard fallback attempted")}
            return ("AXValue.replace",.object(["verified":.bool(true),"value":.string(String(text.prefix(1000)))]))
        }
        if text.isEmpty {return ("no_op",.object(["verified":.bool(true),"characters":.number(0)]))}
        let old=e.flatMap{AX.string($0,kAXValueAttribute)}
        var selectedExpected:String?
        if let e,let old,let raw=AX.value(e,kAXSelectedTextRangeAttribute),CFGetTypeID(raw)==AXValueGetTypeID() {
            var range=CFRange()
            if AXValueGetValue(unsafeDowncast(raw,to:AXValue.self),.cfRange,&range) {
                selectedExpected=TextVerification.insertion(original:old,text:text,location:range.location,length:range.length)
            }
        }
        var attempts:[JSONValue]=[]
        if let e {
            if workspace.apps.contains(where:{$0.pid==workspace.target?.pid && ["safari","browser"].contains($0.kind)}),let old {
                var range=CFRange(location:old.utf16.count,length:0)
                if let value=AXValueCreate(.cfRange,&range) {
                    let status=AX.set(e,kAXSelectedTextRangeAttribute,value)
                    attempts.append(.object(["method":.string("AXSelectedTextRange"),"axError":.number(Double(status.rawValue))]))
                    if status == .success {selectedExpected=old+text}
                }
            }
            for method in [kAXSelectedTextAttribute,kAXValueAttribute] {
                let desired=method==kAXValueAttribute ? (old ?? "")+text:text
                let error=AX.set(e,method,desired as CFString)
                try await Task.sleep(for:.milliseconds(180))
                let current=AX.string(e,kAXValueAttribute)
                let verified:Bool
                if method==kAXValueAttribute {verified=current==desired}
                else {verified=selectedExpected != nil && current==selectedExpected}
                attempts.append(.object(["method":.string(method),"axError":.number(Double(error.rawValue)),"verified":.bool(verified)]))
                if verified || (error == .success && old==nil && current==nil) {
                    return (method,.object(["verified":.bool(verified),"value":current.map{.string(String($0.prefix(1000)))} ?? .null,"attempts":.array(attempts)]))
                }
                if current != old {
                    if error == .success && selectedExpected==nil {
                        return (method,.object(["verified":.bool(false),"value":current.map{.string(String($0.prefix(1000)))} ?? .null,"attempts":.array(attempts),"note":.string("Value changed but insertion range was unavailable; no duplicate fallback attempted")]))
                    }
                    throw AgentSpaceError("verification_failed","AX changed the value unexpectedly; stopped to avoid duplicate insertion")
                }
            }
        }
        // Element focus changes are deliberately excluded: this path never requests global or window focus.
        try await TargetedKeyboard.text(text,pid:workspace.target!.pid)
        try await Task.sleep(for:.milliseconds(200))
        let current=e.flatMap{AX.string($0,kAXValueAttribute)}
        let verified=selectedExpected != nil && current==selectedExpected
        attempts.append(.object(["method":.string("postToPid"),"verified":.bool(verified)]))
        return ("postToPid",.object(["dispatched":.bool(true),"verified":.bool(verified),"value":current.map{.string(String($0.prefix(1000)))} ?? .null,"attempts":.array(attempts)]))
    }

    private func scroll(_ workspace:Workspace,options o:CommandOptions) async throws -> (String,JSONValue) {
        let direction=o["direction"] ?? "down"
        guard ["up","down","left","right"].contains(direction) else {throw AgentSpaceError("invalid_direction","Direction must be up, down, left or right")}
        let amount=Double(o["amount"] ?? "0.8")
        guard let amount,amount.isFinite,amount>0,amount<=100 else {throw AgentSpaceError("invalid_amount","Amount must be positive and at most 100")}
        let unit=o["unit"] ?? "fraction"
        guard ["fraction","pages"].contains(unit) else {throw AgentSpaceError("invalid_unit","Unit must be fraction or pages")}
        let root=try AX.target(workspace)
        let selector=try o.selector()
        let area=(o["ref"] != nil || !selector.isEmpty) ? try AX.resolve(root:root,ref:o["ref"],selector:selector):root
        let (tree,_)=AX.tree(area)
        let horizontal=direction=="left" || direction=="right"
        let sign=(direction=="up" || direction=="left") ? -1.0:1.0
        for node in tree.flattened where node.role=="AXScrollBar" {
            let bar=try AX.resolve(node.ref,root:area)
            let orientation=AX.string(bar,kAXOrientationAttribute)
            guard horizontal ? orientation==kAXHorizontalOrientationValue:orientation==kAXVerticalOrientationValue else {continue}
            guard let number=AX.value(bar,kAXValueAttribute) as? NSNumber else {continue}
            let old=number.doubleValue
            var delta=amount
            if unit=="pages" {
                let viewport=AX.frame(root)
                let content=tree.flattened.first{$0.role=="AXWebArea"}?.frame
                let visible=horizontal ? viewport?.width:viewport?.height
                let total=horizontal ? content?.width:content?.height
                let ratio=(visible != nil && total != nil && total!>visible!) ? visible!/(total!-visible!):0.1
                delta=amount*max(0.01,min(1,ratio))
            }
            let desired=max(0,min(1,old+sign*delta))
            let error=AX.set(bar,kAXValueAttribute,desired as CFNumber)
            try await Task.sleep(for:.milliseconds(220))
            let current=(AX.value(bar,kAXValueAttribute) as? NSNumber)?.doubleValue
            if error == .success,let current,abs(current-desired)<0.02 {
                return ("AXScrollBar.AXValue",.object(["verified":.bool(true),"before":.number(old),"after":.number(current),"atBoundary":.bool(old==desired),"pageAmountApproximate":.bool(unit=="pages")]))
            }
        }
        let candidates=tree.flattened.filter{$0.ref != "0" && $0.actions.contains("AXScrollToVisible")}
        if let node=(sign>0 ? candidates.last:candidates.first) {
            let e=try AX.resolve(node.ref,root:area)
            if AX.perform(e,"AXScrollToVisible") == .success {
                return ("AXScrollToVisible",.object(["verified":.bool(false),"descendant":.string(node.ref),"note":.string("Moved to directional edge descendant; amount not representable by this fallback")]))
            }
        }
        let action=["up":"AXScrollUpByPage","down":"AXScrollDownByPage","left":"AXScrollLeftByPage","right":"AXScrollRightByPage"][direction]!
        if AX.actions(area).contains(action) {
            for _ in 0..<max(1,Int(ceil(amount))) {
                guard AX.perform(area,action) == .success else {throw AgentSpaceError("scroll_failed","Page action failed")}
            }
            return (action,.object(["verified":.bool(false)]))
        }
        throw AgentSpaceError("unsupported","No working AX scrollbar, descendant scroll-to-visible or page action; background wheel injection is intentionally unavailable")
    }

    /// Launch routes through one decision point: the backend and interaction mode are resolved
    /// and persisted before any effect, then dispatch happens on the resolved route only.
    private func launchApp(_ workspace:inout Workspace,options o:CommandOptions) async throws -> (String,JSONValue) {
        if o["chrome-session"] != nil { _ = try ChromeSession.validateLaunch(o) }
        let decision=try pinRouting(&workspace,options:o)
        let (method,result):(String,JSONValue)
        switch BackendKind(rawValue:decision.resolvedBackend) {
        case .virtualDisplay:
            (method,result)=try await VirtualDisplay.launch(&workspace,options:o,store:store)
        case .cdp:
            if o["chrome-session"] != nil {
                (method,result)=try await ChromeSession.launch(&workspace,options:o,store:store)
            } else {
                (method,result)=try await CDPBrowser.launch(&workspace,options:o,store:store)
            }
        case .ax, nil:
            guard AXIsProcessTrusted() else {throw AgentSpaceError("accessibility_permission","Accessibility permission is required; grant it to the host process in System Settings")}
            (method,result)=try await launch(&workspace,options:o)
        }
        guard case .object(var fields)=result else {return (method,result)}
        fields["routing"]=try .encoded(decision)
        return (method,.object(fields))
    }

    /// A workspace's route is pinned at first launch and never migrates. Requests that disagree
    /// with the pin are usage errors; legacy workspaces (no recorded backend) keep whatever
    /// their live apps imply. Requested values are validated before they are compared to the pin
    /// so `--backend bogus` is an invalid-option error even on a pinned workspace.
    private func pinRouting(_ workspace:inout Workspace,options o:CommandOptions) throws -> RoutingDecision {
        // Only flags given on THIS launch are compared against the pin - the create-time
        // request is the resolution default, not a standing veto. Otherwise
        // `create --backend ax` + `launch --backend virtual-display` would pin virtual-display
        // yet a later flagless launch would still see 'ax' and throw backend_locked.
        let explicit=try BackendRouter.request(backend:o["backend"],interaction:o["interaction"])
        if let pinned=workspace.backend {
            guard BackendKind(rawValue:pinned) != nil else {throw AgentSpaceError("state_invalid","workspace.json records unknown backend '\(pinned)'")}
            if let raw=explicit.backend,raw != "auto",raw != pinned {
                throw AgentSpaceError("backend_locked","Workspace backend is '\(pinned)' (pinned at launch); --backend \(raw) requires a new workspace — a live workspace is never migrated to another backend")
            }
            if let raw=explicit.interaction,raw != (workspace.interaction ?? "semantic") {
                throw AgentSpaceError("interaction_locked","Workspace interaction is '\(workspace.interaction ?? "semantic")'; --interaction \(raw) requires a new workspace")
            }
            return workspace.routing ?? RoutingDecision(requestedBackend:workspace.requestedBackend ?? pinned,
                requestedInteraction:workspace.requestedInteraction ?? workspace.interaction ?? "semantic",
                resolvedBackend:pinned,resolvedInteraction:workspace.interaction ?? "semantic",reason:"pinned at first launch")
        }
        if !workspace.apps.isEmpty || CDPBrowser.active(workspace) {
            let inferred:BackendKind=CDPBrowser.active(workspace) ? .cdp:.ax
            let decision=RoutingDecision(requestedBackend:workspace.requestedBackend ?? "auto",
                requestedInteraction:workspace.requestedInteraction ?? "semantic",resolvedBackend:inferred.rawValue,
                resolvedInteraction:"semantic",reason:"inferred from live apps launched before backend routing existed")
            workspace.backend=inferred.rawValue;workspace.interaction="semantic";workspace.routing=decision
            try store.save(workspace)
            return decision
        }
        let app=try o.required("app").lowercased()
        // Unpinned: the create-time request is the default this launch's explicit flags override.
        let request=try BackendRouter.request(backend:o["backend"] ?? workspace.requestedBackend,
                                              interaction:o["interaction"] ?? workspace.requestedInteraction)
        let decision=try BackendRouter.resolve(request:request,app:app)
        // Preflight before pinning: a resolution that cannot run (no display host, no Chrome,
        // no AX grant) fails here while the workspace still has no route, instead of leaving a
        // permanent pin the workspace can never satisfy.
        try preflight(decision:decision)
        workspace.backend=decision.resolvedBackend
        workspace.interaction=decision.resolvedInteraction
        workspace.routing=decision
        try store.save(workspace)
        return decision
    }

    /// Contract-level prerequisites for a resolved route. These say nothing about runtime
    /// session state - only whether the backend can be used at all on this host.
    private func preflight(decision:RoutingDecision) throws {
        switch decision.resolvedBackend {
        case "virtual-display":
            guard DisplayHost.locate() != nil else {
                throw AgentSpaceError("virtual_display_unavailable",
                    "The visual route needs AgentSpace's own display host (agentspace-display-host), "
                    + "built next to the agentspace binary by `swift build`; nothing external is "
                    + "installed or required — or launch with --backend ax/cdp instead")
            }
            guard SelfTest.virtualDisplayAPIAvailable() else {
                throw AgentSpaceError("virtual_display_api_unavailable",
                    "The CGVirtualDisplay APIs are not usable on this macOS: \(SelfTest.virtualDisplayAPIStatus())")
            }
            guard AXIsProcessTrusted() else {
                throw AgentSpaceError("accessibility_permission",
                    "Accessibility permission is required for the virtual-display backend "
                    + "(window placement and observation); grant it to the host process")
            }
        case "cdp":
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") != nil else {
                throw AgentSpaceError("app_unavailable","cdp routes through Google Chrome, which is not installed; launch with --backend ax or virtual-display")
            }
        default:
            guard AXIsProcessTrusted() else {
                throw AgentSpaceError("accessibility_permission","Accessibility permission is required for the ax backend; grant it to the host process in System Settings")
            }
        }
    }

    /// Whether the pinned route can run right now - the distinction capabilities cannot draw.
    /// "Supported" (route can deliver coordinates at all) is reported separately from "ready
    /// right now", which is built only from evidence the get-status probe already collected:
    /// the display-host binary exists, the helper process is alive under the recorded
    /// pid+start identity, its socket answered, and it still holds the recorded display.
    /// A dead or unreachable host reports false/unknown - never persisted-true.
    private func backendReadiness(backend:BackendKind,workspace:Workspace,sessionStatus:JSONValue? = nil) -> JSONValue {
        switch backend {
        case .virtualDisplay:
            let supported=workspace.interactionMode == .visual
            let status=sessionStatus ?? .null
            guard let state=workspace.virtualDisplay else {
                return .object(["coordinateSupported":.bool(supported),"host":.bool(false),
                    "session":.bool(false),"pendingCreate":.bool(false),"coordinateReady":.bool(false),
                    "coordinateReasons":.array([.string("no virtual-display session on this workspace")]),
                    "sessionEvidence":.object(["reachable":field(status,"reachable"),"present":field(status,"present")])])
            }
            guard state.backend == .native else {
                return .object(["coordinateSupported":.bool(false),"host":.bool(false),
                    "session":.bool(false),"pendingCreate":.bool(false),"coordinateReady":.bool(false),
                    "coordinateReasons":.array([.string("legacy external-backend record; create a new workspace — it will never be acted on")]),
                    "sessionEvidence":.object(["kind":.string("legacy")])])
            }
            var evidence:[String:JSONValue]=["reachable":field(status,"reachable"),"present":field(status,"present")]
            let hostBinary = DisplayHost.locate() != nil
            let hostAlive = DisplayHost.alive(state.hostPID ?? -1, start: state.hostStart)
            evidence["hostAlive"] = .bool(hostAlive)
            var ready:JSONValue = .bool(false)
            var reasons:[JSONValue]=[]
            if !hostBinary {reasons.append(.string("agentspace-display-host not found next to agentspace"))}
            if state.pendingCreate {reasons.append(.string("host handshake was never confirmed"))}
            if !hostAlive {reasons.append(.string("display host process is dead or its pid was reused"))}
            if reasons.isEmpty {
                if field(status,"reachable") != .bool(true) {
                    ready = .null
                    reasons.append(.string("host socket unreachable; readiness unknown"))
                } else if field(status,"synthetic") == .bool(true) {
                    reasons.append(.string("the host reports a synthetic test display; it is never a usable seat"))
                } else if field(status,"present") != .bool(true) {
                    reasons.append(.string("host answers but holds no display"))
                } else {
                    ready = .bool(true)
                }
            }
            return .object(["coordinateSupported":.bool(supported),"host":.bool(hostBinary),
                "session":.bool(true),"pendingCreate":.bool(state.pendingCreate),
                "coordinateReady":ready,"coordinateReasons":.array(reasons),
                "sessionEvidence":.object(evidence)])
        case .cdp:
            return .object(["chrome":.bool(NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.google.Chrome") != nil),
                            "active":.bool(CDPBrowser.active(workspace))])
        case .ax:
            return .object(["accessibility":.bool(AXIsProcessTrusted())])
        }
    }

    /// Coordinate input is only ever delivered through a visual-mode virtual-display workspace.
    /// Anything else fails before an effect with an explicit remedy; no silent fallback.
    private func requireVisualRouting(_ workspace:Workspace,command:String) throws {
        guard workspace.backendKind == .virtualDisplay,workspace.interactionMode == .visual else {
            throw AgentSpaceError("interaction_required",
                "'\(command)' needs coordinate input, which this workspace does not deliver: it is pinned to "
                + "\(workspace.backend ?? "ax")/\(workspace.interaction ?? "semantic"). "
                + "Create a new workspace and launch with --backend virtual-display --interaction visual; "
                + "a live workspace is never switched to another input route")
        }
    }

    /// Ordered workspace teardown: owned apps, then the display session, then
    /// local state. The order is the safety property - destroying the display
    /// while owned apps still run would migrate their live windows onto the
    /// user's real displays before the quit landed. Each stage runs only when
    /// the previous one succeeded, so a failure keeps everything downstream
    /// untouched for an honest retry: app leftovers keep the session+state,
    /// and a session failure still leaves the local record unstopped.
    /// Injectable so the regression suite proves the order without a GUI.
    public static func stopSequence(
        terminateApps: () async throws -> [String: JSONValue],
        destroySession: () async throws -> [String: JSONValue]?,
        cleanupLocal: () async throws -> [String: JSONValue]
    ) async throws -> (String, JSONValue) {
        var method = "terminate-apps"
        var result = try await terminateApps()
        if let session = try await destroySession() {
            method += "+session-destroy"
            for (key, value) in session { result[key] = value }
        }
        method += "+cleanup-local"
        for (key, value) in try await cleanupLocal() { result[key] = value }
        return (method, .object(result))
    }

    static func waitForExit(attempts: Int, interval: Duration = .milliseconds(100), alive: () -> Bool) async throws -> Bool {
        for _ in 0..<attempts {
            if !alive() { return true }
            try await Task.sleep(for: interval)
        }
        return !alive()
    }

    private func stop(_ workspace:inout Workspace,options o:CommandOptions) async throws -> (String,JSONValue) {
        if o.has("abandon-session") {
            // Explicit LOCAL-ONLY escape: nothing is signalled and nothing is
            // deleted. The session record moves to abandonedVirtualDisplay as
            // recovery evidence, owned apps keep running with their
            // temp/profile/document files in place, and the workspace is
            // marked stopped with cleanup honestly unconfirmed - a plain
            // stop-workspace remains the retryable default teardown.
            var session:JSONValue = .object(["sessionDestroyed":.null,"reason":.string("no session record")])
            if workspace.virtualDisplay != nil {
                session=try VirtualDisplay.abandon(&workspace,store:store)
            }
            var chromeSession:JSONValue = .null
            if workspace.chromeSession != nil {
                chromeSession = ChromeSession.abandon(&workspace)
            }
            workspace.stopped=true;workspace.target=nil
            try store.save(workspace)
            return ("abandon.local-only",.object(["sessionDestroyed":.null,"cleanupUnconfirmed":.bool(true),
                "appsTerminated":.bool(false),
                "appPIDsNotTerminated":try .encoded(workspace.apps.map(\.pid)),
                "temporaryDirectoryRetained":.string(workspace.temporaryDirectory),
                "session":session,"chromeSession":chromeSession]))
        }
        return try await Self.stopSequence(
            terminateApps: {
                // Owned apps quit FIRST, while the display is still alive -
                // their windows die on it instead of migrating onto the
                // user's displays. Unowned (adopted) apps are never signalled.
                let owned=workspace.apps.filter(\.owned)
                var browserCloseAcknowledged = false
                var browserCloseError: String?
                if CDPBrowser.active(workspace) {
                    do {
                        try await CDPBrowser.closeBrowser(workspace)
                        browserCloseAcknowledged = true
                    } catch { browserCloseError = String(describing: error) }
                }
                var requested:[Int32]=[]
                for record in owned where AX.isAlive(record) {
                    if NSRunningApplication(processIdentifier:record.pid)?.terminate()==true {requested.append(record.pid)}
                }
                _ = try await Self.waitForExit(attempts: 20) { owned.contains(where: AX.isAlive) }
                var forced:[Int32]=[]
                for record in owned where AX.isAlive(record) {
                    if NSRunningApplication(processIdentifier:record.pid)?.forceTerminate()==true {forced.append(record.pid)}
                }
                _ = try await Self.waitForExit(attempts: 50) { owned.contains(where: AX.isAlive) }
                let leftovers=owned.filter{AX.isAlive($0)}.map(\.pid)
                guard leftovers.isEmpty else {
                    throw AgentSpaceError("processes_remaining",
                        "Owned processes still alive: \(leftovers); the display host and "
                        + "session state are kept so stop-workspace can retry")
                }
                return ["terminated":try .encoded(requested),"forced":try .encoded(forced),
                        "browserCloseAcknowledged":.bool(browserCloseAcknowledged),
                        "browserCloseError":browserCloseError.map(JSONValue.string) ?? .null,
                        "leftoverPIDs":try .encoded(leftovers),
                        "unownedPIDsNotTerminated":try .encoded(workspace.apps.filter{!$0.owned}.map(\.pid))]
            },
            destroySession: {
                var out:[String:JSONValue]=[:]
                if workspace.virtualDisplay != nil {
                    let session=try await VirtualDisplay.destroy(&workspace,store:self.store)
                    try self.store.save(workspace)
                    out["session"]=session
                }
                if workspace.chromeSession != nil {
                    let session=try await ChromeSession.closeSession(&workspace,store:self.store)
                    try self.store.save(workspace)
                    out["chromeSession"]=session
                }
                return out.isEmpty ? nil : out
            },
            cleanupLocal: {
                let temp=URL(fileURLWithPath:workspace.temporaryDirectory,isDirectory:true).standardizedFileURL
                guard temp.lastPathComponent.hasPrefix("AgentSpace-"),temp.deletingLastPathComponent().resolvingSymlinksInPath()==FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw AgentSpaceError("unsafe_temp_directory","Refusing to delete a directory outside the disposable workspace temp root")
                }
                if FileManager.default.fileExists(atPath:temp.path) {try FileManager.default.removeItem(at:temp)}
                workspace.stopped=true;workspace.target=nil;try self.store.save(workspace)
                return ["temporaryDirectoryDeleted":.bool(!FileManager.default.fileExists(atPath:temp.path))]
            })
    }
}
