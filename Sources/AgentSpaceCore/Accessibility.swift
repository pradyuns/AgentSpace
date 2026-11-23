import AppKit
import ApplicationServices

@MainActor
enum AX {
    static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success ? result : nil
    }
    static func element(_ element: AXUIElement, _ key: String) -> AXUIElement? {
        guard let v=value(element,key), CFGetTypeID(v)==AXUIElementGetTypeID() else {return nil}
        return unsafeDowncast(v,to:AXUIElement.self)
    }
    static func string(_ element: AXUIElement, _ key: String) -> String? {
        guard let v=value(element,key) else {return nil}
        return (v as? String) ?? (v as? NSNumber)?.stringValue
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] { value(element,kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    static func actions(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        return AXUIElementCopyActionNames(element,&names) == .success ? names as? [String] ?? [] : []
    }
    static func frame(_ element: AXUIElement) -> WindowFrame? {
        guard let p=value(element,kAXPositionAttribute), let s=value(element,kAXSizeAttribute),
              CFGetTypeID(p)==AXValueGetTypeID(), CFGetTypeID(s)==AXValueGetTypeID() else {return nil}
        var point=CGPoint.zero; var size=CGSize.zero
        guard AXValueGetValue(unsafeDowncast(p,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeDowncast(s,to:AXValue.self),.cgSize,&size) else {return nil}
        return WindowFrame(x:point.x,y:point.y,width:size.width,height:size.height)
    }
    static func node(_ element: AXUIElement, ref: String, children: [ElementNode] = []) -> ElementNode {
        ElementNode(ref:ref,role:string(element,kAXRoleAttribute) ?? "unknown",
                    subrole:string(element,kAXSubroleAttribute),title:string(element,kAXTitleAttribute).map{String($0.prefix(500))},
                    label:string(element,kAXDescriptionAttribute).map{String($0.prefix(500))},
                    value:string(element,kAXValueAttribute).map{String($0.prefix(1000))},frame:frame(element),
                    enabled:value(element,kAXEnabledAttribute) as? Bool,actions:actions(element),children:children)
    }
    static func tree(_ root: AXUIElement, depth: Int = 16, limit: Int = 1000) -> (ElementNode, Bool) {
        var count=0; var truncated=false
        func visit(_ e: AXUIElement, _ ref: String, _ level: Int) -> ElementNode {
            count += 1
            var out: [ElementNode]=[]
            let children=children(e)
            if level < depth {
                for (index, child) in children.enumerated() {
                    guard count < limit else {truncated=true;break}
                    out.append(visit(child,"\(ref).\(index)",level+1))
                }
            } else if !children.isEmpty {truncated=true}
            return node(e,ref:ref,children:out)
        }
        let result=visit(root,"0",0)
        return (result,truncated)
    }
    static func resolve(_ ref: String, root: AXUIElement) throws -> AXUIElement {
        var current=root
        for index in try ElementRef(ref).indices {
            let kids=children(current)
            guard index < kids.count else {throw AgentSpaceError("element_not_found","Ref \(ref) no longer exists; observe again")}
            current=kids[index]
        }
        return current
    }
    static func resolve(root: AXUIElement, ref: String?, selector: Selector) throws -> AXUIElement {
        if let ref { return try resolve(ref,root:root) }
        guard !selector.isEmpty else {throw AgentSpaceError("element_required","Provide --ref or a selector")}
        let (tree,truncated)=tree(root)
        if truncated {throw AgentSpaceError("tree_limit","Selector search exceeded tree limits; use a ref from observe")}
        return try resolve(selector.resolve(in:tree).ref,root:root)
    }
    static func resolveWhenReady<Value>(attempts:Int=20, interval:Duration = .milliseconds(100),
                                        resolve:() throws -> Value) async throws -> Value {
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        for attempt in 0..<attempts {
            do {return try resolve()}
            catch let error as AgentSpaceError where error.code=="element_not_found"
                && attempt+1<attempts && ContinuousClock.now<deadline {
                try await Task.sleep(for:interval)
            }
        }
        throw AgentSpaceError("element_not_found","No element became ready")
    }
    static func documentURLMatches(_ actual:URL?,requested:URL) -> Bool {
        guard let actual else {return false}
        if actual.isFileURL && requested.isFileURL {
            return actual.standardizedFileURL.resolvingSymlinksInPath()==requested.standardizedFileURL.resolvingSymlinksInPath()
        }
        return actual==requested
    }
    static func containsDocument(_ root:AXUIElement,url:URL) -> Bool {
        var documents:[URL?]=[]
        var remaining=1000
        var truncated=false
        func visit(_ element:AXUIElement,_ depth:Int) {
            guard remaining>0,depth<=16 else {truncated=true;return}
            remaining-=1
            if string(element,kAXRoleAttribute)=="AXWebArea" {
                let raw=value(element,"AXURL")
                documents.append((raw as? URL) ?? (raw as? String).flatMap{URL(string:$0)})
                return
            }
            for child in children(element) {visit(child,depth+1)}
        }
        visit(root,0)
        return !truncated && documents.count==1 && documentURLMatches(documents[0],requested:url)
    }
    static func windows(_ pid: pid_t) -> [AXUIElement] {
        value(AXUIElementCreateApplication(pid),kAXWindowsAttribute) as? [AXUIElement] ?? []
    }
    static func target(_ workspace: Workspace) throws -> AXUIElement {
        guard let target=workspace.target,
              let record=workspace.apps.first(where:{$0.pid==target.pid}), isAlive(record) else {
            throw AgentSpaceError("target_unavailable","Target app is not alive; launch or target a window first")
        }
        let windows=windows(target.pid)
        let matches=windows.filter{string($0,kAXTitleAttribute)==target.title}
        if matches.count == 1 {return matches[0]}
        if target.index < windows.count, string(windows[target.index],kAXTitleAttribute)==target.title {return windows[target.index]}
        throw AgentSpaceError("target_unavailable","Target window closed or changed title; run target-window")
    }
    static func isAlive(_ record: AppRecord) -> Bool {
        guard let app=NSRunningApplication(processIdentifier:record.pid), !app.isTerminated,
              app.bundleIdentifier==record.bundleIdentifier else {return false}
        return app.launchDate == record.launchDate
    }
    static func set(_ e:AXUIElement,_ key:String,_ value:CFTypeRef)->AXError {
        AXUIElementSetAttributeValue(e,key as CFString,value)
    }
    static func perform(_ e:AXUIElement,_ action:String)->AXError {AXUIElementPerformAction(e,action as CFString)}
}
