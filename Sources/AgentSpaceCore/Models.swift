import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

/// JSONValue field accessors shared by every target that speaks the wire
/// protocol (core, display host, eval).
public func field(_ value: JSONValue, _ key: String) -> JSONValue {
    if case .object(let object) = value { return object[key] ?? .null }
    return .null
}
public func stringField(_ value: JSONValue, _ key: String) -> String? {
    if case .string(let text) = field(value, key) { return text }
    return nil
}
public func numberField(_ value: JSONValue, _ key: String) -> Double? {
    if case .number(let number) = field(value, key) { return number }
    return nil
}
public func arrayField(_ value: JSONValue, _ key: String) -> [JSONValue] {
    if case .array(let array) = field(value, key) { return array }
    return []
}
/// Numeric wire fields convert through `exactly:` so a fractional, negative, overflowing or
/// non-integral value yields nil instead of trapping on `Int32(x)`/`UInt32(x)`.
public func int32Field(_ value: JSONValue, _ key: String) -> Int32? {
    numberField(value, key).flatMap { Int32(exactly: $0) }
}
public func uint32Field(_ value: JSONValue, _ key: String) -> UInt32? {
    numberField(value, key).flatMap { UInt32(exactly: $0) }
}

public struct AgentSpaceError: Error, CustomStringConvertible, Sendable {
    public let code: String
    public let description: String
    public let details: JSONValue?
    public init(_ code: String, _ description: String, details: JSONValue? = nil) {
        self.code = code; self.description = description; self.details = details
    }
}

public struct ElementRef: Equatable, Sendable {
    public let indices: [Int]
    public init(_ text: String) throws {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.first == "0", parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              parts.allSatisfy({ Int($0) != nil }) else {
            throw AgentSpaceError("invalid_ref", "Ref must start with 0 and contain nonnegative child indices, e.g. 0.3.1")
        }
        indices = try parts.dropFirst().map {
            guard let n = Int($0), n >= 0 else { throw AgentSpaceError("invalid_ref", "Invalid child index") }
            return n
        }
    }
}

public struct ElementNode: Codable, Equatable, Sendable {
    public var ref: String
    public var role: String
    public var subrole: String?
    public var title: String?
    public var label: String?
    public var value: String?
    public var frame: WindowFrame?
    public var enabled: Bool?
    public var actions: [String]
    public var children: [ElementNode]

    public init(ref: String, role: String, subrole: String? = nil, title: String? = nil,
                label: String? = nil, value: String? = nil, frame: WindowFrame? = nil,
                enabled: Bool? = nil, actions: [String] = [], children: [ElementNode] = []) {
        self.ref = ref; self.role = role; self.subrole = subrole; self.title = title
        self.label = label; self.value = value; self.frame = frame; self.enabled = enabled
        self.actions = actions; self.children = children
    }
    public var flattened: [ElementNode] { [self] + children.flatMap(\.flattened) }
}

public struct Selector: Sendable {
    public var role: String?
    public var title: String?
    public var label: String?
    public var valueContains: String?
    public var index: Int?
    public init(role: String? = nil, title: String? = nil, label: String? = nil,
                valueContains: String? = nil, index: Int? = nil) {
        self.role = role; self.title = title; self.label = label
        self.valueContains = valueContains; self.index = index
    }
    public var isEmpty: Bool { role == nil && title == nil && label == nil && valueContains == nil && index == nil }
    public func matches(_ node: ElementNode) -> Bool {
        (role == nil || node.role == role) && (title == nil || node.title == title)
        && (label == nil || node.label == label)
        && (valueContains == nil || node.value?.contains(valueContains!) == true)
    }
    public func resolve(in root: ElementNode) throws -> ElementNode {
        let matches = root.flattened.filter { self.matches($0) }
        if let index {
            guard index >= 0, index < matches.count else { throw AgentSpaceError("element_not_found", "Selector index out of range; \(matches.count) matches") }
            return matches[index]
        }
        guard matches.count == 1 else {
            throw AgentSpaceError(matches.isEmpty ? "element_not_found" : "ambiguous_selector", "Selector matched \(matches.count) elements; use --index (zero-based) or a more specific selector")
        }
        return matches[0]
    }
}

public struct WindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
}

public struct AppRecord: Codable, Equatable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String
    public var launchDate: Date?
    public var owned: Bool
    public var kind: String
}

public struct WindowTarget: Codable, Equatable, Sendable {
    public var pid: Int32
    public var windowID: UInt32?
    public var title: String
    public var index: Int
}

public struct Workspace: Codable, Equatable, Sendable {
    public var name: String
    public var createdAt: Date
    public var temporaryDirectory: String
    public var apps: [AppRecord]
    public var target: WindowTarget?
    public var stopped: Bool
    /// Backend/interaction requested at create time; resolved and pinned at first launch.
    public var requestedBackend: String?
    public var requestedInteraction: String?
    /// The resolved backend this workspace's actions route through. Optional so workspaces
    /// written before backend routing decode unchanged; nil resolves by inference.
    public var backend: String?
    public var interaction: String?
    public var routing: RoutingDecision?
    /// The external private-display session owned by a virtual-display workspace.
    public var virtualDisplay: VirtualDisplayState?
    /// Set by `stop-workspace --abandon-session`: the session record AgentSpace gave up on
    /// reaching. Presence means the session may still exist - it is never claimed destroyed.
    public var abandonedVirtualDisplay: VirtualDisplayState?
    /// Opt-in Chrome session reference: session id + broker identity only.
    /// Target ids, credentials and page content live exclusively in the
    /// session broker's journal - never in the workspace.
    public var chromeSession: ChromeSessionRef?
    /// `stop-workspace --abandon-session` echo of a dropped chrome session.
    public var abandonedChromeSession: ChromeSessionRef?
    public init(name: String, temporaryDirectory: String) {
        self.name=name; self.temporaryDirectory=temporaryDirectory; createdAt=Date()
        apps=[]; target=nil; stopped=false
    }
    public var backendKind: BackendKind? { backend.flatMap(BackendKind.init(rawValue:)) }
    public var interactionMode: InteractionMode { interaction.flatMap(InteractionMode.init(rawValue:)) ?? .semantic }
}

public struct Frontmost: Codable, Equatable, Sendable {
    public var pid: Int32
    public var bundleIdentifier: String?
    public var name: String?
}
public struct CursorPoint: Codable, Equatable, Sendable { public var x: Double; public var y: Double }
public struct FocusSnapshot: Codable, Equatable, Sendable {
    public var frontmost: Frontmost?
    public var cursor: CursorPoint
    public var axFocusedAppPID: Int32?
    public var axFocusedElementRole: String?
}

public struct ActionLog: Codable, Sendable {
    public var timestamp: Date
    public var action: String
    public var method: String
    public var latencyMs: Double
    public var result: JSONValue
    public var before: FocusSnapshot
    public var after: FocusSnapshot
    public var focusChanged: Bool { before.frontmost?.pid != after.frontmost?.pid }
    public var cursorMoved: Bool { before.cursor != after.cursor }
}
