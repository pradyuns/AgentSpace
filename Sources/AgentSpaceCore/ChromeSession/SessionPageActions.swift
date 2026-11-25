import Foundation

extension SessionCore {
    func evaluate(_ cdpSession: String, _ expression: String,
                          timeout: TimeInterval = 15) async throws -> JSONValue {
        let reply = try await cdp("Runtime.evaluate",
                                  params: ["expression": .string(expression),
                                           "returnByValue": .bool(true), "awaitPromise": .bool(true)],
                                  sessionId: cdpSession, timeout: timeout)
        guard field(reply, "exceptionDetails") == .null else {
            throw AgentSpaceError("cdp_script", "page evaluation failed")
        }
        return field(field(reply, "result"), "value")
    }

    func snapshot(_ cdpSession: String, limit: Int) async throws -> ElementNode {
        let reply = try await cdp("Accessibility.getFullAXTree", sessionId: cdpSession, timeout: 30)
        return CDPBrowser.tree(reply, limit: limit)
    }

    func element(_ cdpSession: String, options: JSONValue) async throws -> ElementNode {
        let tree = try await snapshot(cdpSession, limit: 10_000)
        if let ref = stringField(options, "ref") {
            guard let node = tree.flattened.first(where: { $0.ref == ref }), node.ref != "0" else {
                throw AgentSpaceError("element_not_found", "the ref no longer exists - run observe for a fresh tree")
            }
            return node
        }
        var selector = Selector(role: stringField(options, "role"), title: stringField(options, "title"),
                                label: stringField(options, "label"),
                                valueContains: stringField(options, "value-contains"))
        if let index = int32Field(options, "index") { selector.index = Int(index) }
        guard !selector.isEmpty else {
            throw AgentSpaceError("element_required", "address an element with --ref or a selector")
        }
        return try selector.resolve(in: tree)
    }

    func nodeCall(_ cdpSession: String, _ node: ElementNode, _ function: String,
                          arguments: [JSONValue] = []) async throws -> JSONValue {
        guard let id = Int(node.ref.dropFirst(2)) else {
            throw AgentSpaceError("invalid_ref", "expected a current CDP DOM reference")
        }
        let resolved = try await cdp("DOM.resolveNode",
                                     params: ["backendNodeId": .number(Double(id))], sessionId: cdpSession)
        let reply = try await cdp("Runtime.callFunctionOn",
                                  params: ["objectId": field(field(resolved, "object"), "objectId"),
                                           "functionDeclaration": .string(function),
                                           "arguments": .array(arguments.map { .object(["value": $0]) }),
                                           "returnByValue": .bool(true), "awaitPromise": .bool(true)],
                                  sessionId: cdpSession)
        guard field(reply, "exceptionDetails") == .null else {
            throw AgentSpaceError("cdp_script", "DOM operation failed")
        }
        return field(field(reply, "result"), "value")
    }

    func settle(_ cdpSession: String, timeout: TimeInterval = 15) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if try await evaluate(cdpSession,
                "document.readyState === 'complete' && !['about:blank',''].includes(location.href)") == .bool(true) {
                try await Task.sleep(for: .milliseconds(300))
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw AgentSpaceError("navigation_timeout", "the page did not finish loading")
    }

    func assess(_ sessionID: String) async throws -> AccessReport {
        guard let session = journal.sessions[sessionID], !session.ended else { throw AgentSpaceError("session_not_found", "unknown session") }
        let generation = try guardBrowser()
        let (target, page) = try pageSession(sessionID)
        let revision = live[sessionID]?.revision ?? 0
        let before = try await cdp("Page.getFrameTree", sessionId: page)
        let raw = try await evaluate(page, SiteAccess.evidenceExpression)
        let after = try await cdp("Page.getFrameTree", sessionId: page)
        let loader = stringField(field(field(before, "frameTree"), "frame"), "loaderId") ?? ""
        guard generation.identity == journal.generation?.identity,
              loader == (stringField(field(field(after, "frameTree"), "frame"), "loaderId") ?? ""),
              revision == (live[sessionID]?.revision ?? 0) else {
            live[sessionID]?.access = nil
            throw AgentSpaceError("document_changed", "the page changed during access assessment; retry observation")
        }
        let facts = SiteAccess.facts(from: raw)
        let report = SiteAccess.assess(facts, site: session.site,
                                     expectedDigest: session.expectedAccountDigest, hash: accountHash)
        let document = "\(generation.identity.guid)|\(target)|\(loader)|\(stringField(raw, "document") ?? "")"
        live[sessionID] = LiveSession(access: report, lastURL: facts.url, document: document, revision: revision)
        return report
    }

