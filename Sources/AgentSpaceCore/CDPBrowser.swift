import AppKit
import Foundation

@MainActor
final class CDPBrowser {
    private let socket: URLSessionWebSocketTask
    private var serial = 0
    private var session: String?

    private init(endpoint: URL) {
        socket = URLSession.shared.webSocketTask(with: endpoint)
        socket.maximumMessageSize = 32 * 1024 * 1024
        socket.resume()
    }

    private static func file(_ workspace: Workspace) -> URL {
        URL(fileURLWithPath: workspace.temporaryDirectory).appendingPathComponent("cdp-endpoint.json")
    }

    static func active(_ workspace: Workspace) -> Bool {
        FileManager.default.fileExists(atPath: file(workspace).path)
    }

    private func request(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        serial += 1
        var message: [String: JSONValue] = ["id": .number(Double(serial)), "method": .string(method), "params": .object(params)]
        if let session { message["sessionId"] = .string(session) }
        let identifier = serial
        let deadline = Task { [socket] in
            do { try await Task.sleep(for: .seconds(15)); socket.cancel(with: .goingAway, reason: nil) } catch {}
        }
        defer { deadline.cancel() }
        try await socket.send(.string(String(decoding: JSONEncoder().encode(JSONValue.object(message)), as: UTF8.self)))
        while true {
            let data: Data
            switch try await socket.receive() {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: throw AgentSpaceError("cdp_protocol", "Unknown WebSocket frame")
            }
            let reply = try JSONDecoder().decode(JSONValue.self, from: data)
            if number(reply, "id") == Double(identifier) {
                if field(reply, "error") != .null { throw AgentSpaceError("cdp_error", String(describing: field(reply, "error"))) }
                return field(reply, "result")
            }
        }
    }

