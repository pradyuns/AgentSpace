import Foundation

extension SessionCore {
    func armPage(cdpSession: String, sessionID: String, paused: Bool = false) async throws {
        if attachments.values.contains(cdpSession) { try await configureOwnedDownloads(sessionID) }
        _ = try await cdp("Page.enable", sessionId: cdpSession)
        _ = try await cdp("Runtime.enable", sessionId: cdpSession)
        if policyScripts[cdpSession] == nil {
            let receipt = try await cdp("Page.addScriptToEvaluateOnNewDocument",
                params: ["source": .string(SessionPagePolicy.script(shared: config.mode == .shared)), "runImmediately": .bool(true)], sessionId: cdpSession)
            guard let id = stringField(receipt, "identifier") else { throw AgentSpaceError("policy_unavailable", "Chrome did not install the owned-page policy") }
            policyScripts[cdpSession] = id
        }
        if !paused { _ = try await evaluate(cdpSession, SessionPagePolicy.script(shared: config.mode == .shared)) }
        for context in (paused ? [] : executionContexts[cdpSession] ?? []) {
            _ = try await cdp("Runtime.evaluate", params: ["expression": .string(SessionPagePolicy.script(shared: config.mode == .shared)),
                "contextId": .number(Double(context)), "returnByValue": .bool(true)], sessionId: cdpSession)
        }
        _ = try await cdp("Target.setAutoAttach", params: ["autoAttach": .bool(true),
            "waitForDebuggerOnStart": .bool(true), "flatten": .bool(true)], sessionId: cdpSession)
        if config.mode == .shared {
            _ = try await cdp("Fetch.enable", params: ["patterns": .array([.object(["requestStage": .string("Response")])])], sessionId: cdpSession)
        }
    }

    func disarmPage(_ cdpSession: String) async throws {
        let pages = sessionByCDPSession.filter { $0.value == sessionByCDPSession[cdpSession] }.map(\.key)
        for page in pages {
            if let id = policyScripts[page] {
                _ = try await cdp("Page.removeScriptToEvaluateOnNewDocument", params: ["identifier": .string(id)], sessionId: page)
                policyScripts[page] = nil
            }
            let disable = "(()=>{const s=window.__agentSpacePolicy;if(s){s.enabled=false;s.restore();}return true})()"
            _ = try await evaluate(page, disable)
            for context in executionContexts[page] ?? [] {
                _ = try await cdp("Runtime.evaluate", params: ["expression": .string(disable), "contextId": .number(Double(context)), "returnByValue": .bool(true)], sessionId: page)
            }
            _ = try await cdp("Fetch.disable", sessionId: page)
        }
        for page in pages {
            _ = try await cdp("Target.setAutoAttach", params: ["autoAttach": .bool(true),
                "waitForDebuggerOnStart": .bool(false), "flatten": .bool(true)], sessionId: page)
        }
    }

    func handleEvent(_ event: CDPEvent, epoch: Int) async {
        switch event.method {
        case "Runtime.executionContextCreated":
            if let page = event.sessionId, let context = int32Field(field(event.params, "context"), "id"),
               field(field(field(event.params, "context"), "auxData"), "isDefault") == .bool(true) {
                executionContexts[page, default: []].insert(context)
            }
        case "Runtime.executionContextDestroyed":
            if let page = event.sessionId, let context = int32Field(event.params, "executionContextId") { executionContexts[page]?.remove(context) }
        case "Page.frameNavigated", "Page.frameStartedLoading", "Runtime.executionContextsCleared":
            if event.method == "Runtime.executionContextsCleared", let page = event.sessionId { executionContexts[page] = [] }
            if let page = event.sessionId, let id = sessionByCDPSession[page] {
                var state = live[id] ?? LiveSession()
                state.access = nil; state.document = nil; state.revision += 1
                live[id] = state
            }
        case "Target.attachedToTarget":
            guard let parent = event.sessionId, let id = sessionByCDPSession[parent],
                  let child = stringField(event.params, "sessionId") else { return }
            if stringField(field(event.params, "targetInfo"), "type") == "iframe" {
                sessionByCDPSession[child] = id
                do {
                    if journal.sessions[id]?.handoff == .background {
                        try await armPage(cdpSession: child, sessionID: id,
                            paused: field(event.params, "waitingForDebugger") == .bool(true))
                    } else {
                        _ = try await cdp("Runtime.enable", sessionId: child)
                        _ = try await cdp("Target.setAutoAttach", params: ["autoAttach": .bool(true),
                            "waitForDebuggerOnStart": .bool(false), "flatten": .bool(true)], sessionId: child)
                    }
                }
                catch {
                    if epoch == transportEpoch { connectionError = AgentSpaceError("policy_unavailable", "a child frame could not be protected; automation is paused") }
                }
            }
            _ = try? await cdp("Runtime.runIfWaitingForDebugger", sessionId: child)
        case "Fetch.requestPaused":
            guard let page = event.sessionId, let id = sessionByCDPSession[page],
                  let request = stringField(event.params, "requestId") else { return }
            let headers = arrayField(event.params, "responseHeaders")
            let attachment = headers.contains { stringField($0, "name")?.lowercased() == "content-disposition" && (stringField($0, "value") ?? "").lowercased().contains("attachment") }
            let mime = headers.first { stringField($0, "name")?.lowercased() == "content-type" }.flatMap { stringField($0, "value") }?.lowercased().split(separator: ";").first.map(String.init)
            let status = int32Field(event.params, "responseStatusCode") ?? 0
            let unsafeDocument = (200..<300).contains(status) && status != 204 && stringField(event.params, "resourceType") == "Document" && mime.map { !SessionPagePolicy.renderableMIME.contains($0.trimmingCharacters(in: .whitespaces)) } != false
            let blocked = journal.sessions[id]?.handoff == .background && (attachment || unsafeDocument)
            do {
                _ = try await cdp(blocked ? "Fetch.failRequest" : "Fetch.continueRequest", params: blocked
                    ? ["requestId": .string(request), "errorReason": .string("Aborted")]
                    : ["requestId": .string(request)], sessionId: page)
                if blocked { journal.sessions[id]?.downloadsBlocked += 1; try saveJournal() }
            } catch {
                if epoch == transportEpoch { connectionError = AgentSpaceError("policy_unavailable", "a paused page response could not be settled; automation is paused") }
            }
        case "Target.targetDestroyed":
            if let target = stringField(event.params, "targetId") { markTarget(target, state: .closed) }
        case "Target.detachedFromTarget":
            if let page = stringField(event.params, "sessionId") {
                if let target = attachments.first(where: { $0.value == page })?.key { attachments[target] = nil }
                sessionByCDPSession[page] = nil; policyScripts[page] = nil; executionContexts[page] = nil
            }
        case "Browser.downloadWillBegin":
            guard config.mode == .dedicated, let guid = stringField(event.params, "guid"),
                  let frame = stringField(event.params, "frameId"),
                  let id = journal.sessions.first(where: { !$0.value.ended && $0.value.targets.contains { $0.state == .open && $0.targetId == frame } })?.key else { return }
            pendingDownloads[guid] = id
        case "Browser.downloadProgress":
            guard config.mode == .dedicated, let guid = stringField(event.params, "guid"),
                  field(event.params, "state") == .string("completed"), let id = pendingDownloads.removeValue(forKey: guid) else { return }
            // Persist only our opaque receipt, never a server-supplied filename.
            journal.sessions[id]?.downloadsSaved.append(guid)
            try? saveJournal()
        default: break
        }
    }
}

