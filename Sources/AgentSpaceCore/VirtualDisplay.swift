import AppKit
import ApplicationServices
import Foundation
import ScreenCaptureKit

/// The identity a spawn reports through `onLaunched` - a lock so the spawn
/// thread can hand pid+start back while the caller is still awaiting the
/// handshake result.
private final class LaunchIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var pidValue: Int32?
    private var startValue: TimeInterval?
    func record(pid: Int32, start: TimeInterval?) {
        lock.withLock { pidValue = pid; startValue = start }
    }
    var identity: (pid: Int32, start: TimeInterval?)? {
        lock.withLock { pidValue.map { ($0, startValue) } }
    }
}

/// The virtual-display backend, implemented end to end on AgentSpace-owned
/// components: `agentspace-display-host` owns a CGVirtualDisplay and answers an
/// authenticated unix-socket protocol; this backend launches its own app
/// instances, places their windows wholly inside the display via AX geometry,
/// and delivers input through Chrome's owned CDP endpoint or per-PID events
/// after re-verifying window identity, display containment and focus ownership.
@MainActor
public enum VirtualDisplay {
    static let presets: [String: (width: Int, height: Int)] = [
        "1080p": (1920, 1080), "1440p": (2560, 1440),
    ]
    static let writableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField",
        "AXComboBox", "AXSecureTextField"]

    static func validatePreset(_ preset: String) throws {
        guard presets[preset] != nil else {
            throw AgentSpaceError("invalid_option", "--preset must be one of \(presets.keys.sorted().joined(separator: ", "))")
        }
    }

    // MARK: State + host

    private static func state(_ workspace: Workspace) throws -> VirtualDisplayState {
        guard let state = workspace.virtualDisplay else {
            throw AgentSpaceError("virtual_display_session_required",
                "This workspace has no virtual-display session; launch an app with --backend virtual-display first")
        }
        guard state.backend == .native else {
            throw AgentSpaceError("legacy_backend_state",
                "This workspace was created by a previous integration AgentSpace no longer "
                + "uses. AgentSpace will not act on or migrate it: create a new workspace. "
                + "`stop-workspace --abandon-session` drops only AgentSpace's local record")
        }
        return state
    }

    /// Prove the recorded host is alive and answering: process liveness with the
    /// stored pid+start pair, then an authenticated `hello` whose reply must
    /// echo the workspace uuid and (unless the display was already destroyed)
    /// the recorded display id.
    @discardableResult
    private static func ensureHost(_ workspace: inout Workspace, store: StateStore) async throws -> VirtualDisplayState {
        var state = try self.state(workspace)
        let pid = state.hostPID ?? -1
        let live = DisplayHost.alive(pid, start: state.hostStart)
        if !live {
            if state.pendingCreate || state.hostPID == nil {
                // The handshake never confirmed and the process is gone - the
                // dead host provably owns nothing, so a fresh spawn is safe.
                return try await spawnHost(&workspace, store: store)
            }
            throw AgentSpaceError("virtual_display_host_lost",
                "The display host (pid \(pid)) is gone; its virtual display was destroyed by "
                + "the OS and any session windows moved back to the visible displays. The "
                + "workspace record is kept so stop-workspace can still terminate owned apps")
        }
        do {
            let socket = state.socketPath!
            let token = state.token!
            let uuid = state.workspaceUUID ?? ""
            let reply = try await Task.detached { @Sendable () -> JSONValue in
                try DisplayHost.call(socketPath: socket, token: token,
                                     op: "hello", fields: ["workspaceUUID": .string(uuid)], timeout: 5)
            }.value
            let verified = try verifyHello(state, reply: reply)
            if state.pendingCreate {
                state.pendingCreate = false
                state.displayID = verified.id
                workspace.virtualDisplay = state
                try store.save(workspace)
            }
            if let bounds = verified.bounds { state.bounds = bounds }
            return state
        } catch let error as AgentSpaceError {
            if ["virtual_display_host_lost", "display_lost", "synthetic_display"].contains(error.code) { throw error }
            if state.pendingCreate, !DisplayHost.alive(state.hostPID ?? -1, start: state.hostStart) {
                return try await spawnHost(&workspace, store: store)
            }
            throw AgentSpaceError("virtual_display_host_unreachable",
                "\(error.description). The display host did not answer hello; state kept so a "
                + "later command retries — a live unreachable host still holds the display")
        }
    }

    /// The contract a host hello must satisfy before AgentSpace trusts the
    /// seat: the reported display is real (a host started in fake-display test
    /// mode is never a seat AgentSpace drives input against), live, and - when
    /// one was already recorded - still the same id.
    public nonisolated static func verifyHello(_ state: VirtualDisplayState, reply: JSONValue) throws -> (id: UInt32, bounds: WindowFrame?) {
        let display = field(reply, "display")
        guard field(display, "fake") != .bool(true) else {
            throw AgentSpaceError("synthetic_display",
                "the display host reports a synthetic test display; AgentSpace never treats it as a real seat")
        }
        guard let id = uint32Field(display, "id") else {
            throw AgentSpaceError("display_lost",
                "the display host answers but reports no live display; the workspace "
                + "record is kept — stop-workspace cleans up owned apps")
        }
        if let recorded = state.displayID, recorded != id {
            throw AgentSpaceError("display_lost",
                "the host reports display \(id), not the recorded \(recorded); treating the "
                + "display as replaced — inspect with get-status before acting")
        }
        return (id, boundsField(display))
    }

    /// Spawn the persistent helper: write its 0600 token file first, persist a
    /// pending record naming socket/token/uuid, then hand it the display spec
    /// from the preset and require an authenticated hello before confirming.
    /// The child's pid+start are persisted the instant they exist - before
    /// the handshake - so an interrupted launch still leaves a stoppable
    /// record; a failed spawn kills only the proven child.
    private static func spawnHost(_ workspace: inout Workspace, store: StateStore,
                                  preset: String? = nil) async throws -> VirtualDisplayState {
        let executable = try DisplayHost.locateOrThrow()
        let size = presets[workspace.virtualDisplay?.preset ?? preset ?? "1080p"] ?? presets["1080p"]!
        let uuid = workspace.virtualDisplay?.workspaceUUID ?? UUID().uuidString
        let token = String((0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().prefix(96))
        let socketPath = try DisplayHost.socketPath(for: workspace.name, store: store)
        let tokenPath = try DisplayHost.tokenPath(for: workspace.name, store: store)
        try FileManager.default.createDirectory(atPath: (tokenPath as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: tokenPath, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
        let logPath = try store.directory(workspace.name).appendingPathComponent("display-host.log").path
        var state = VirtualDisplayState(hostPID: nil, hostStart: nil, socketPath: socketPath,
                                        token: token, workspaceUUID: uuid,
                                        displayID: nil, bounds: nil,
                                        preset: workspace.virtualDisplay?.preset ?? preset)
        state.pendingCreate = true
        workspace.virtualDisplay = state
        try store.save(workspace)
        let snapshot = workspace
        let pendingRecord = state
        let launched = LaunchIdentity()
        var spawned: (pid: Int32, start: TimeInterval, reply: JSONValue)?
        do {
            let workspaceName = workspace.name
            spawned = try await Task.detached { @Sendable () throws -> (pid: Int32, start: TimeInterval, reply: JSONValue) in
                try DisplayHost.spawn(executable: executable, workspaceUUID: uuid,
                                      socketPath: socketPath, tokenPath: tokenPath,
                                      width: size.width, height: size.height, hiDPI: true,
                                      name: "AgentSpace \(workspaceName)", logPath: logPath,
                                      onLaunched: { pid, start in
                    launched.record(pid: pid, start: start)
                    var pending = snapshot
                    var record = pending.virtualDisplay ?? pendingRecord
                    record.hostPID = pid
                    record.hostStart = start
                    pending.virtualDisplay = record
                    try? store.save(pending)
                })
            }.value
            state.hostPID = spawned!.pid
            state.hostStart = spawned!.start
            let verified = try verifyHello(state, reply: spawned!.reply)
            state.displayID = verified.id
            state.bounds = verified.bounds ?? state.bounds
            // Established records must satisfy the decoder's own invariant - a
            // signalable pid and a finite positive start - or the workspace
            // would be unreadable forever. `spawn` guarantees both already;
            // this guard is the last line of defense before persisting.
            guard DisplayHost.canSignal(state.hostPID ?? -1),
                  let savedStart = state.hostStart, savedStart.isFinite, savedStart > 0 else {
                throw AgentSpaceError("host_spawn_failed",
                    "spawn confirmed without a usable host identity; the pending record stays recoverable")
            }
            state.pendingCreate = false
            workspace.virtualDisplay = state
            try store.save(workspace)
            return state
        } catch {
            // Keep whatever identity the launch actually produced so the
            // record still names a stoppable helper; a guessed identity is
            // never written. Any spawned child the handshake rejected is
            // stopped by its recorded identity, not recomputed.
            if let recorded = launched.identity {
                state.hostPID = recorded.pid
                state.hostStart = recorded.start
            }
            if let spawned {
                _ = DisplayHost.terminate(spawned.pid, start: spawned.start, signal: SIGTERM)
            }
            // The decoder refuses an established record without a usable
            // pid+start identity - keep such a record pending instead so the
            // workspace stays decodable and recoverable (respawn or abandon).
            let identityUsable = DisplayHost.canSignal(state.hostPID ?? -1)
                && (state.hostStart ?? 0).isFinite && (state.hostStart ?? 0) > 0
            if !identityUsable { state.pendingCreate = true }
            workspace.virtualDisplay = state
            try? store.save(workspace)
            throw error
        }
    }

    private nonisolated static func boundsField(_ display: JSONValue) -> WindowFrame? {
        let frame = field(display, "bounds")
        guard let x = numberField(frame, "x"), let y = numberField(frame, "y"),
              let w = numberField(frame, "width"), let h = numberField(frame, "height") else { return nil }
        return WindowFrame(x: x, y: y, width: w, height: h)
    }

    // MARK: Launch

    /// Every option is validated before a single side effect; then the host is
    /// up, the app is launched nonactivating as OUR instance, and every owned
    /// window is moved wholly onto the display and read back.
    static func launch(_ workspace: inout Workspace, options: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        let rawApp = try options.required("app")
        let kind = rawApp.lowercased()
        let aliases = ["textedit": "com.apple.TextEdit", "safari": "com.apple.Safari",
                       "browser": "com.apple.Safari", "chrome": "com.google.Chrome"]
        guard rawApp.utf8.count <= 128, !rawApp.contains("/"), !rawApp.contains("\0") else {
            throw AgentSpaceError("invalid_app", "--app must be an app name or bundle id without path separators")
        }
        let bundle = aliases[kind] ?? rawApp
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            throw AgentSpaceError("app_unavailable",
                "virtual-display launches installed apps by name or bundle id: textedit, safari, chrome, or e.g. com.apple.Calculator")
        }
        guard !(options["url"] != nil && options["file"] != nil) else {
            throw AgentSpaceError("invalid_option", "Use --url or --file, not both")
        }
        guard kind == "textedit" || options["format"] == nil else {
            throw AgentSpaceError("unsupported_option", "--format only applies to textedit")
        }
        guard kind != "textedit" || (options["url"] == nil && options["file"] == nil) else {
            throw AgentSpaceError("unsupported_option",
                "textedit creates its own workspace document; --url/--file are not supported for it")
        }
        for name in ["chrome-launch-strategy", "restore-focus"] where options[name] != nil || options.has(name) {
            throw AgentSpaceError("unsupported_option", "--\(name) applies to the native AX launch path only")
        }
        if let preset = options["preset"] { try validatePreset(preset) }
        let temp = URL(fileURLWithPath: workspace.temporaryDirectory, isDirectory: true)
        var openItems: [URL] = []
        if kind == "textedit" {
            let ext = options["format"] ?? "txt"
            guard ["txt", "rtf"].contains(ext) else { throw AgentSpaceError("invalid_option", "--format must be txt or rtf") }
            let file = temp.appendingPathComponent("AgentSpace-\(UUID().uuidString).\(ext)")
            try (ext == "rtf" ? "{\\rtf1\\ansi }" : "").write(to: file, atomically: true, encoding: .utf8)
            openItems = [file]
        } else if let raw = options["file"] ?? options["url"] {
            if options["file"] != nil {
                let source = URL(fileURLWithPath: raw)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw AgentSpaceError("file_not_found", "Local browser file does not exist")
                }
                let copy = temp.appendingPathComponent("Page-\(UUID().uuidString).html")
                try FileManager.default.copyItem(at: source, to: copy)
                openItems = [copy]
            } else {
                guard let parsed = URL(string: raw), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                    throw AgentSpaceError("invalid_url", "Expected an http or https URL")
                }
                openItems = [parsed]
            }
        }
        if let existing = workspace.virtualDisplay {
            guard existing.backend == .native else {
                throw AgentSpaceError("legacy_backend_state",
                    "This workspace was created by a previous integration AgentSpace no longer "
                    + "uses. Create a new workspace; --abandon-session drops only the local record")
            }
            if let preset = options["preset"], preset != existing.preset {
                throw AgentSpaceError("conflicting_option",
                    "This workspace already has a virtual display (preset \(existing.preset ?? "none")); "
                    + "stop-workspace and relaunch to change display sizes")
            }
        }
        let state: VirtualDisplayState
        if workspace.virtualDisplay == nil {
            state = try await spawnHost(&workspace, store: store, preset: options["preset"])
        } else {
            state = try await ensureHost(&workspace, store: store)
        }
        guard let displayBounds = state.bounds else {
            throw AgentSpaceError("display_lost", "the display host reports no display bounds")
        }
        // A bare launch into the user's already-running process would adopt its
        // windows - including any on the user's own displays. Refuse up front.
        if openItems.isEmpty,
           NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundle && !$0.isTerminated }) {
            throw AgentSpaceError("app_already_running",
                "\(bundle) is already running; a bare launch would adopt the user's process and "
                + "act in windows AgentSpace does not own — open a document with --file or --url instead")
        }
        let previousPIDs = Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier))
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        config.createsNewApplicationInstance = true
        if kind == "chrome" {
            config.arguments = ["--user-data-dir=\(temp.appendingPathComponent("ChromeProfile").path)",
                                "--no-first-run", "--no-default-browser-check", "--force-renderer-accessibility",
                                "--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1", "--no-startup-window"]
        }
        let app: NSRunningApplication
        if kind == "chrome" || openItems.isEmpty {
            app = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
        } else {
            app = try await NSWorkspace.shared.open(openItems, withApplicationAt: appURL, configuration: config)
        }
        let owned = !previousPIDs.contains(app.processIdentifier)
        guard owned else {
            throw AgentSpaceError("app_already_running",
                "\(bundle) launch resolved to an already-running process (pid \(app.processIdentifier)); "
                + "AgentSpace will not target a process it did not start")
        }
        let record = AppRecord(pid: app.processIdentifier, bundleIdentifier: bundle,
                               launchDate: app.launchDate, owned: true, kind: kind)
        workspace.apps.append(record)
        try store.save(workspace)
        if kind == "chrome", let url = openItems.first {
            try await CDPBrowser.openWindow(workspace, profile: temp.appendingPathComponent("ChromeProfile"), url: url)
        }
        // Window readiness, then containment: place each of OUR process's
        // windows inside the display and verify the read-back frame is wholly
        // within its bounds. Nothing else on the machine is ever moved.
        var placed: [JSONValue] = []
        var target: WindowTarget?
        var placementError: String?
        let deadline = ContinuousClock.now.advanced(by: .seconds(6))
        repeat {
            placed = []
            let windows = AX.windows(app.processIdentifier)
            for (index, window) in windows.enumerated() {
                switch place(window, inside: displayBounds) {
                case .success(let frame):
                    placed.append(.object(["index": .number(Double(index)),
                        "title": AX.string(window, kAXTitleAttribute).map(JSONValue.string) ?? .null,
                        "frame": try .encoded(frame), "placed": .bool(true)]))
                case .failure(let error):
                    placed.append(.object(["index": .number(Double(index)), "placed": .bool(false),
                                           "error": .string(String(describing: error))]))
                }
            }
            if !placed.isEmpty, placed.allSatisfy({ field($0, "placed") == .bool(true) }) { break }
            try await Task.sleep(for: .milliseconds(150))
        } while ContinuousClock.now < deadline
        let verified = placed.filter { field($0, "placed") == .bool(true) }
        if verified.isEmpty, !AX.windows(app.processIdentifier).isEmpty {
            placementError = "no window could be placed wholly inside the display"
        } else if AX.windows(app.processIdentifier).isEmpty {
            placementError = "no AX windows reported yet; target-window retries placement"
        }
        if let first = AX.windows(app.processIdentifier).first, verified.count == AX.windows(app.processIdentifier).count, !verified.isEmpty {
            target = WindowTarget(pid: app.processIdentifier, windowID: nil,
                                  title: AX.string(first, kAXTitleAttribute) ?? "", index: 0)
        }
        workspace.target = target
        try store.save(workspace)
        return ("NSWorkspace.activates=false+CGVirtualDisplay", .object([
            "backend": .string("virtual-display"), "displayID": state.displayID.map { .number(Double($0)) } ?? .null,
            "hostPID": state.hostPID.map { .number(Double($0)) } ?? .null,
            "displayBounds": try .encoded(state.bounds), "app": try .encoded(record),
            "openedURL": openItems.first.map { .string($0.absoluteString) } ?? .null,
            "windowsPlaced": .array(verified), "placementNote": placementError.map(JSONValue.string) ?? .null,
            "target": try .encoded(workspace.target), "targetReady": .bool(workspace.target != nil),
            "launchedApps": .array([try .encoded(record)])]))
    }

    /// Move one owned window wholly inside the display: origin at the display's
    /// top-left plus an inset, size clamped to what fits, then a strict
    /// containment read-back.
    private static func place(_ window: AXUIElement, inside bounds: WindowFrame) -> Result<WindowFrame, AgentSpaceError> {
        let inset = 24.0
        var origin = CGPoint(x: bounds.x + inset, y: bounds.y + inset)
        var current = AX.frame(window)
        var size = CGSize(width: min(current?.width ?? bounds.width - 2 * inset, bounds.width - 2 * inset),
                          height: min(current?.height ?? bounds.height - 2 * inset, bounds.height - 2 * inset))
        size.width = max(size.width, 200); size.height = max(size.height, 120)
        guard let position = AXValueCreate(.cgPoint, &origin), let dimension = AXValueCreate(.cgSize, &size) else {
            return .failure(AgentSpaceError("ax_value", "Cannot create AX position/size values"))
        }
        var status = AX.set(window, kAXPositionAttribute, position)
        if status == .success { status = AX.set(window, kAXSizeAttribute, dimension) }
        if status != .success {
            return .failure(AgentSpaceError("display_placement_failed",
                "AX geometry write failed (\(status.rawValue)); the window was not moved"))
        }
        current = AX.frame(window)
        guard let frame = current, contained(frame, in: bounds) else {
            return .failure(AgentSpaceError("display_escape",
                "window frame \(describe(current)) is not wholly inside display bounds \(describe(bounds))"))
        }
        return .success(frame)
    }

    private static func contained(_ frame: WindowFrame, in bounds: WindowFrame, tolerance: Double = 2) -> Bool {
        frame.x >= bounds.x - tolerance && frame.y >= bounds.y - tolerance
            && frame.x + frame.width <= bounds.x + bounds.width + tolerance
            && frame.y + frame.height <= bounds.y + bounds.height + tolerance
    }

    private static func describe(_ frame: WindowFrame?) -> String {
        guard let frame else { return "(unreadable)" }
        return "(\(frame.x),\(frame.y) \(frame.width)x\(frame.height))"
    }

    // MARK: Per-command validation (before any effect)

    nonisolated static func preValidate(_ command: String, options: CommandOptions) throws {
        func refFormat(_ name: String) throws {
            if let ref = options[name] { _ = try ElementRef(ref) }
        }
        func notBoth(_ point: (x: Double, y: Double)?, _ what: String, _ addressed: Bool) throws {
            if point != nil, addressed {
                throw AgentSpaceError("invalid_option", "\(what) needs either --x/--y or an element (--ref/selectors), not both")
            }
        }
        switch command {
        case "observe":
            _ = try options.integer("depth", default: 16, range: 0...30)
            _ = try options.integer("max-nodes", default: 1000, range: 1...10000)
        case "click":
            let point = try options.point(); _ = try options.button(); _ = try options.clickCount(); _ = try options.modifierList()
            let selector = try options.selector(); try refFormat("ref")
            try notBoth(point, "click", options["ref"] != nil || !selector.isEmpty)
        case "move":
            let point = try options.point(); _ = try options.modifierList()
            let selector = try options.selector(); try refFormat("ref")
            try notBoth(point, "move", options["ref"] != nil || !selector.isEmpty)
            guard point != nil || options["ref"] != nil || !selector.isEmpty else {
                throw AgentSpaceError("invalid_option", "move needs --x/--y, --ref or an element selector")
            }
        case "drag":
            let from = try options.point(); let to = try options.point("to-x", "to-y")
            _ = try options.button(); _ = try options.modifierList()
            try refFormat("from-ref"); try refFormat("to-ref")
            let refs = (options["from-ref"] != nil) || (options["to-ref"] != nil)
            if refs {
                guard options["from-ref"] != nil, options["to-ref"] != nil else {
                    throw AgentSpaceError("invalid_option", "drag needs both --from-ref and --to-ref")
                }
                guard from == nil, to == nil else {
                    throw AgentSpaceError("invalid_option", "drag uses either refs or coordinates, not both")
                }
            } else {
                guard from != nil, to != nil else {
                    throw AgentSpaceError("invalid_option", "drag needs --x/--y and --to-x/--to-y")
                }
            }
        case "scroll":
            let point = try options.point(); _ = try options.modifierList()
            let selector = try options.selector(); try refFormat("ref")
            try notBoth(point, "scroll", options["ref"] != nil || !selector.isEmpty)
            _ = try scrollDelta(options)
        case "type-text":
            let text = try options.required("text")
            guard text.utf16.count <= 100_000 else { throw AgentSpaceError("text_too_large", "Text is limited to 100000 UTF-16 units") }
            _ = try options.selector(); try refFormat("ref")
        case "key":
            guard let key = options["key"], !key.isEmpty else {
                throw AgentSpaceError("invalid_option", "key needs a nonempty --key")
            }
            _ = try options.selector(); try refFormat("ref")
        case "target-window":
            _ = try options.integer("index", default: 0, range: 0...10000)
            if let raw = options["window"], UInt32(raw) == nil {
                throw AgentSpaceError("invalid_option", "--window must be a window id")
            }
            if let raw = options["pid"], Int32(raw) == nil {
                throw AgentSpaceError("invalid_option", "--pid must be a process id")
            }
        default:
            throw AgentSpaceError("unsupported", "Command is not available on the virtual-display backend")
        }
    }

    // MARK: Commands

    /// Verified execution context for anything that can send input: a native
    /// state, an answering host holding the recorded display, an owned live
    /// target app, its target window resolved and wholly inside the display,
    /// and the human's frontmost app not being our target.
    private struct Guarded {
        var state: VirtualDisplayState
        var record: AppRecord
        var window: AXUIElement
        var frame: WindowFrame
        var display: WindowFrame
    }

    private static func guarded(_ workspace: inout Workspace, store: StateStore) async throws -> Guarded {
        let state = try await ensureHost(&workspace, store: store)
        guard let bounds = state.bounds else { throw AgentSpaceError("display_lost", "no display bounds recorded") }
        guard let target = workspace.target else {
            throw AgentSpaceError("target_unavailable", "No target window; run target-window first")
        }
        guard let record = workspace.apps.first(where: { $0.pid == target.pid && $0.owned }), AX.isAlive(record) else {
            throw AgentSpaceError("target_unavailable", "Target app is not a live workspace-owned app")
        }
        guard DisplayHost.alive(state.hostPID ?? -1, start: state.hostStart) else {
            throw AgentSpaceError("virtual_display_host_lost", "the display host died; the display is gone")
        }
        let windows = AX.windows(target.pid)
        let window: AXUIElement
        let matches = windows.filter { AX.string($0, kAXTitleAttribute) == target.title }
        if matches.count == 1 { window = matches[0] }
        else if target.index < windows.count, AX.string(windows[target.index], kAXTitleAttribute) == target.title {
            window = windows[target.index]
        } else {
            throw AgentSpaceError("target_unavailable", "Target window closed or changed title; run target-window")
        }
        guard let frame = AX.frame(window) else {
            throw AgentSpaceError("display_escape", "target window frame is unreadable")
        }
        guard contained(frame, in: bounds) else {
            throw AgentSpaceError("display_escape",
                "target window \(describe(frame)) escaped or left the display bounds "
                + "\(describe(bounds)); input aborted — re-target it with target-window")
        }
        if FocusGuard.snapshot().frontmost?.pid == target.pid {
            throw AgentSpaceError("focus_unexpected",
                "the target app is unexpectedly the human's frontmost app; input aborted to "
                + "keep events from interleaving with human input")
        }
        return Guarded(state: state, record: record, window: window, frame: frame, display: bounds)
    }

    /// Stored --ref resolution: the element list from the observe the caller
    /// saw. Re-resolving the same tree path must still produce the same
    /// role/title/frame, else the ref is stale - never a best-guess element.
    private static func refElement(_ workspace: Workspace, ref: String, root: AXUIElement) throws -> (AXUIElement, ObservedElement) {
        guard let observation = workspace.virtualDisplay?.observation else {
            throw AgentSpaceError("observation_required",
                "--ref needs an observe first on this workspace; refs only mean something "
                + "against the observation they came from")
        }
        guard let stored = observation.elements.first(where: { $0.ref == ref }) else {
            throw AgentSpaceError("element_not_found", "Ref \(ref) was not in the last observe; run observe again")
        }
        let element = try AX.resolve(ref, root: root)
        let liveRole = AX.string(element, kAXRoleAttribute)
        let liveTitle = AX.string(element, kAXTitleAttribute).map { String($0.prefix(500)) }
        let liveFrame = AX.frame(element)
        let frameMatch = (stored.frame == nil && liveFrame == nil)
            || (stored.frame != nil && liveFrame != nil
                && abs(stored.frame!.x - liveFrame!.x) < 2 && abs(stored.frame!.y - liveFrame!.y) < 2
                && abs(stored.frame!.width - liveFrame!.width) < 2 && abs(stored.frame!.height - liveFrame!.height) < 2)
        guard liveRole == stored.role, liveTitle == stored.title, frameMatch else {
            throw AgentSpaceError("stale_reference",
                "ref \(ref) resolved to \(liveRole ?? "?")/\"\(liveTitle ?? "")\" at "
                + "\(describe(liveFrame)) but the observation recorded \(stored.role)/\"\(stored.title ?? "")\" "
                + "at \(describe(stored.frame)); observe again")
        }
        return (element, stored)
    }

    /// Resolve the actionable element for an addressed command: --ref (pinned
    /// to the stored observation) or a selector resolved against a fresh tree.
    private static func addressedElement(_ workspace: inout Workspace, options: CommandOptions,
                                         root: AXUIElement) throws -> AXUIElement? {
        if let ref = options["ref"] { return try refElement(workspace, ref: ref, root: root).0 }
        let selector = try options.selector()
        guard !selector.isEmpty else { return nil }
        let (tree, truncated) = AX.tree(root)
        if truncated { throw AgentSpaceError("tree_limit", "Selector search exceeded tree limits; use a ref from observe") }
        return try AX.resolve(selector.resolve(in: tree).ref, root: root)
    }

    /// Window-local point → global screen point, with the point required inside
    /// the window frame so a click can never land on another display's surface.
    private static func globalPoint(_ point: (x: Double, y: Double), in g: Guarded) throws -> CGPoint {
        guard point.x >= 0, point.y >= 0, point.x <= g.frame.width, point.y <= g.frame.height else {
            throw AgentSpaceError("invalid_option",
                "window-local point (\(point.x),\(point.y)) is outside the window frame \(describe(g.frame))")
        }
        let global = CGPoint(x: g.frame.x + point.x, y: g.frame.y + point.y)
        let f = WindowFrame(x: global.x, y: global.y, width: 1, height: 1)
        guard contained(f, in: g.display) else {
            throw AgentSpaceError("display_escape", "resolved point \(global) is outside the display bounds")
        }
        return global
    }

    static func perform(_ command: String, workspace: inout Workspace, options: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        try preValidate(command, options: options)
        switch command {
        case "observe": return try await observe(&workspace, options: options, store: store)
        case "target-window": return try await targetWindow(&workspace, options: options, store: store)
        default: break
        }
        let g = try await guarded(&workspace, store: store)
        let selector = try options.selector()
        let addressed = options["ref"] != nil || !selector.isEmpty
        if g.record.bundleIdentifier == "com.google.Chrome",
           (["click", "move", "drag"].contains(command) && options["x"] != nil || command == "scroll" && !addressed
             || ["type-text", "key"].contains(command) && !addressed) {
            let (tree, _) = AX.tree(g.window, depth: 16, limit: 2000)
            guard let web = tree.flattened.first(where: { $0.role == "AXWebArea" })?.frame else {
                throw AgentSpaceError("target_unavailable", "Chrome page viewport is not available")
            }
            let viewport = WindowFrame(x: web.x-g.frame.x, y: web.y-g.frame.y, width: web.width, height: web.height)
            return try await CDPBrowser.visual(command, workspace: workspace, options: options, viewport: viewport)
        }
        switch command {
        case "click": return try click(&workspace, options: options, g: g)
        case "move": return try move(&workspace, options: options, g: g)
        case "drag": return try drag(&workspace, options: options, g: g)
        case "scroll": return try await scroll(&workspace, options: options, g: g)
        case "type-text": return try await typeText(&workspace, options: options, g: g, store: store)
        case "key": return try await key(&workspace, options: options, g: g)
        default:
            throw AgentSpaceError("unsupported", "Command is not available on the virtual-display backend")
        }
    }

    // MARK: observe / target-window / screenshot

    private static func observe(_ workspace: inout Workspace, options: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        let g = try await guarded(&workspace, store: store)
        let depth = try options.integer("depth", default: 16, range: 0...30)
        let limit = try options.integer("max-nodes", default: 1000, range: 1...10000)
        let (tree, truncated) = AX.tree(g.window, depth: depth, limit: limit)
        let generation = (workspace.virtualDisplay?.observation?.generation ?? 0) + 1
        var elements: [ObservedElement] = []
        for node in tree.flattened where node.ref != "0" {
            guard elements.count < 5000 else { break }
            elements.append(ObservedElement(ref: node.ref, role: node.role, title: node.title,
                label: node.label, value: node.value, frame: node.frame, enabled: node.enabled))
        }
        workspace.virtualDisplay?.observation = VirtualDisplayObservation(generation: generation, elements: elements, at: Date())
        try store.save(workspace)
        var result: [String: JSONValue] = ["tree": try .encoded(tree), "truncated": .bool(truncated),
            "generation": .number(Double(generation)), "displayID": g.state.displayID.map { .number(Double($0)) } ?? .null]
        if options.has("screenshot") { result["screenshot"] = try await screenshot(&workspace, g: g, store: store) }
        return ("AXTree", .object(result))
    }

    private static func targetWindow(_ workspace: inout Workspace, options: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        let state = try await ensureHost(&workspace, store: store)
        guard let bounds = state.bounds else { throw AgentSpaceError("display_lost", "no display bounds recorded") }
        let owned = workspace.apps.filter { $0.owned && AX.isAlive($0) }
        guard !owned.isEmpty else { throw AgentSpaceError("app_unavailable", "No live workspace-owned app on this display") }
        var candidates: [(pid: pid_t, element: AXUIElement, index: Int, title: String, frame: WindowFrame)] = []
        for record in owned {
            if let raw = options["pid"], Int32(raw) != record.pid { continue }
            for (index, window) in AX.windows(record.pid).enumerated() {
                let title = AX.string(window, kAXTitleAttribute) ?? ""
                guard options["title"] == nil || title == options["title"] else { continue }
                guard let frame = AX.frame(window), contained(frame, in: bounds) else { continue }
                candidates.append((record.pid, window, index, title, frame))
            }
        }
        let index = try options.integer("index", default: 0, range: 0...10000)
        guard index < candidates.count else {
            throw AgentSpaceError("window_not_found",
                "No owned window wholly on the display at index \(index); \(candidates.count) candidates")
        }
        let chosen = candidates[index]
        workspace.target = WindowTarget(pid: chosen.pid, windowID: nil, title: chosen.title, index: chosen.index)
        try store.save(workspace)
        return ("AXWindows+display-bounds", .object(["target": try .encoded(workspace.target),
            "frame": try .encoded(chosen.frame), "candidates": .number(Double(candidates.count))]))
    }

    /// Window-only capture of the verified target window - never a full-display
    /// read - through the same ScreenCaptureKit path the AX backend uses.
    private static func screenshot(_ workspace: inout Workspace, g: Guarded, store: StateStore) async throws -> JSONValue {
        guard CGPreflightScreenCaptureAccess() else {
            throw AgentSpaceError("screen_capture_permission", "Screen Recording permission is required")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let matches = content.windows.filter { $0.owningApplication?.processID == g.record.pid && $0.windowLayer == 0 }
        let candidates = matches.map { CaptureCandidate(id: $0.windowID, title: $0.title, frame:
            WindowFrame(x: $0.frame.minX, y: $0.frame.minY, width: $0.frame.width, height: $0.frame.height)) }
        let id = try WindowMatcher.resolve(candidates, title: workspace.target?.title ?? "",
                                           frame: g.frame, previousID: workspace.target?.windowID)
        guard let window = matches.first(where: { $0.windowID == id }) else {
            throw AgentSpaceError("capture_window_not_found", "Target window disappeared")
        }
        let config = SCStreamConfiguration(); config.width = max(1, Int(window.frame.width)); config.height = max(1, Int(window.frame.height)); config.showsCursor = false
        let start = ContinuousClock.now
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
        let ms = Double(start.duration(to: .now).components.seconds) * 1000 + Double(start.duration(to: .now).components.attoseconds) / 1e15
        let path = try store.directory(workspace.name).appendingPathComponent("capture-\(UUID().uuidString).png")
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw AgentSpaceError("png_encoding", "Cannot encode screenshot")
        }
        try data.write(to: path, options: .atomic)
        workspace.target?.windowID = window.windowID
        try store.save(workspace)
        return .object(["path": .string(path.path), "latencyMs": .number(ms),
                        "windowID": .number(Double(window.windowID)), "method": .string("ScreenCaptureKit"),
                        "width": .number(Double(image.width)), "height": .number(Double(image.height))])
    }

    // MARK: Pointer actions

    private static func flags(_ modifiers: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        for modifier in modifiers {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        return flags
    }

    private static func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton,
                              modifiers: CGEventFlags, clickState: Int64 = 0, windowID: UInt32) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw AgentSpaceError("event_creation", "Cannot create \(type) event")
        }
        event.flags = modifiers
        try stampPointer(event, windowID: windowID)
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        return event
    }

    nonisolated static func stampPointer(_ event: CGEvent, windowID: UInt32) throws {
        guard windowID != 0 else { throw AgentSpaceError("target_unavailable", "No window identity for pointer input") }
        // Per-PID delivery bypasses the WindowServer's window attribution.
        event.setIntegerValueField(CGEventField(rawValue: 91)!, value: Int64(windowID))
        event.setIntegerValueField(CGEventField(rawValue: 92)!, value: Int64(windowID))
    }

    private static func pointerWindowID(_ g: Guarded) throws -> UInt32 {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates: [CaptureCandidate] = windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == g.record.pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: raw as CFDictionary) else { return nil }
            return CaptureCandidate(id: id, title: info[kCGWindowName as String] as? String,
                frame: WindowFrame(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height))
        }
        return try WindowMatcher.resolve(candidates, title: AX.string(g.window, kAXTitleAttribute) ?? "",
                                         frame: g.frame, previousID: nil)
    }

    private static func buttonPair(_ button: String) -> (down: CGEventType, up: CGEventType, drag: CGEventType, button: CGMouseButton) {
        switch button {
        case "right": return (.rightMouseDown, .rightMouseUp, .rightMouseDragged, .right)
        case "middle": return (.otherMouseDown, .otherMouseUp, .otherMouseDragged, .center)
        default: return (.leftMouseDown, .leftMouseUp, .leftMouseDragged, .left)
        }
    }

    /// Element centre → global point for element-addressed coordinate actions.
    private static func elementCenter(_ element: AXUIElement, in g: Guarded) throws -> CGPoint {
        guard let frame = AX.frame(element), contained(frame, in: g.display) else {
            throw AgentSpaceError("display_escape", "element frame is outside the display bounds")
        }
        return CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
    }

    private static func click(_ workspace: inout Workspace, options: CommandOptions, g: Guarded) throws -> (String, JSONValue) {
        let button = try options.button() ?? "left"
        let count = try options.clickCount() ?? 1
        let modifierNames = try options.modifierList()
        let modifiers = flags(modifierNames)
        let plain = options["button"] == nil && options["count"] == nil && modifierNames.isEmpty
        var result: [String: JSONValue] = [:]
        if let point = try options.point() {
            let global = try globalPoint(point, in: g)
            try dispatchClick(at: global, button: button, count: count, modifiers: modifiers, pid: g.record.pid, windowID: pointerWindowID(g))
            result["resolvedPoint"] = .object(["x": .number(point.x), "y": .number(point.y), "source": .string("coordinates")])
        } else {
            let element = try addressedElement(&workspace, options: options, root: g.window)
            guard let element else { throw AgentSpaceError("element_required", "Provide --ref, a selector or --x/--y") }
            if plain {
                var attempts: [JSONValue] = []
                for action in ["AXPress", "AXConfirm", "AXPick"] where AX.actions(element).contains(action) {
                    let status = AX.perform(element, action)
                    attempts.append(.object(["method": .string(action), "axError": .number(Double(status.rawValue))]))
                    if status == .success {
                        result["attempts"] = .array(attempts)
                        result["dispatched"] = .bool(true); result["verified"] = .bool(false)
                        return (action, .object(result))
                    }
                }
                // No AX press action - fall through to a coordinate click on the
                // element's own center rather than failing a dispatchable action.
            }
            let center = try elementCenter(element, in: g)
            try dispatchClick(at: center, button: button, count: count, modifiers: modifiers, pid: g.record.pid, windowID: pointerWindowID(g))
            result["resolvedPoint"] = .object(["x": .number(center.x - g.frame.x), "y": .number(center.y - g.frame.y), "source": .string("element-center")])
        }
        result["dispatched"] = .bool(true); result["verified"] = .bool(false)
        result["note"] = .string("per-pid events are dispatched, not guaranteed; observe to confirm the effect")
        return ("CGEvent.postToPid", .object(result))
    }

    private static func dispatchClick(at point: CGPoint, button: String, count: Int,
                                      modifiers: CGEventFlags, pid: pid_t, windowID: UInt32) throws {
        let pair = buttonPair(button)
        try mouse(.mouseMoved, at: point, button: pair.button, modifiers: modifiers, windowID: windowID).postToPid(pid)
        for click in 1...count {
            try mouse(pair.down, at: point, button: pair.button, modifiers: modifiers, clickState: Int64(click), windowID: windowID).postToPid(pid)
            try mouse(pair.up, at: point, button: pair.button, modifiers: modifiers, clickState: Int64(click), windowID: windowID).postToPid(pid)
        }
    }

    private static func move(_ workspace: inout Workspace, options: CommandOptions, g: Guarded) throws -> (String, JSONValue) {
        let modifiers = flags(try options.modifierList())
        let point: CGPoint
        var source = "coordinates"
        if let raw = try options.point() {
            point = try globalPoint(raw, in: g)
        } else {
            let element = try addressedElement(&workspace, options: options, root: g.window)
            guard let element else { throw AgentSpaceError("element_required", "move needs --x/--y, --ref or a selector") }
            point = try elementCenter(element, in: g)
            source = "element-center"
        }
        try mouse(.mouseMoved, at: point, button: .left, modifiers: modifiers, windowID: pointerWindowID(g)).postToPid(g.record.pid)
        return ("CGEvent.postToPid", .object(["dispatched": .bool(true), "verified": .bool(false),
            "resolvedPoint": .object(["x": .number(point.x - g.frame.x), "y": .number(point.y - g.frame.y), "source": .string(source)])]))
    }

    private static func drag(_ workspace: inout Workspace, options: CommandOptions, g: Guarded) throws -> (String, JSONValue) {
        let button = try options.button() ?? "left"
        let modifiers = flags(try options.modifierList())
        let from: CGPoint, to: CGPoint
        if let fromRef = options["from-ref"] {
            let a = try refElement(workspace, ref: fromRef, root: g.window).0
            let b = try refElement(workspace, ref: options["to-ref"]!, root: g.window).0
            from = try elementCenter(a, in: g); to = try elementCenter(b, in: g)
        } else {
            from = try globalPoint(try options.point()!, in: g)
            to = try globalPoint(try options.point("to-x", "to-y")!, in: g)
        }
        let pair = buttonPair(button)
        let windowID = try pointerWindowID(g)
        try mouse(.mouseMoved, at: from, button: pair.button, modifiers: modifiers, windowID: windowID).postToPid(g.record.pid)
        try mouse(pair.down, at: from, button: pair.button, modifiers: modifiers, clickState: 1, windowID: windowID).postToPid(g.record.pid)
        for step in 1...8 {
            let intermediate = CGPoint(x: from.x + (to.x - from.x) * Double(step) / 8,
                                       y: from.y + (to.y - from.y) * Double(step) / 8)
            try mouse(pair.drag, at: intermediate, button: pair.button, modifiers: modifiers, windowID: windowID).postToPid(g.record.pid)
        }
        try mouse(pair.up, at: to, button: pair.button, modifiers: modifiers, windowID: windowID).postToPid(g.record.pid)
        return ("CGEvent.postToPid", .object(["dispatched": .bool(true), "verified": .bool(false),
            "from": .object(["x": .number(from.x - g.frame.x), "y": .number(from.y - g.frame.y)]),
            "to": .object(["x": .number(to.x - g.frame.x), "y": .number(to.y - g.frame.y)]),
            "note": .string("per-pid drag is dispatched, not guaranteed; observe to confirm")]))
    }

    private static func scroll(_ workspace: inout Workspace, options: CommandOptions, g: Guarded) async throws -> (String, JSONValue) {
        let modifiers = flags(try options.modifierList())
        let (dx, dy, ticks) = try scrollDelta(options)
        let point: CGPoint
        var source = "window-center"
        if let raw = try options.point() {
            point = try globalPoint(raw, in: g); source = "coordinates"
        } else {
            let selector = try options.selector()
            if options["ref"] != nil || !selector.isEmpty {
                let element = try addressedElement(&workspace, options: options, root: g.window)
                if let element { point = try elementCenter(element, in: g); source = "element-center" }
                else { point = CGPoint(x: g.frame.x + g.frame.width / 2, y: g.frame.y + g.frame.height / 2) }
            } else {
                point = CGPoint(x: g.frame.x + g.frame.width / 2, y: g.frame.y + g.frame.height / 2)
            }
        }
        let windowID = try pointerWindowID(g)
        for _ in 0..<(ticks ?? 1) {
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                      wheel1: Int32(dy ?? 0), wheel2: Int32(dx ?? 0), wheel3: 0) else {
                throw AgentSpaceError("event_creation", "Cannot create scroll wheel event")
            }
            event.flags = modifiers
            event.location = point
            try stampPointer(event, windowID: windowID)
            event.postToPid(g.record.pid)
            try await Task.sleep(for: .milliseconds(25))
        }
        return ("CGEvent.postToPid", .object(["dispatched": .bool(true), "verified": .bool(false),
            "resolvedPoint": .object(["x": .number(point.x - g.frame.x), "y": .number(point.y - g.frame.y), "source": .string(source)]),
            "dx": dx.map { .number(Double($0)) } ?? .null, "dy": dy.map { .number(Double($0)) } ?? .null,
            "note": .string("per-pid scroll is dispatched, not guaranteed; observe to confirm")]))
    }

    nonisolated static func scrollDelta(_ options: CommandOptions) throws -> (dx: Int32?, dy: Int32?, ticks: Int?) {
        let rawDX = options["dx"], rawDY = options["dy"], rawTicks = options["ticks"]
        func delta(_ name: String, _ raw: String?) throws -> Int32? {
            guard let raw else { return nil }
            guard let value = Int32(raw), (-10_000...10_000).contains(value) else {
                throw AgentSpaceError("invalid_option", "--\(name) must be an integer from -10000 through 10000")
            }
            return value
        }
        if rawDX != nil || rawDY != nil || rawTicks != nil {
            guard options["direction"] == nil, options["amount"] == nil, options["unit"] == nil else {
                throw AgentSpaceError("invalid_option", "Use --dx/--dy/--ticks or --direction/--amount/--unit, not both")
            }
            let dx = try delta("dx", rawDX), dy = try delta("dy", rawDY)
            guard dx != nil || dy != nil else { throw AgentSpaceError("missing_option", "scroll needs --dx or --dy") }
            var ticks: Int? = 1
            if let rawTicks {
                guard let value = Int(rawTicks), (1...100).contains(value) else {
                    throw AgentSpaceError("invalid_option", "--ticks must be an integer from 1 through 100")
                }
                ticks = value
            }
            return (dx, dy, ticks)
        }
        let direction = options["direction"] ?? "down"
        guard ["up", "down", "left", "right"].contains(direction) else {
            throw AgentSpaceError("invalid_direction", "Direction must be up, down, left or right")
        }
        guard let amount = Double(options["amount"] ?? "0.8"), amount.isFinite, amount > 0, amount <= 100 else {
            throw AgentSpaceError("invalid_amount", "Amount must be positive and at most 100")
        }
        let unit = options["unit"] ?? "fraction"
        guard ["fraction", "pages"].contains(unit) else { throw AgentSpaceError("invalid_unit", "Unit must be fraction or pages") }
        let base = unit == "pages" ? 800.0 : 400.0
        let magnitude = Int32((amount * base).rounded())
        let horizontal = direction == "left" || direction == "right"
        let positive = direction == "up" || direction == "left"
        let signed = positive ? magnitude : -magnitude
        return (horizontal ? signed : nil, horizontal ? nil : signed, 1)
    }

    // MARK: Text + keys

    /// Addressed typing writes the element directly through AX value/range
    /// attributes with a matching read-back - it never clicks or activates the
    /// field to focus it first. Unaddressed typing goes to whatever the target
    /// process itself has focused; dispatched and honestly unverified.
    private static func typeText(_ workspace: inout Workspace, options: CommandOptions, g: Guarded, store: StateStore) async throws -> (String, JSONValue) {
        let text = try options.required("text")
        let selector = try options.selector()
        let addressed = options["ref"] != nil || !selector.isEmpty
        let element = try addressedElement(&workspace, options: options, root: g.window)
        if addressed {
            guard let element else { throw AgentSpaceError("element_required", "Provide --ref or a selector") }
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            guard writableRoles.contains(role) else {
                throw AgentSpaceError("element_not_writable",
                    "\(role) is not a writable text control; refusing to type into it "
                    + "(a focusing click is never sent)")
            }
            let old = AX.string(element, kAXValueAttribute)
            let desired: String
            if options.has("replace") { desired = text }
            else if let range = AX.value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
                var cf = CFRange()
                guard AXValueGetValue(unsafeDowncast(range, to: AXValue.self), .cfRange, &cf),
                      let inserted = TextVerification.insertion(original: old ?? "", text: text, location: cf.location, length: cf.length) else {
                    throw AgentSpaceError("unsupported", "Cannot compute the insertion from the element's selection range")
                }
                desired = inserted
            } else { desired = (old ?? "") + text }
            let status = AX.set(element, kAXValueAttribute, desired as CFString)
            try await Task.sleep(for: .milliseconds(180))
            let current = AX.string(element, kAXValueAttribute)
            guard status == .success, current == desired else {
                throw AgentSpaceError("unsupported",
                    "AX value write was not accepted or did not read back (status \(status.rawValue)); "
                    + "no keyboard or click fallback is attempted on an addressed element")
            }
            return ("AXValue.set", .object(["verified": .bool(true), "value": .string(String(desired.prefix(1000)))]))
        }
        guard !options.has("replace") else {
            throw AgentSpaceError("element_required", "--replace requires an addressed text element")
        }
        try await TargetedKeyboard.text(text, pid: g.record.pid)
        return ("postToPid", .object(["dispatched": .bool(true), "verified": .bool(false),
            "note": .string("typed to whatever the target process has focused; observe to confirm")]))
    }

    private static func key(_ workspace: inout Workspace, options: CommandOptions, g: Guarded) async throws -> (String, JSONValue) {
        let key = try options.required("key")
        let selector = try options.selector()
        if options["ref"] != nil || !selector.isEmpty {
            // The element is only verified to be a writable control - never
            // clicked or activated - then the key goes to the owning process.
            guard let element = try addressedElement(&workspace, options: options, root: g.window) else {
                throw AgentSpaceError("element_required", "Provide --ref or a selector")
            }
            let role = AX.string(element, kAXRoleAttribute) ?? ""
            guard writableRoles.contains(role) else {
                throw AgentSpaceError("element_not_writable", "\(role) is not a writable text control")
            }
        }
        try TargetedKeyboard.key(key, pid: g.record.pid)
        try await Task.sleep(for: .milliseconds(120))
        let parts = key.lowercased().split(separator: "+").map(String.init)
        var result: [String: JSONValue] = ["dispatched": .bool(true), "verified": .bool(false)]
        if !Set(parts.dropLast()).isDisjoint(with: ["cmd", "command", "ctrl", "control"]) {
            result["warning"] = .string("unverified_modifier_combo")
        }
        return ("postToPid", .object(result))
    }

    // MARK: Stop / status

    /// Teardown timing for `destroy` - injectable so the regression suite can
    /// exercise the same escalation path in seconds instead of the production
    /// bounds. Every bound still applies; only the durations shrink.
    public struct DestroyPolicy: Sendable {
        /// Deadline for the `shutdown` op itself.
        public var shutdownTimeout: TimeInterval
        /// Wait for the host to exit after a clean shutdown reply.
        public var shutdownGrace: TimeInterval
        /// Wait for exit after SIGTERM before escalating.
        public var termGrace: TimeInterval
        /// Wait for exit after SIGKILL before reporting the process stuck.
        public var killGrace: TimeInterval
        /// Liveness poll cadence inside each grace period.
        public var poll: TimeInterval
        public init(shutdownTimeout: TimeInterval = 8, shutdownGrace: TimeInterval = 3,
                    termGrace: TimeInterval = 2, killGrace: TimeInterval = 1,
                    poll: TimeInterval = 0.1) {
            self.shutdownTimeout = shutdownTimeout; self.shutdownGrace = shutdownGrace
            self.termGrace = termGrace; self.killGrace = killGrace; self.poll = poll
        }
        public static let standard = DestroyPolicy()
    }

    /// Release the display and end the host. The polite path is the `shutdown`
    /// op (which also destroys the display object); whatever its outcome, a
    /// host still alive under the recorded pid+start identity is then
    /// signalled SIGTERM, waited out, then SIGKILL - an unreachable helper is
    /// still OUR process and is never abandoned while it holds the display.
    /// Signals only ever fire after the identity check passes; a pid that
    /// fails it (reused, or never recorded) is never signalled. The session is
    /// claimed destroyed only once the process is provably gone - a host
    /// still alive, or a pid that now names a different process, keeps the
    /// state record so stop-workspace can retry or be inspected.
    public static func destroy(_ workspace: inout Workspace, store: StateStore,
                               policy: DestroyPolicy = .standard,
                               probe: DisplayHost.Probe = .system) async throws -> JSONValue {
        guard let state = workspace.virtualDisplay else {
            return .object(["sessionDestroyed": .bool(false), "reason": .string("no session")])
        }
        guard state.backend == .native else {
            throw AgentSpaceError("legacy_backend_state",
                "This workspace was created by a previous integration AgentSpace no longer "
                + "uses; there is nothing to destroy through AgentSpace. "
                + "`stop-workspace --abandon-session` drops only the local record")
        }
        let pid = state.hostPID ?? -1
        let start = state.hostStart
        let pollMillis = Int64(max(0.005, policy.poll) * 1000)
        var released: JSONValue = .null
        var shutdownError: String?
        var forced = false
        // 1. Polite shutdown while the recorded identity still names the host.
        if let socket = state.socketPath, let token = state.token,
           DisplayHost.alive(pid, start: start, probe: probe) {
            do {
                let timeout = policy.shutdownTimeout
                let reply = try await Task.detached { @Sendable () -> JSONValue in
                    try DisplayHost.call(socketPath: socket, token: token, op: "shutdown", timeout: timeout)
                }.value
                released = field(reply, "result")
                let until = ContinuousClock.now.advanced(by: .seconds(policy.shutdownGrace))
                while DisplayHost.alive(pid, start: start, probe: probe), ContinuousClock.now < until {
                    try await Task.sleep(for: .milliseconds(pollMillis))
                }
            } catch let error as AgentSpaceError {
                if ["host_unreachable", "host_io", "host_closed", "host_protocol", "host_timeout"].contains(error.code),
                   !DisplayHost.alive(pid, start: start, probe: probe) {
                    // It died between the liveness check and connect - the OS
                    // already released the display with the process.
                    released = .object(["released": .null, "note": .string("host exited before shutdown was answered")])
                } else {
                    // A live host that could not be served still gets the
                    // signal escalation below - unreachable is not a dead
                    // end, and the diagnostics ride along in the receipt.
                    shutdownError = "\(error.code): \(error.description)"
                }
            } catch {
                shutdownError = String(describing: error)
            }
        }
        // 2. Signal escalation, gated on the recorded pid+start identity only.
        if DisplayHost.alive(pid, start: start, probe: probe) {
            forced = true
            _ = DisplayHost.terminate(pid, start: start, signal: SIGTERM, probe: probe)
            let until = ContinuousClock.now.advanced(by: .seconds(policy.termGrace))
            while DisplayHost.alive(pid, start: start, probe: probe), ContinuousClock.now < until {
                try await Task.sleep(for: .milliseconds(pollMillis))
            }
            if DisplayHost.alive(pid, start: start, probe: probe) {
                _ = DisplayHost.terminate(pid, start: start, signal: SIGKILL, probe: probe)
                let until = ContinuousClock.now.advanced(by: .seconds(policy.killGrace))
                while DisplayHost.alive(pid, start: start, probe: probe), ContinuousClock.now < until {
                    try await Task.sleep(for: .milliseconds(pollMillis))
                }
            }
        }
        // 3. Never claim destroyed on a live process or an ambiguous identity.
        if DisplayHost.alive(pid, start: start, probe: probe) {
            throw AgentSpaceError("processes_remaining",
                "display host pid \(pid) is still alive after shutdown + signals; state kept")
        }
        if DisplayHost.canSignal(pid), probe.startTime(pid) != nil {
            throw AgentSpaceError("virtual_display_host_unreachable",
                "pid \(pid) now names a different process (start-time mismatch); refusing to "
                + "signal it — state kept for retry after manual inspection")
        }
        if released == .null {
            released = .object(["released": .bool(true), "note": .string(
                state.hostPID == nil ? "no host process was ever recorded"
                                     : "host already dead; display destroyed with it")])
        }
        workspace.virtualDisplay = nil
        try store.save(workspace)
        if let socket = state.socketPath {
            // The host is confirmed dead; its socket file is stale evidence,
            // ours to remove before the private directory is rmdir'd.
            unlink(socket)
            DisplayHost.cleanupSocketDirectory(URL(fileURLWithPath: socket).deletingLastPathComponent())
        }
        let sessionID = state.workspaceUUID ?? "unknown"
        return .object(["sessionDestroyed": .bool(true), "sessionID": .string(sessionID),
                        "displayReleased": released,
                        "shutdownError": shutdownError.map(JSONValue.string) ?? .null,
                        "forcedTermination": .bool(forced),
                        "teardownComplete": .bool(shutdownError == nil && !forced)])
    }

    /// `--abandon-session`: drop only AgentSpace's record, honestly. For a
    /// native host the recorded pid+start are echoed so the user can inspect or
    /// kill it themselves; for a legacy record nothing was ever contacted.
    public static func abandon(_ workspace: inout Workspace, store: StateStore) throws -> JSONValue {
        guard let state = workspace.virtualDisplay else {
            return .object(["sessionDestroyed": .null, "reason": .string("no session record")])
        }
        workspace.abandonedVirtualDisplay = state
        workspace.virtualDisplay = nil
        try store.save(workspace)
        if state.backend == .legacy {
            return .object([
                "sessionDestroyed": .null, "cleanupUnconfirmed": .bool(true),
                "legacy": .bool(true), "sessionID": state.legacySessionID.map(JSONValue.string) ?? .null,
                "note": .string("Legacy record dropped locally; AgentSpace never contacted "
                    + "anything external and does not know whether its session still exists")])
        }
        return .object([
            "sessionDestroyed": .null, "cleanupUnconfirmed": .bool(true),
            "hostPID": state.hostPID.map { .number(Double($0)) } ?? .null,
            "socketPath": state.socketPath.map(JSONValue.string) ?? .null,
            "note": .string("AgentSpace dropped its record; if pid \(state.hostPID ?? -1) is still "
                + "alive it may still hold the display — verify start time before signalling it")])
    }

    /// Live evidence for get-status; degrades to the persisted record when the
    /// host cannot be reached.
    static func sessionStatus(_ workspace: Workspace) async -> JSONValue {
        var result: [String: JSONValue] = [:]
        if let abandoned = workspace.abandonedVirtualDisplay {
            result["abandoned"] = (try? .encoded(abandoned)) ?? .null
        }
        guard let state = workspace.virtualDisplay else {
            return result.isEmpty ? .null : .object(result)
        }
        result["kind"] = .string(state.backend.rawValue)
        if state.backend == .legacy {
            result["legacy"] = .object(["sessionID": state.legacySessionID.map(JSONValue.string) ?? .null,
                "controllerID": state.legacyControllerID.map(JSONValue.string) ?? .null,
                "note": .string("pre-integration record; no action runs against it")])
            return .object(result)
        }
        result["record"] = .object(["hostPID": state.hostPID.map { .number(Double($0)) } ?? .null,
            "hostStart": state.hostStart.map { .number($0) } ?? .null,
            "displayID": state.displayID.map { .number(Double($0)) } ?? .null,
            "pendingCreate": .bool(state.pendingCreate)])
        let pid = state.hostPID ?? -1
        guard DisplayHost.alive(pid, start: state.hostStart) else {
            result["reachable"] = .bool(false)
            result["error"] = .string("host process dead or pid reused")
            return .object(result)
        }
        do {
            let reply = try await Task.detached { @Sendable () -> JSONValue in
                try DisplayHost.call(socketPath: state.socketPath!, token: state.token!,
                                     op: "status", fields: ["workspaceUUID": .string(state.workspaceUUID ?? "")], timeout: 5)
            }.value
            let display = field(reply, "display")
            let synthetic = field(display, "fake") == .bool(true)
            result["reachable"] = .bool(true)
            result["display"] = display
            // A host answering in fake-display mode is evidence of nothing but
            // a test fixture - never a live seat.
            result["synthetic"] = .bool(synthetic)
            result["present"] = .bool(uint32Field(display, "id") != nil && !synthetic)
        } catch {
            result["reachable"] = .bool(false)
            result["error"] = .string(String(describing: error))
        }
        return .object(result)
    }
}