    private static func connect(_ workspace: Workspace, attachPage: Bool = true) async throws -> CDPBrowser {
        let saved = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file(workspace)))
        guard let endpoint = URL(string: string(saved, "endpoint")), endpoint.scheme == "ws", endpoint.host == "127.0.0.1",
              let pid = number(saved, "pid"), workspace.apps.contains(where: { Double($0.pid) == pid && $0.owned && AX.isAlive($0) }) else {
            throw AgentSpaceError("cdp_unavailable", "Owned headless Chrome is no longer available")
        }
        let client = CDPBrowser(endpoint: endpoint)
        do {
            if !attachPage { return client }
            let targets = try await client.request("Target.getTargets")
            let pages = array(targets, "targetInfos").filter { string($0, "type") == "page" }
            guard pages.count == 1, let page = pages.first else {
                throw AgentSpaceError("cdp_unavailable", "Expected exactly one owned page target")
            }
            let attached = try await client.request("Target.attachToTarget", ["targetId": field(page, "targetId"), "flatten": .bool(true)])
            client.session = string(attached, "sessionId")
            return client
        } catch { client.socket.cancel(with: .goingAway, reason: nil); throw error }
    }

    nonisolated static func debugEndpoint(_ contents: String) -> URL? {
        let lines = contents.split(separator: "\n")
        guard lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port),
              lines[1].hasPrefix("/devtools/browser/"),
              lines[1].dropFirst("/devtools/browser/".count).allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              lines[1].count > "/devtools/browser/".count else { return nil }
        return URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
    }

    static func closeBrowser(_ workspace: Workspace) async throws {
        let client = try await connect(workspace, attachPage: false)
        defer { client.socket.cancel(with: .goingAway, reason: nil) }
        _ = try await client.request("Browser.close")
    }

    static func openWindow(_ workspace: Workspace, profile: URL, url: URL) async throws {
        var endpoint: URL?
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: profile.appendingPathComponent("DevToolsActivePort"), encoding: .utf8) {
                endpoint = debugEndpoint(contents)
            }
            if endpoint != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let endpoint, let record = workspace.apps.last,
              record.bundleIdentifier == "com.google.Chrome", record.owned, AX.isAlive(record) else {
            throw AgentSpaceError("cdp_launch_failed", "Owned Chrome did not publish its loopback endpoint")
        }
        try JSONEncoder().encode(JSONValue.object(["endpoint": .string(endpoint.absoluteString), "pid": .number(Double(record.pid))]))
            .write(to: file(workspace), options: .atomic)
        let client = try await connect(workspace, attachPage: false)
        defer { client.socket.cancel(with: .goingAway, reason: nil) }
        _ = try await client.request("Target.createTarget", ["url": .string(url.absoluteString), "newWindow": .bool(true), "background": .bool(true)])
        let page = try await connect(workspace)
        defer { page.socket.cancel(with: .goingAway, reason: nil) }
        for _ in 0..<100 {
            if try await page.evaluate("document.readyState === 'complete' && location.href !== 'about:blank'") == .bool(true) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AgentSpaceError("navigation_timeout", "Chrome background window did not finish loading")
    }

    nonisolated static func viewportPoint(_ point: CGPoint, viewport: WindowFrame, width: Double, height: Double) throws -> CGPoint {
        guard point.x.isFinite, point.y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0, viewport.width > 0, viewport.height > 0,
              point.x >= viewport.x, point.y >= viewport.y,
              point.x < viewport.x + viewport.width, point.y < viewport.y + viewport.height else {
            throw AgentSpaceError("point_outside_viewport", "Chrome visual coordinates must be inside the page, not browser chrome")
        }
        return CGPoint(x: (point.x-viewport.x)*width/viewport.width, y: (point.y-viewport.y)*height/viewport.height)
    }

    nonisolated static func keyParameters(_ raw: String) throws -> [String: JSONValue] {
        guard let entry = ["return": ("Enter", 13), "enter": ("Enter", 13), "tab": ("Tab", 9),
                           "backspace": ("Backspace", 8), "escape": ("Escape", 27)][raw.lowercased()] else {
            throw AgentSpaceError("unsupported", "Chrome visual key supports return, tab, backspace and escape")
        }
        return ["key": .string(entry.0), "code": .string(entry.0), "windowsVirtualKeyCode": .number(Double(entry.1))]
    }

    static func visual(_ command: String, workspace: Workspace, options: CommandOptions, viewport: WindowFrame) async throws -> (String, JSONValue) {
        let client = try await connect(workspace)
        defer { client.socket.cancel(with: .goingAway, reason: nil) }
        let size = try await client.evaluate("({width:innerWidth,height:innerHeight})")
        func point(_ raw: (x: Double, y: Double)) throws -> CGPoint {
            try viewportPoint(CGPoint(x: raw.x, y: raw.y), viewport: viewport, width: number(size, "width") ?? 0, height: number(size, "height") ?? 0)
        }
        let names = try options.modifierList()
        guard !names.contains("fn") else { throw AgentSpaceError("unsupported", "CDP input cannot represent fn") }
        let modifiers = names.reduce(0) { value, modifier in
            value | (["alt": 1, "option": 1, "opt": 1, "ctrl": 2, "control": 2, "cmd": 4, "command": 4, "shift": 8][modifier] ?? 0)
        }
        func mouse(_ type: String, _ p: CGPoint, button: String = "none", buttons: Int = 0, count: Int = 0) async throws {
            _ = try await client.request("Input.dispatchMouseEvent", ["type": .string(type), "x": .number(p.x), "y": .number(p.y),
                "button": .string(button), "buttons": .number(Double(buttons)), "clickCount": .number(Double(count)), "modifiers": .number(Double(modifiers))])
        }
        switch command {
        case "click", "move", "drag":
            let from = try point(options.point()!)
            let button = try options.button() ?? "left"
            let mask = button == "right" ? 2 : button == "middle" ? 4 : 1
            let destination = command == "drag" ? try point(options.point("to-x", "to-y")!) : from
            try await mouse("mouseMoved", from)
            if command != "move" {
                let count = try options.clickCount() ?? 1
                for click in 1...count {
                    try await mouse("mousePressed", from, button: button, buttons: mask, count: click)
                    if command == "drag" {
                        for step in 1...12 {
                            let t = Double(step)/12
                            try await mouse("mouseMoved", CGPoint(x: from.x+(destination.x-from.x)*t, y: from.y+(destination.y-from.y)*t), button: button, buttons: mask)
                        }
                    }
                    try await mouse("mouseReleased", destination, button: button, count: click)
                }
            }
        case "scroll":
            let p = try point(options.point() ?? (x: viewport.x+viewport.width/2, y: viewport.y+viewport.height/2))
            let delta = try VirtualDisplay.scrollDelta(options)
            for _ in 0..<(delta.2 ?? 1) {
                _ = try await client.request("Input.dispatchMouseEvent", ["type": .string("mouseWheel"), "x": .number(p.x), "y": .number(p.y),
                    "deltaX": .number(-Double(delta.0 ?? 0)), "deltaY": .number(-Double(delta.1 ?? 0)), "modifiers": .number(Double(modifiers))])
            }
        case "type-text":
            guard !options.has("replace") else { throw AgentSpaceError("element_required", "--replace requires an addressed text field") }
            let before = try await client.evaluate("(()=>{const e=document.activeElement;return e&&(e.tagName==='INPUT'||e.tagName==='TEXTAREA')?{value:e.value,start:e.selectionStart,end:e.selectionEnd}:null})()")
            let text = try options.required("text")
            guard case .string(let old) = field(before, "value"), let start = number(before, "start"), let end = number(before, "end"),
                  let expected = TextVerification.insertion(original: old, text: text, location: Int(start), length: Int(end-start)) else {
                throw AgentSpaceError("element_not_writable", "Click a page text field before unaddressed typing")
            }
            _ = try await client.request("Input.insertText", ["text": .string(text)])
            let after = try await client.evaluate("document.activeElement.value")
            guard after == .string(expected) else { throw AgentSpaceError("verification_failed", "Chrome focused-field readback did not match") }
            return ("CDP.Input.insertText", .object(["verified": .bool(true), "value": after, "inputRoute": .string("cdp-input")]))
        case "key":
            var params = try keyParameters(options.required("key"))
            params["modifiers"] = .number(Double(modifiers))
            for type in ["keyDown", "keyUp"] {
                params["type"] = .string(type)
                _ = try await client.request("Input.dispatchKeyEvent", params)
            }
        default: throw AgentSpaceError("unsupported", "Unsupported Chrome visual command")
        }
        return ("CDP.Input.\(command)", .object(["dispatched": .bool(true), "verified": .bool(false), "inputRoute": .string("cdp-input")]))
    }

    static func launch(_ workspace: inout Workspace, options: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        guard !active(workspace) else { throw AgentSpaceError("backend_in_use", "Stop the existing CDP workspace before launching another page") }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"),
              let executable = Bundle(url: appURL)?.executableURL else { throw AgentSpaceError("app_unavailable", "Google Chrome is required") }
        let raw = try (options["file"] ?? options.required("url"))
        let url = options["file"] != nil ? URL(fileURLWithPath: raw) : URL(string: raw)
        guard var url, ["file", "http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw AgentSpaceError("invalid_url", "Expected file, http or https URL") }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { throw AgentSpaceError("file_not_found", "Local page does not exist") }
        if url.isFileURL {
            let copy = URL(fileURLWithPath: workspace.temporaryDirectory).appendingPathComponent("Page-\(UUID().uuidString).html")
            try FileManager.default.copyItem(at: url, to: copy); url = copy
        }
        let profile = URL(fileURLWithPath: workspace.temporaryDirectory).appendingPathComponent("ChromeProfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--headless=new", "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
                             "--user-data-dir=\(profile.path)", "--no-first-run", "--no-default-browser-check", "--window-size=1280,900", "about:blank"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        var persisted = false
        defer { if !persisted && process.isRunning { process.terminate() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var endpoint: URL?
        repeat {
            if let contents = try? String(contentsOf: profile.appendingPathComponent("DevToolsActivePort"), encoding: .utf8) {
                let lines = contents.split(separator: "\n")
                if lines.count == 2, let port = Int(lines[0]), (1...65535).contains(port), lines[1].hasPrefix("/devtools/browser/") {
                    endpoint = URL(string: "ws://127.0.0.1:\(port)\(lines[1])")
                }
            }
            if endpoint != nil, NSRunningApplication(processIdentifier: process.processIdentifier) != nil { break }
            guard process.isRunning else { throw AgentSpaceError("cdp_launch_failed", "Headless Chrome exited during startup") }
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        guard let endpoint, let app = NSRunningApplication(processIdentifier: process.processIdentifier), app.bundleIdentifier == "com.google.Chrome" else {
            throw AgentSpaceError("cdp_launch_failed", "Headless Chrome did not publish its loopback endpoint and process identity")
        }
        let record = AppRecord(pid: process.processIdentifier, bundleIdentifier: "com.google.Chrome", launchDate: app.launchDate, owned: true, kind: "chrome")
        workspace.apps.append(record); workspace.target = nil
        try store.save(workspace)
        let state: JSONValue = .object(["endpoint": .string(endpoint.absoluteString), "pid": .number(Double(record.pid))])
        try JSONEncoder().encode(state).write(to: file(workspace), options: .atomic)
        persisted = true
        let client = try await connect(workspace)
        defer { client.socket.cancel(with: .goingAway, reason: nil) }
        let navigation = try await client.request("Page.navigate", ["url": .string(url.absoluteString)])
        guard field(navigation, "errorText") == .null else { throw AgentSpaceError("navigation_failed", string(navigation, "errorText")) }
        var loaded = false
        for _ in 0..<100 {
            let state = try await client.evaluate("document.readyState === 'complete' && location.href !== 'about:blank'")
            if state == .bool(true) { loaded = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard loaded else { throw AgentSpaceError("navigation_timeout", "Page did not finish loading") }
        return ("CDP.headless", .object(["backend": .string("cdp"), "headless": .bool(true), "app": try .encoded(record),
                                         "openedURL": .string(url.absoluteString), "targetReady": .bool(true)]))
    }

    private func evaluate(_ expression: String) async throws -> JSONValue {
        let reply = try await request("Runtime.evaluate", ["expression": .string(expression), "returnByValue": .bool(true), "awaitPromise": .bool(true)])
        guard field(reply, "exceptionDetails") == .null else { throw AgentSpaceError("cdp_script", "Page evaluation failed") }
        return field(field(reply, "result"), "value")
    }

    nonisolated static func tree(_ response: JSONValue, limit: Int) -> ElementNode {
        let roles = ["RootWebArea": "AXWebArea", "textbox": "AXTextField", "button": "AXButton", "checkbox": "AXCheckBox",
                     "link": "AXLink", "StaticText": "AXStaticText", "heading": "AXHeading", "combobox": "AXComboBox"]
        let children = array(response, "nodes").compactMap { item -> ElementNode? in
            guard field(item, "ignored") != .bool(true), var role = roles[string(field(item, "role"), "value")],
                  let id = number(item, "backendDOMNodeId") else { return nil }
            let properties = array(item, "properties")
            if role == "AXTextField", properties.contains(where: { string($0, "name") == "multiline" && field(field($0, "value"), "value") == .bool(true) }) { role = "AXTextArea" }
            var value = string(field(item, "value"), "value")
            if role == "AXStaticText" { value = string(field(item, "name"), "value") }
            if role == "AXCheckBox" {
                let checked = properties.first { string($0, "name") == "checked" }
                value = checked.map { string(field($0, "value"), "value") == "true" ? "1" : "0" } ?? "0"
            }
            let title = string(field(item, "name"), "value")
            return ElementNode(ref: "0.\(Int(id))", role: role, title: title, label: title, value: value, actions: [], children: [])
        }
        return ElementNode(ref: "0", role: "AXApplication", children: Array(children.prefix(limit)))
    }

    private func snapshot(_ limit: Int = 1000) async throws -> ElementNode {
        Self.tree(try await request("Accessibility.getFullAXTree"), limit: limit)
    }

    private func element(_ options: CommandOptions) async throws -> ElementNode {
        let tree = try await snapshot()
        if let ref = options["ref"] {
            guard let node = tree.flattened.first(where: { $0.ref == ref }), node.ref != "0" else { throw AgentSpaceError("element_not_found", "CDP ref no longer exists") }
            return node
        }
        return try options.selector().resolve(in: tree)
    }

    private func call(_ node: ElementNode, _ function: String, arguments: [JSONValue] = []) async throws -> JSONValue {
        guard let id = Int(node.ref.dropFirst(2)) else { throw AgentSpaceError("invalid_ref", "Expected a current CDP DOM reference") }
        let resolved = try await request("DOM.resolveNode", ["backendNodeId": .number(Double(id))])
        let reply = try await request("Runtime.callFunctionOn", ["objectId": field(field(resolved, "object"), "objectId"),
            "functionDeclaration": .string(function), "arguments": .array(arguments.map { .object(["value": $0]) }),
            "returnByValue": .bool(true), "awaitPromise": .bool(true)])
        guard field(reply, "exceptionDetails") == .null else { throw AgentSpaceError("cdp_script", "DOM operation failed") }
        return field(field(reply, "result"), "value")
    }

    static func perform(_ command: String, workspace: inout Workspace, options: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        let client = try await connect(workspace)
        defer { client.socket.cancel(with: .goingAway, reason: nil) }
        var result: [String: JSONValue] = [:]
        switch command {
        case "observe":
            let limit = try options.integer("max-nodes", default: 1000, range: 1...10000)
            let depth = try options.integer("depth", default: 16, range: 0...30)
            var tree = try await client.snapshot(limit)
            if depth == 0 { tree.children = [] }
            result["tree"] = try .encoded(tree)
            result["truncated"] = .bool(tree.children.count == limit)
            if options.has("screenshot") {
                let start = ContinuousClock.now
                let capture = try await client.request("Page.captureScreenshot", ["format": .string("png"), "captureBeyondViewport": .bool(false)])
                guard let data = Data(base64Encoded: string(capture, "data")), data.starts(with: [137,80,78,71,13,10,26,10]) else { throw AgentSpaceError("capture_failed", "CDP returned no PNG") }
                let path = try store.directory(workspace.name).appendingPathComponent("capture-\(UUID().uuidString).png")
                try data.write(to: path)
                let duration = start.duration(to: .now)
                result["screenshot"] = .object(["path": .string(path.path), "method": .string("Page.captureScreenshot"),
                    "latencyMs": .number(Double(duration.components.seconds)*1000 + Double(duration.components.attoseconds)/1e15)])
            }
        case "type-text":
            let node = try await client.element(options)
            guard ["AXTextField", "AXTextArea"].contains(node.role) else { throw AgentSpaceError("unsupported", "CDP typing requires a text field") }
            let text = try options.required("text")
            let before = try await client.call(node, "function(replace){this.focus();this.setSelectionRange(replace?0:this.value.length,this.value.length);return this.value}", arguments: [.bool(options.has("replace"))])
            let expected = (options.has("replace") ? "" : stringValue(before)) + text
            if text.isEmpty, options.has("replace") {
                for type in ["keyDown", "keyUp"] { _ = try await client.request("Input.dispatchKeyEvent", ["type": .string(type), "key": .string("Backspace"), "windowsVirtualKeyCode": .number(8)]) }
            } else { _ = try await client.request("Input.insertText", ["text": .string(text)]) }
            let actual = try await client.call(node, "function(){return this.value}")
            guard actual == .string(expected) else { throw AgentSpaceError("verification_failed", "CDP text readback did not match") }
            result = ["verified": .bool(true), "value": actual]
        case "click":
            let node = try await client.element(options)
            let point = try await client.call(node, "function(){this.scrollIntoView({block:'center'});const r=this.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}}")
            guard number(point, "x") != nil, number(point, "y") != nil else { throw AgentSpaceError("unsupported", "Element has no clickable box") }
            for type in ["mousePressed", "mouseReleased"] {
                _ = try await client.request("Input.dispatchMouseEvent", ["type": .string(type), "x": field(point, "x"), "y": field(point, "y"), "button": .string("left"), "clickCount": .number(1)])
            }
            let readback = try await client.snapshot()
            result = ["dispatched": .bool(true), "verified": .bool(false), "readback": try .encoded(readback)]
        case "scroll":
            let selector = try options.selector()
            if options["ref"] != nil || !selector.isEmpty {
                let node = try await client.element(options)
                guard node.role == "AXWebArea" else { throw AgentSpaceError("unsupported", "CDP scrolling currently targets the page scroll area") }
            }
            let direction = options["direction"] ?? "down"
            guard ["up", "down", "left", "right"].contains(direction) else { throw AgentSpaceError("invalid_option", "Unknown scroll direction") }
            let vertical = ["up", "down"].contains(direction)
            let end = ["down", "right"].contains(direction)
            guard let amount = Double(options["amount"] ?? "0.8"), amount.isFinite, amount > 0, amount <= 100 else { throw AgentSpaceError("invalid_amount", "Amount must be positive and at most 100") }
            let unit = options["unit"] ?? "fraction"
            guard ["fraction", "pages"].contains(unit) else { throw AgentSpaceError("invalid_unit", "Unit must be fraction or pages") }
            let axis = vertical ? "Top" : "Left", size = vertical ? "Height" : "Width"
            let expected = try await client.evaluate("(()=>{const e=document.scrollingElement;const max=e.scroll\(size)-e.client\(size);const p=Math.max(0,Math.min(max,e.scroll\(axis)+\(end ? "" : "-")\(amount)*\(unit == "fraction" ? "max" : "e.client" + size)));e.scrollTo({\(vertical ? "top" : "left"):p,behavior:'instant'});return p})()")
            try await Task.sleep(for: .milliseconds(100))
            let actual = try await client.evaluate(vertical ? "scrollY" : "scrollX")
            guard case .number(let wanted) = expected, case .number(let observed) = actual, abs(wanted-observed) <= 1 else { throw AgentSpaceError("verification_failed", "Scroll readback did not match requested position") }
            result = ["verified": .bool(true), "position": try await client.evaluate("({x:scrollX,y:scrollY})")]
        case "key":
            let key = try options.required("key").lowercased()
            guard ["return", "enter", "tab", "backspace"].contains(key) else { throw AgentSpaceError("unsupported", "CDP key supports return, enter, tab and backspace; use --replace for replacement") }
            let name = ["return": "Enter", "enter": "Enter", "tab": "Tab", "backspace": "Backspace"][key]!
            for type in ["keyDown", "keyUp"] { _ = try await client.request("Input.dispatchKeyEvent", ["type": .string(type), "key": .string(name)]) }
            result = ["dispatched": .bool(true), "verified": .bool(false)]
        default: throw AgentSpaceError("unsupported", "Command is not available for the headless page")
        }
        result["backend"] = .string("cdp")
        return ("CDP.\(command)", .object(result))
    }
}

private func stringValue(_ value: JSONValue) -> String { if case .string(let text) = value { return text }; if case .bool(let flag) = value { return String(flag) }; return "" }
private func string(_ value: JSONValue, _ key: String) -> String { stringValue(field(value, key)) }
private func number(_ value: JSONValue, _ key: String) -> Double? { if case .number(let number) = field(value, key) { return number }; return nil }
private func array(_ value: JSONValue, _ key: String) -> [JSONValue] { if case .array(let array) = field(value, key) { return array }; return [] }