    func accessValue(_ report: AccessReport) -> JSONValue {
        .object(["access": .string(report.access.rawValue), "identity": .string(report.identity.rawValue),
                 "identityMethod": report.identityMethod.map(JSONValue.string) ?? .null,
                 "evidence": .array(report.evidence.map(JSONValue.string)), "reason": report.reason.map(JSONValue.string) ?? .null])
    }

    func gate(_ sessionID: String, command: String, allowHandoff: Bool = false) throws {
        guard let session = journal.sessions[sessionID] else { throw AgentSpaceError("session_not_found", "unknown session") }
        guard allowHandoff || session.handoff == .background else { throw AgentSpaceError("handoff_active", "automation is paused during human handoff; run session-resume after sign-in") }
        guard let report = live[sessionID]?.access else { throw AgentSpaceError("access_unassessed", "fresh access evidence is unavailable") }
        if session.expectedAccountDigest != nil, report.identity != .verified {
            throw AgentSpaceError("account_unverified", "the expected account is not verified (state \(report.identity.rawValue)); observation and mutation are paused. Use session-handoff to sign in yourself.")
        }
        if command != "observe", report.access == .loginRequired {
            throw AgentSpaceError("login_required", "the page reports a sign-in wall; use session-handoff. Automated password input is refused.")
        }
    }

    func authorize(_ sessionID: String, command: String) async throws -> String {
        guard journal.sessions[sessionID]?.handoff == .background else { throw AgentSpaceError("handoff_active", "automation is paused during human handoff") }
        _ = try await assess(sessionID)
        try gate(sessionID, command: command)
        return live[sessionID]!.document!
    }

    func validateRead(_ sessionID: String, document: String) async throws {
        _ = try await authorize(sessionID, command: "observe")
        guard live[sessionID]?.document == document else { throw AgentSpaceError("document_changed", "the document changed during readback; content was withheld") }
    }

    func refusePasswordInput(_ cdpSession: String, node: ElementNode? = nil) async throws {
        if let node {
            let info = try await nodeCall(cdpSession, node, "function(){return {type:this.type,tag:this.tagName}}")
            if stringField(info, "type")?.lowercased() == "password" {
                throw AgentSpaceError("password_input_refused",
                    "the resolved element is a password field - AgentSpace never produces automated "
                    + "password input; sign in yourself via session-handoff")
            }
            return
        }
        let info = try await evaluate(cdpSession,
            "(()=>{const e=document.activeElement;return e?{type:e.type||'',tag:e.tagName||''}:null})()")
        if stringField(info, "type")?.lowercased() == "password" {
            throw AgentSpaceError("password_input_refused",
                "the focused element is a password field - AgentSpace never produces automated "
                + "password input; sign in yourself via session-handoff")
        }
    }

