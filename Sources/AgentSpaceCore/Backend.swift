import Foundation

public enum BackendKind: String, Codable, Sendable, CaseIterable {
    case ax = "ax"
    case cdp = "cdp"
    case virtualDisplay = "virtual-display"
}

public enum InteractionMode: String, Codable, Sendable, CaseIterable {
    case semantic = "semantic"
    case visual = "visual"
}

/// The routing outcome persisted on a workspace at first launch: what the caller asked for,
/// what was selected before any effect ran, and why.
public struct RoutingDecision: Codable, Equatable, Sendable {
    public var requestedBackend: String
    public var requestedInteraction: String
    public var resolvedBackend: String
    public var resolvedInteraction: String
    public var reason: String
    public init(requestedBackend: String, requestedInteraction: String, resolvedBackend: String, resolvedInteraction: String, reason: String) {
        self.requestedBackend = requestedBackend; self.requestedInteraction = requestedInteraction
        self.resolvedBackend = resolvedBackend; self.resolvedInteraction = resolvedInteraction; self.reason = reason
    }
}

/// One element from the last `observe` a virtual-display workspace returned, kept so a later
/// `--ref` resolves against the snapshot the caller actually saw - never a silently fresher one.
/// The ref is a live AX tree path; a mutation re-resolves it and requires role/title/frame to
/// match this record before any event is dispatched.
public struct ObservedElement: Codable, Equatable, Sendable {
    public var ref: String
    public var role: String
    public var title: String?
    public var label: String?
    public var value: String?
    public var frame: WindowFrame?
    public var enabled: Bool?
    public init(ref: String, role: String, title: String? = nil, label: String? = nil,
                value: String? = nil, frame: WindowFrame? = nil, enabled: Bool? = nil) {
        self.ref = ref; self.role = role; self.title = title
        self.label = label; self.value = value; self.frame = frame; self.enabled = enabled
    }
}

/// The observation a `--ref` pins to: our own monotonically increasing generation plus the
/// element list it belonged to. A later read bumps the generation; `--ref` still works on the
/// pinned list but identity is re-verified against live AX before dispatch.
public struct VirtualDisplayObservation: Codable, Equatable, Sendable {
    public var generation: Int
    public var elements: [ObservedElement]
    public var at: Date
    public init(generation: Int, elements: [ObservedElement], at: Date) {
        self.generation = generation; self.elements = elements; self.at = at
    }
}

/// Which virtual-display implementation a workspace record belongs to. "native" is
/// AgentSpace's own display host; "legacy" marks a record written by the removed external
/// integration - it is decodeable so it can be reported and abandoned, but no action will
/// ever run against it.
public enum VirtualDisplayBackend: String, Codable, Sendable {
    case native = "native"
    case legacy = "legacy"
}

/// Ownership record for AgentSpace's own display host behind a virtual-display workspace.
/// hostPID + hostStart identify the helper process without pid-reuse confusion; the random
/// session token authenticates every request on its 0600 unix socket.
public struct VirtualDisplayState: Codable, Equatable, Sendable {
    public var backend: VirtualDisplayBackend
    // Native fields.
    public var hostPID: Int32?
    public var hostStart: TimeInterval?
    public var socketPath: String?
    public var token: String?
    public var workspaceUUID: String?
    public var displayID: UInt32?
    public var bounds: WindowFrame?
    public var preset: String?
    public var createdAt: Date?
    /// True while the helper was spawned but its handshake never confirmed - a later
    /// command re-checks liveness and either attaches to the same host or fails honestly.
    public var pendingCreate: Bool
    /// The last `observe` generation/element set that `--ref` values address.
    public var observation: VirtualDisplayObservation?
    // Legacy echo (old external record): kept verbatim only so status/abandon can describe it.
    public var legacySessionID: String?
    public var legacyControllerID: String?
    public var legacyExecutablePath: String?