enum SessionPagePolicy {
    static let renderableMIME: Set<String> = ["text/html", "application/xhtml+xml", "text/plain", "image/png", "image/jpeg", "image/gif", "image/webp", "image/svg+xml"]
    static func script(shared: Bool) -> String { """
    (() => {
      if (window.__agentSpacePolicy) { window.__agentSpacePolicy.enabled=true; window.__agentSpacePolicy.shared=\(shared ? "true" : "false"); return true; }
      const state = {enabled:true, popups:0, downloads:0};
      Object.defineProperty(window,'__agentSpacePolicy',{value:state});
      const targets=new Map();
      const rewrite=(e,attr)=>{
        let attrs=targets.get(e);if(!attrs){attrs=new Map();targets.set(e,attrs);}
        if(!attrs.has(attr))attrs.set(attr,e.getAttribute(attr));
        e.setAttribute(attr,'_self');
      };
      state.restore=()=>{for(const [e,attrs] of targets)for(const [attr,value] of attrs){if(value===null)e.removeAttribute(attr);else e.setAttribute(attr,value);}targets.clear();};
      const open=window.open;
      window.open=function(...args){if(state.enabled){state.popups++;return null;}return open.apply(this,args);};
      const protect = e => {
        if(!state.enabled || !e) return false;
        const href=e.href || e.action || '';
        if (state.shared && (e.hasAttribute('download') || /^(blob:|data:)/i.test(href))) {
          state.downloads++; return true;
        }
        const target=e.getAttribute('target') || (document.querySelector('base[target]')||{}).target || '';
        if(target && !['_self','_top','_parent'].includes(target.toLowerCase())) {
          rewrite(e,'target'); state.popups++;
        }
        return false;
      };
      document.addEventListener('click',event=>{
        const e=event.composedPath().find(x=>x instanceof HTMLAnchorElement || x instanceof HTMLAreaElement);
        if(protect(e)){event.preventDefault();event.stopImmediatePropagation();}
      },true);
      document.addEventListener('submit',event=>{
        const form=event.target;
        const submitter=event.submitter;
        if(state.enabled && submitter && submitter.hasAttribute('formtarget')) rewrite(submitter,'formtarget');
        if(protect(form)){event.preventDefault();event.stopImmediatePropagation();}
      },true);
      const submit=HTMLFormElement.prototype.submit;
      HTMLFormElement.prototype.submit=function(...args){if(protect(this))return;return submit.apply(this,args);};
      const requestSubmit=HTMLFormElement.prototype.requestSubmit;
      HTMLFormElement.prototype.requestSubmit=function(button){if(state.enabled && button && button.hasAttribute('formtarget'))rewrite(button,'formtarget');if(protect(this))return;return requestSubmit.call(this,button);};
      const click=HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click=function(...args){if(protect(this))return;return click.apply(this,args);};
      state.shared=\(shared ? "true" : "false");
      return true;
    })()
    """ }
}