    public func perform(sessionID: String, command: String, options: JSONValue) async throws -> JSONValue {
        guard let session = journal.sessions[sessionID], !session.ended else {
            throw AgentSpaceError("session_not_found", "unknown or ended session \(sessionID)")
        }
        _ = try guardBrowser()
        _ = try await authorize(sessionID, command: command)
        let (_, cdpSession) = try pageSession(sessionID)
        var result: [String: JSONValue] = ["session": .string(sessionID)]
        var inputAttempted = false
        var inputDispatched = false
        do {
            switch command {
            case "observe":
                let limit = min(max(Int(int32Field(options, "limit") ?? 1000), 1), 10_000)
                let depth = min(max(Int(int32Field(options, "depth") ?? 16), 0), 30)
                let document = try await authorize(sessionID, command: command)
                var tree = try await snapshot(cdpSession, limit: limit)
                try await validateRead(sessionID, document: document)
                if depth == 0 { tree.children = [] }
                result["tree"] = try .encoded(tree)
                result["truncated"] = .bool(tree.children.count == limit)
                if field(options, "screenshot") == .bool(true) {
                    let capture = try await cdp("Page.captureScreenshot",
                                                params: ["format": .string("png"), "captureBeyondViewport": .bool(false)],
                                                sessionId: cdpSession, timeout: 30)
                    guard let data = Data(base64Encoded: stringField(capture, "data") ?? ""),
                          data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
                        throw AgentSpaceError("capture_failed", "CDP returned no PNG")
                    }
                    try await validateRead(sessionID, document: document)
                    result["screenshot"] = .object(["base64": .string(data.base64EncodedString()), "mimeType": .string("image/png")])
                }
            case "click":
                let document = try await authorize(sessionID, command: command)
                let node = try await element(cdpSession, options: options)
                try await validateRead(sessionID, document: document)
                if config.mode == .shared,
                   try await nodeCall(cdpSession, node, "function(){const a=this.closest('a,area');return !!a&&(a.hasAttribute('download')||/^(blob:|data:)/i.test(a.href))}") == .bool(true) {
                    journal.sessions[sessionID]?.downloadsBlocked += 1
                    try saveJournal()
                    throw AgentSpaceError("download_refused", "shared Chrome download links and blob or data destinations are unsupported; use a dedicated profile for downloads")
                }
                let point = try await nodeCall(cdpSession, node,
                    "function(){this.scrollIntoView({block:'center',behavior:'instant'});for(const r of this.getClientRects()){const x=r.x+r.width/2,y=r.y+r.height/2;const hit=document.elementFromPoint(x,y);if(r.width>0&&r.height>0&&hit&&(hit===this||this.contains(hit)))return {x,y};}return null}")
                guard field(point, "x") != .null else {
                    throw AgentSpaceError("unsupported", "element has no clickable box")
                }
                _ = try await authorize(sessionID, command: command)
                for type in ["mousePressed", "mouseReleased"] {
                    inputAttempted = true
                    _ = try await cdp("Input.dispatchMouseEvent",
                                      params: ["type": .string(type), "x": field(point, "x"), "y": field(point, "y"),
                                               "button": .string("left"), "clickCount": .number(1)],
                                      sessionId: cdpSession)
                    inputDispatched = true
                }
                result["dispatched"] = .bool(true)
                try await Task.sleep(for: .milliseconds(150))
                let afterDocument = try await authorize(sessionID, command: "observe")
                let tree = try await snapshot(cdpSession, limit: 1000)
                try await validateRead(sessionID, document: afterDocument)
                result["readback"] = try .encoded(tree)
            case "type-text":
                let document = try await authorize(sessionID, command: command)
                let node = try await element(cdpSession, options: options)
                try await validateRead(sessionID, document: document)
                try await refusePasswordInput(cdpSession, node: node)
                guard ["AXTextField", "AXTextArea"].contains(node.role) else {
                    throw AgentSpaceError("unsupported", "typing requires a text field")
                }
                guard let text = stringField(options, "text") else {
                    throw AgentSpaceError("missing_option", "type-text needs --text")
                }
                let replace = field(options, "replace") == .bool(true)
                let before = try await nodeCall(cdpSession, node,
                    "function(replace){this.focus();this.setSelectionRange(replace?0:this.value.length,this.value.length);return this.value}",
                    arguments: [.bool(replace)])
                let beforeText = stringField(.object(["value": before]), "value") ?? ""
                let expected = (replace ? "" : beforeText) + text
                try await validateRead(sessionID, document: document)
                if text.isEmpty, replace {
                    for type in ["keyDown", "keyUp"] {
                        inputAttempted = true
                        _ = try await cdp("Input.dispatchKeyEvent",
                                          params: ["type": .string(type), "key": .string("Backspace"),
                                                   "windowsVirtualKeyCode": .number(8)], sessionId: cdpSession)
                        inputDispatched = true
                    }
                } else {
                    inputAttempted = true
                    _ = try await cdp("Input.insertText", params: ["text": .string(text)], sessionId: cdpSession)
                    inputDispatched = true
                }
                _ = try await authorize(sessionID, command: command)
                let actual = try await nodeCall(cdpSession, node, "function(){return this.value}")
                try await validateRead(sessionID, document: document)
                guard actual == .string(expected) else {
                    throw AgentSpaceError("verification_failed", "text readback did not match")
                }
                result["verified"] = .bool(true); result["value"] = actual
            case "key":
                try await refusePasswordInput(cdpSession)
                guard let key = stringField(options, "key")?.lowercased(),
                      let name = ["return": "Enter", "enter": "Enter", "tab": "Tab", "backspace": "Backspace",
                                  "escape": "Escape"][key] else {
                    throw AgentSpaceError("unsupported", "key supports return, enter, tab, backspace, escape")
                }
                for type in ["keyDown", "keyUp"] {
                    inputAttempted = true
                    _ = try await cdp("Input.dispatchKeyEvent",
                                      params: ["type": .string(type), "key": .string(name)],
                                      sessionId: cdpSession)
                    inputDispatched = true
                }
                result["dispatched"] = .bool(true)
            case "scroll":
                let direction = stringField(options, "direction") ?? "down"
                guard ["up", "down", "left", "right"].contains(direction) else {
                    throw AgentSpaceError("invalid_option", "unknown scroll direction")
                }
                let vertical = ["up", "down"].contains(direction)
                let end = ["down", "right"].contains(direction)
                let amount = min(max(numberField(options, "amount") ?? 0.8, 0.01), 100)
                let unit = stringField(options, "unit") ?? "fraction"
                guard ["fraction", "pages"].contains(unit) else {
                    throw AgentSpaceError("invalid_unit", "unit must be fraction or pages")
                }
                let axis = vertical ? "Top" : "Left", size = vertical ? "Height" : "Width"
                let expression = "(()=>{const e=document.scrollingElement;const max=e.scroll\(size)-e.client\(size);"
                    + "const p=Math.max(0,Math.min(max,e.scroll\(axis)+\(end ? "" : "-")\(amount)*\(unit == "fraction" ? "max" : "e.client" + size)));"
                    + "e.scrollTo({\(vertical ? "top" : "left"):p,behavior:'instant'});return p})()"
                inputAttempted = true
                let expected = try await evaluate(cdpSession, expression)
                inputDispatched = true
                try await Task.sleep(for: .milliseconds(100))
                _ = try await authorize(sessionID, command: command)
                let actual = try await evaluate(cdpSession, vertical ? "scrollY" : "scrollX")
                guard case .number(let wanted) = expected, case .number(let observed) = actual,
                      abs(wanted - observed) <= 1 else {
                    throw AgentSpaceError("verification_failed", "scroll readback did not match")
                }
                result["verified"] = .bool(true)
                let doc = try await authorize(sessionID, command: command)
                result["position"] = try await evaluate(cdpSession, "({x:scrollX,y:scrollY})")
                try await validateRead(sessionID, document: doc)
            default:
                throw AgentSpaceError("unsupported", "\(command) is not available on a chrome session")
            }
            _ = try await authorize(sessionID, command: command)
            let counts = try await evaluate(cdpSession, "(()=>{const s=window.__agentSpacePolicy;if(!s)return null;const n={popups:s.popups,downloads:s.downloads};s.popups=0;s.downloads=0;return n})()")
            if let popups = int32Field(counts, "popups"), popups > 0 { journal.sessions[sessionID]?.popupRejected += Int(popups) }
            if let downloads = int32Field(counts, "downloads"), downloads > 0 { journal.sessions[sessionID]?.downloadsBlocked += Int(downloads) }
            try saveJournal()
            _ = try await authorize(sessionID, command: command)
            if let access = live[sessionID]?.access {
                result["access"] = .object([
                    "access": .string(access.access.rawValue),
                    "identity": .string(access.identity.rawValue),
                ])
            }
            return .object(result)
        } catch {
            guard inputAttempted else { throw error }
            let failure = error as? AgentSpaceError ?? AgentSpaceError("verification_failed", "input was attempted but its result could not be verified")
            throw AgentSpaceError(failure.code, failure.description,
                details: .object(["dispatched": .bool(inputDispatched), "dispatchUncertain": .bool(!inputDispatched),
                    "verified": .bool(false), "retrySafe": .bool(false)]))
        }
    }

}