    public init(hostPID: Int32?, hostStart: TimeInterval?, socketPath: String, token: String,
                workspaceUUID: String, displayID: UInt32?, bounds: WindowFrame?, preset: String?) {
        backend = .native
        self.hostPID = hostPID; self.hostStart = hostStart; self.socketPath = socketPath
        self.token = token; self.workspaceUUID = workspaceUUID; self.displayID = displayID
        self.bounds = bounds; self.preset = preset; createdAt = Date(); pendingCreate = false
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Old records carry the external session contract; a missing "kind" plus a sessionID
        // identifies them so they can be refused and abandoned - never acted on.
        let kind = try c.decodeIfPresent(String.self, forKey: .backend)
            ?? (c.contains(.sessionID) ? "legacy" : "native")
        backend = VirtualDisplayBackend(rawValue: kind) ?? .legacy
        hostPID = try c.decodeIfPresent(Int32.self, forKey: .hostPID)
        hostStart = try c.decodeIfPresent(TimeInterval.self, forKey: .hostStart)
        socketPath = try c.decodeIfPresent(String.self, forKey: .socketPath)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        workspaceUUID = try c.decodeIfPresent(String.self, forKey: .workspaceUUID)
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID)
        bounds = try c.decodeIfPresent(WindowFrame.self, forKey: .bounds)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        pendingCreate = try c.decodeIfPresent(Bool.self, forKey: .pendingCreate) ?? false
        observation = try c.decodeIfPresent(VirtualDisplayObservation.self, forKey: .observation)
        legacySessionID = try c.decodeIfPresent(String.self, forKey: .legacySessionID)
            ?? c.decodeIfPresent(String.self, forKey: .sessionID)
        legacyControllerID = try c.decodeIfPresent(String.self, forKey: .legacyControllerID)
            ?? c.decodeIfPresent(String.self, forKey: .controllerID)
        legacyExecutablePath = try c.decodeIfPresent(String.self, forKey: .legacyExecutablePath)
            ?? c.decodeIfPresent(String.self, forKey: .executablePath)
        if backend == .native {
            guard socketPath != nil, token != nil else {
                throw DecodingError.dataCorruptedError(forKey: .socketPath, in: c,
                    debugDescription: "native virtual-display state needs socketPath/token")
            }
            if pendingCreate {
                // A pending record may legitimately have no pid yet (spawn was
                // interrupted before launch). A placeholder pid that could
                // never name a process (<=1) or an identity missing its start
                // is unusable - normalize to nil rather than corrupt state.
                if let pid = hostPID {
                    if pid <= 1 || hostStart == nil || !hostStart!.isFinite || hostStart! <= 0 {
                        hostPID = nil; hostStart = nil
                    }
                }
            } else {
                guard let pid = hostPID, pid > 1,
                      let start = hostStart, start.isFinite, start > 0 else {
                    throw DecodingError.dataCorruptedError(forKey: .hostPID, in: c,
                        debugDescription: "established native state needs hostPID>1 and a valid hostStart")
                }
            }
        }
    }

    /// New records encode only their own shape; the legacy-key cases exist for decoding only.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(backend, forKey: .backend)
        try c.encodeIfPresent(hostPID, forKey: .hostPID)
        try c.encodeIfPresent(hostStart, forKey: .hostStart)
        try c.encodeIfPresent(socketPath, forKey: .socketPath)
        try c.encodeIfPresent(token, forKey: .token)
        try c.encodeIfPresent(workspaceUUID, forKey: .workspaceUUID)
        try c.encodeIfPresent(displayID, forKey: .displayID)
        try c.encodeIfPresent(bounds, forKey: .bounds)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(pendingCreate, forKey: .pendingCreate)
        try c.encodeIfPresent(observation, forKey: .observation)
        try c.encodeIfPresent(legacySessionID, forKey: .legacySessionID)
        try c.encodeIfPresent(legacyControllerID, forKey: .legacyControllerID)
        try c.encodeIfPresent(legacyExecutablePath, forKey: .legacyExecutablePath)
    }

    private enum CodingKeys: String, CodingKey {
        case backend, hostPID, hostStart, socketPath, token, workspaceUUID, displayID, bounds
        case preset, createdAt, pendingCreate, observation
        case legacySessionID, legacyControllerID, legacyExecutablePath
        case sessionID, controllerID, executablePath
    }
}

public struct RoutingRequest: Equatable, Sendable {
    public var backend: String?
    public var interaction: String?
    public init(backend: String? = nil, interaction: String? = nil) {
        self.backend = backend; self.interaction = interaction
    }
}

public enum BackendRouter {
    public static let backends: Set<String> = ["auto", "ax", "cdp", "virtual-display"]
    public static let interactions: Set<String> = ["semantic", "visual"]

