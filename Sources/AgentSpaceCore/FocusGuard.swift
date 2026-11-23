import AppKit
import ApplicationServices

final class ActivationWatch: @unchecked Sendable {
    private let lock=NSLock()
    private var pids:[Int32]=[]
    private var token:(any NSObjectProtocol)?
    init() {
        token=NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:nil) { [weak self] note in
            guard let app=note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {return}
            self?.lock.lock();self?.pids.append(app.processIdentifier);self?.lock.unlock()
        }
    }
    func stop() -> [Int32] {
        if let token {NSWorkspace.shared.notificationCenter.removeObserver(token)}
        token=nil
        lock.lock();defer {lock.unlock()};return pids
    }
    deinit {if let token {NSWorkspace.shared.notificationCenter.removeObserver(token)}}
}

@MainActor
public enum FocusGuard {
    public static func snapshot() -> FocusSnapshot {
        let app=NSWorkspace.shared.frontmostApplication
        let point=CGEvent(source:nil)?.location ?? .zero
        let system=AXUIElementCreateSystemWide()
        var pid:pid_t=0
        let focused=AX.element(system,kAXFocusedApplicationAttribute)
        if let focused {AXUIElementGetPid(focused,&pid)}
        return FocusSnapshot(frontmost:app.map{Frontmost(pid:$0.processIdentifier,bundleIdentifier:$0.bundleIdentifier,name:$0.localizedName)},
                             cursor:CursorPoint(x:point.x,y:point.y),axFocusedAppPID:focused == nil ? nil : pid,
                             axFocusedElementRole:AX.element(system,kAXFocusedUIElementAttribute).flatMap{AX.string($0,kAXRoleAttribute)})
    }
}