    /// Validate only; resolution needs the launched app. Values are normalized to lowercase.
    public static func request(backend: String?, interaction: String?) throws -> RoutingRequest {
        let backendValue = backend?.lowercased()
        if let backendValue, !backends.contains(backendValue) {
            throw AgentSpaceError("invalid_option", "--backend must be auto, ax, cdp or virtual-display")
        }
        let interactionValue = interaction?.lowercased()
        if let interactionValue, !interactions.contains(interactionValue) {
            throw AgentSpaceError("invalid_option", "--interaction must be semantic or visual")
        }
        return RoutingRequest(backend: backendValue, interaction: interactionValue)
    }
    public static func request(_ options: CommandOptions) throws -> RoutingRequest {
        try request(backend: options["backend"], interaction: options["interaction"])
    }

    /// Resolve a request against the app being launched. Runs before any effect; an invalid
    /// combination is a usage error, never a fallback.
    public static func resolve(request: RoutingRequest, app: String) throws -> RoutingDecision {
        let backend = request.backend ?? "auto"
        let interaction = request.interaction
        let resolved: BackendKind
        let mode: InteractionMode
        let reason: String
        switch backend {
        case "auto":
            mode = interaction == "visual" ? .visual : .semantic
            if mode == .visual {
                resolved = .virtualDisplay
                reason = "auto: visual interaction requires a private display seat"
            } else if app == "chrome" {
                resolved = .cdp
                reason = "auto: chrome uses headless CDP"
            } else {
                resolved = .ax
                reason = "auto: native apps use Accessibility"
            }
        case "virtual-display":
            resolved = .virtualDisplay
            // An explicit private-display request defaults to the coordinate-capable contract;
            // --interaction semantic keeps element addressing only.
            mode = interaction == "semantic" ? .semantic : .visual
            reason = interaction == nil
                ? "requested: virtual-display (interaction defaults to visual)"
                : "requested: virtual-display"
        case "cdp":
            guard app == "chrome" else { throw AgentSpaceError("invalid_option", "--backend cdp applies to chrome only") }
            guard interaction != "visual" else { throw AgentSpaceError("invalid_option", "cdp cannot deliver coordinate input; relaunch with --backend virtual-display") }
            resolved = .cdp; mode = .semantic; reason = "requested: cdp"
        case "ax":
            guard interaction != "visual" else { throw AgentSpaceError("invalid_option", "ax cannot deliver coordinate input; relaunch with --backend virtual-display") }
            resolved = .ax; mode = .semantic; reason = "requested: ax"
        default:
            throw AgentSpaceError("invalid_option", "--backend must be auto, ax, cdp or virtual-display")
        }
        return RoutingDecision(requestedBackend: backend, requestedInteraction: interaction ?? mode.rawValue,
                               resolvedBackend: resolved.rawValue, resolvedInteraction: mode.rawValue, reason: reason)
    }

    /// Options that declare pointer-seat intent (coordinates, buttons, wheel deltas). Any one of
    /// them, or the pointer commands themselves, requires a visual-mode workspace.
    public static let pointerOptions: Set<String> = ["x", "y", "to-x", "to-y", "dx", "dy", "ticks", "button", "count", "modifiers"]
    public static let pointerCommands: Set<String> = ["move", "drag"]
    public static func requiresVisual(command: String, options: CommandOptions) -> Bool {
        if pointerCommands.contains(command) { return true }
        return options.values.keys.contains { pointerOptions.contains($0) }
    }

    /// What a resolved workspace can deliver. Surfaced by get-status so a caller can plan
    /// instead of probing commands.
    public static func capabilities(backend: BackendKind, interaction: InteractionMode) -> JSONValue {
        let coordinate = backend == .virtualDisplay && interaction == .visual
        switch backend {
        case .ax:
            return .object(["observe": .string("AXTree"), "screenshot": .string("ScreenCaptureKit"), "click": .string("element"),
                            "typeText": .bool(true), "key": .string("postToPid"), "scroll": .string("AXScrollBar"),
                            "coordinate": .bool(false), "hover": .bool(false), "drag": .bool(false),
                            "rightClick": .bool(false), "doubleClick": .bool(false)])
        case .cdp:
            return .object(["observe": .string("DOMAXTree"), "screenshot": .string("Page.captureScreenshot"), "click": .string("element"),
                            "typeText": .bool(true), "key": .string("limited"), "scroll": .string("dom"),
                            "coordinate": .bool(false), "hover": .bool(false), "drag": .bool(false),
                            "rightClick": .bool(false), "doubleClick": .bool(false)])
        case .virtualDisplay:
            return .object(["observe": .string("AXTree"), "screenshot": .string("ScreenCaptureKit"),
                            "click": .string(coordinate ? "element+coordinate" : "element"),
                            "typeText": .bool(true), "key": .string("Chrome CDP Input / native postToPid"), "scroll": .string(coordinate ? "Chrome CDP Input / native scrollWheel" : "AXScrollBar"),
                            "coordinate": .bool(coordinate), "hover": .bool(coordinate), "drag": .bool(coordinate),
                            "rightClick": .bool(coordinate), "doubleClick": .bool(coordinate)])
        }
    }
}

/// The shared command/option contract for the CLI and the MCP server. One table keeps the two
/// front ends identical: `commands` is the tool/command list, `allowed` the per-command options,
/// `flags` the boolean options, and `common` the options every command accepts.
public enum AgentSpaceCommands {
    public static let commands: Set<String> = ["prepare", "create-workspace", "launch-app", "target-window", "observe",
        "click", "type-text", "key", "scroll", "move", "drag", "self-test", "get-status", "stop-workspace", "list-workspaces"]
    public static let common: Set<String> = ["workspace"]
    public static let selectors: Set<String> = ["ref", "role", "title", "label", "value-contains", "index"]
    public static let allowed: [String: Set<String>] = [
        "prepare": ["url", "file", "restore-focus", "chrome-launch-strategy", "backend", "interaction"],
        "create-workspace": ["backend", "interaction"],
        "launch-app": ["app", "url", "file", "format", "restore-focus", "chrome-launch-strategy", "backend", "interaction", "preset"],
        "target-window": ["pid", "title", "index", "window"],
        "observe": ["screenshot", "depth", "max-nodes"],
        "click": selectors.union(["x", "y", "button", "count", "modifiers"]),
        "type-text": selectors.union(["text", "replace"]),
        "key": selectors.union(["key"]),
        "scroll": selectors.union(["direction", "amount", "unit", "x", "y", "dx", "dy", "ticks"]),
        "move": selectors.union(["x", "y", "modifiers"]),
        "drag": ["x", "y", "to-x", "to-y", "from-ref", "to-ref", "button", "modifiers"],
        "self-test": [],
        "stop-workspace": ["abandon-session"],
    ]
    public static let flags: Set<String> = ["screenshot", "restore-focus", "replace", "abandon-session"]
}

extension CommandOptions {
    /// A validated coordinate pair. Both axes are required together; bounds match window-local
    /// points on any display a session can occupy.
    public func point(_ xName: String = "x", _ yName: String = "y") throws -> (x: Double, y: Double)? {
        let supplied = [xName, yName].filter { values[$0] != nil }
        guard !supplied.isEmpty else { return nil }
        guard supplied.count == 2 else { throw AgentSpaceError("invalid_option", "--\(xName) and --\(yName) must be given together") }
        func coordinate(_ name: String) throws -> Double {
            guard let raw = values[name], let value = Double(raw), value.isFinite, (0...32767).contains(value) else {
                throw AgentSpaceError("invalid_option", "--\(name) must be a finite coordinate from 0 through 32767")
            }
            return value
        }
        return (try coordinate(xName), try coordinate(yName))
    }
    public func button() throws -> String? {
        guard let raw = self["button"] else { return nil }
        guard ["left", "right", "middle"].contains(raw) else {
            throw AgentSpaceError("invalid_option", "--button must be left, right or middle")
        }
        return raw
    }
    public func clickCount() throws -> Int? {
        guard self["count"] != nil else { return nil }
        return try integer("count", default: 1, range: 1...4)
    }
    public func modifierList() throws -> [String] {
        guard let raw = self["modifiers"] else { return [] }
        let names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let known: Set<String> = ["cmd", "command", "shift", "alt", "option", "opt", "ctrl", "control", "fn"]
        guard !names.isEmpty, names.allSatisfy(known.contains) else {
            throw AgentSpaceError("invalid_option", "--modifiers accepts a comma list of cmd, shift, alt, ctrl, fn")
        }
        return names
    }
}
