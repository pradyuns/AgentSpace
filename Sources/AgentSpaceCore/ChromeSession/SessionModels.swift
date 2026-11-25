import CryptoKit
import Foundation

public enum SessionMode: String, Codable, Sendable {
    /// The user's already-running Chrome reached through its opt-in
    /// DevToolsActivePort endpoint. Never signalled, never closed, its
    /// profile never deleted. Maps to `--chrome-session existing`.
    case shared = "existing"
    /// An AgentSpace-owned persistent-profile Chrome the broker itself
    /// launches headless and may relaunch headed for an explicit login
    /// handoff. Maps to `--chrome-session dedicated`.
    case dedicated = "dedicated"
}

/// Exact process identity: pid plus seconds-since-boot start time, so a
/// recycled pid can never be mistaken for the recorded process.
public struct ProcessIdentity: Codable, Equatable, Sendable {
    public var pid: Int32
    public var start: TimeInterval
    public init(pid: Int32, start: TimeInterval) { self.pid = pid; self.start = start }
}

/// One Chrome run, bound to its advertised endpoint: the DevToolsActivePort
/// websocket URL (port + browser GUID) plus the owning browser process's
/// pid+start. Any change means a different browser generation.
public struct BrowserIdentity: Codable, Equatable, Sendable {
    public var endpoint: String
    public var guid: String
    public var browser: ProcessIdentity
    public init(endpoint: String, guid: String, browser: ProcessIdentity) {
        self.endpoint = endpoint; self.guid = guid; self.browser = browser
    }
}

public enum TargetState: String, Codable, Sendable {
    case open, closing, closed, uncertain
}

/// One exact agent-created target. Ids enter the journal only from this
/// broker's own `Target.createTarget` receipt - never from `getTargets`.
public struct OwnedTarget: Codable, Equatable, Sendable {
    public var targetId: String
    public var alias: String
    public var createdAt: Date
    public var state: TargetState
    public var openerTargetId: String?
    public var generation: BrowserIdentity?
    public init(targetId: String, alias: String, openerTargetId: String? = nil) {
        self.targetId = targetId; self.alias = alias
        self.createdAt = Date(); self.state = .open; self.openerTargetId = openerTargetId
    }
}

public enum HandoffState: String, Codable, Sendable {
    /// Normal background operation; automation may run.
    case background
    /// The owned tab was activated for the human at their explicit request;
    /// all automation and sensitive observation pause.
    case awaitingHuman = "awaiting_human"
    /// Resume was requested while the owned tab is still foreground; the
    /// human must switch away first - AgentSpace never picks a user tab.
    case awaitingBackground = "awaiting_background"
}

public enum AccessState: String, Codable, Sendable {
    case loginRequired = "login_required"
    case accessible
    case unknown
}

/// Verified identity is independent of access state; a URL account slot or
/// host can never produce `.verified`.
public enum IdentityState: String, Codable, Sendable {
    case notRequired = "not_required"
    case verified, mismatch, unknown
}

/// The allowlisted access/identity verdict. `evidence` names evidence KINDS
/// only; the observed account string is compared in memory and discarded.
public struct AccessReport: Codable, Equatable, Sendable {
    public var access: AccessState
    public var identity: IdentityState
    public var identityMethod: String?
    public var evidence: [String]
    public var reason: String?
    public var at: Date
    public init(access: AccessState, identity: IdentityState, identityMethod: String? = nil,
                evidence: [String] = [], reason: String? = nil, at: Date = Date()) {
        self.access = access; self.identity = identity; self.identityMethod = identityMethod
        self.evidence = evidence; self.reason = reason; self.at = at
    }
}

public enum SessionOpenState: String, Codable, Sendable {
    case pending, creatingTarget, targetCreated, ready
}

public struct SessionRecord: Codable, Equatable, Sendable {
    public var session: String
    public var openRequestId: String
    public var site: String?
    /// Salted digest only; the plaintext account is digested at open and
    /// never stored.
    public var expectedAccountDigest: String?
    public var targets: [OwnedTarget]
    public var handoff: HandoffState
    public var createdAt: Date
    public var ended: Bool
    public var popupRejected: Int
    public var downloadsBlocked: Int
    public var downloadsSaved: [String]
    public var openState: SessionOpenState?
    public var cleanupReceipt: JSONValue?

    public init(session: String, openRequestId: String, site: String?,
                expectedAccountDigest: String?) {
        self.session = session; self.openRequestId = openRequestId; self.site = site
        self.expectedAccountDigest = expectedAccountDigest
        targets = []; handoff = .background; createdAt = Date(); ended = false
        popupRejected = 0; downloadsBlocked = 0; downloadsSaved = []
        openState = .pending
    }
}

/// One browser generation the journal has seen. `current` is the generation
/// target receipts are valid for; older entries are restart evidence whose
/// ids must never be closed (they may name user tabs or nothing at all).
public struct BrowserGeneration: Codable, Equatable, Sendable {
    public var identity: BrowserIdentity
    public var connectedAt: Date
    /// Dedicated mode: the broker launched and owns this process.
    public var ownedByBroker: Bool
    public var profileDir: String?
    public var gone: Bool
    public init(identity: BrowserIdentity, ownedByBroker: Bool, profileDir: String? = nil) {
        self.identity = identity; connectedAt = Date()
        self.ownedByBroker = ownedByBroker; self.profileDir = profileDir; gone = false
    }
}

public struct SessionJournal: Codable, Equatable, Sendable {
    public var brokerKey: String
    public var mode: SessionMode
    public var chromeRoot: String
    public var generation: BrowserGeneration?
    public var staleGenerations: [BrowserGeneration]
    public var sessions: [String: SessionRecord]
    /// How many broker processes have owned this journal.
    public var brokerBoots: Int
    /// Dedicated mode: the persistent profile directory (never deleted).
    public var profileDir: String?
    public init(brokerKey: String, mode: SessionMode, chromeRoot: String, profileDir: String? = nil) {
        self.brokerKey = brokerKey; self.mode = mode; self.chromeRoot = chromeRoot
        generation = nil; staleGenerations = []; sessions = [:]; brokerBoots = 0
        self.profileDir = profileDir
    }
}

/// The only record a workspace holds: which broker owns the session and the
/// opaque session id. Socket path and token are re-derived from brokerKey
/// under the state root; the broker's live pid+start are re-verified on
/// every call, so a recycled pid can never be talked to by accident.
public struct ChromeSessionRef: Codable, Equatable, Sendable {
    public var session: String
    public var brokerKey: String
    public var brokerPID: Int32
    public var brokerStart: TimeInterval
    public var mode: String
    public var site: String?
    public var expectedAccountDigest: String?
    public var createdAt: Date
    public var opening: Bool?
    public init(session: String, brokerKey: String, brokerPID: Int32, brokerStart: TimeInterval,
                mode: String, site: String?, expectedAccountDigest: String?, createdAt: Date = Date()) {
        self.session = session; self.brokerKey = brokerKey
        self.brokerPID = brokerPID; self.brokerStart = brokerStart
        self.mode = mode; self.site = site
        self.expectedAccountDigest = expectedAccountDigest; self.createdAt = createdAt
    }
}

/// `broker.json` inside the broker's private state directory: the record a
/// client validates before it trusts the socket.
public struct BrokerRecord: Codable, Equatable, Sendable {
    public var brokerKey: String
    public var mode: SessionMode
    public var pid: Int32
    public var start: TimeInterval
    public var socketPath: String
    public var chromeRoot: String
    public var createdAt: Date
    public init(brokerKey: String, mode: SessionMode, pid: Int32, start: TimeInterval,
                socketPath: String, chromeRoot: String) {
        self.brokerKey = brokerKey; self.mode = mode; self.pid = pid; self.start = start
        self.socketPath = socketPath; self.chromeRoot = chromeRoot; createdAt = Date()
    }
}

public enum SessionBroker {
    static func keyHash(_ material: String) -> String {
        String(SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// One broker per Chrome instance. Shared mode keys on the canonical
    /// user-data root plus the browser GUID (a restarted Chrome is a
    /// different broker); dedicated mode keys on the AgentSpace-owned
    /// profile root only, because the broker manages that profile's browser
    /// generations itself.
    public static func brokerKey(mode: SessionMode, chromeRoot: String, guid: String? = nil) -> String {
        switch mode {
        case .shared: return "sb-" + keyHash("shared|\(chromeRoot)|\(guid ?? "")")
        case .dedicated: return "sb-" + keyHash("dedicated|\(chromeRoot)")
        }
    }

    /// Salted account digest: the only persisted form of --expected-account.
    public static func accountDigest(_ account: String, salt: String) -> String {
        keyHash("account|\(salt)|\(AccountConstraint.normalize(account))")
    }

    /// The canonical Chrome user-data root used for shared sessions.
    /// AGENTSPACE_CHROME_USER_DIR overrides it for isolated fixture runs.
    public static func sharedChromeRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["AGENTSPACE_CHROME_USER_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Root holding AgentSpace-owned dedicated profiles; NAME is validated
    /// like a workspace name and resolved under this root - an arbitrary
    /// user profile directory is never accepted.
    public static func dedicatedProfilesRoot(_ store: StateStore) -> URL {
        store.root.appendingPathComponent("chrome-profiles", isDirectory: true)
    }

    public static func dedicatedProfileDir(_ store: StateStore, name: String) throws -> URL {
        try StateStore.validate(name)
        return dedicatedProfilesRoot(store).appendingPathComponent(name, isDirectory: true)
    }

    /// Broker state directory under the state root (journal, token, record).
    public static func brokerDirectory(_ store: StateStore, key: String) -> URL {
        store.root.appendingPathComponent("session-brokers/\(key)", isDirectory: true)
    }

    /// Short private socket path, under the same per-user parent the display
    /// host uses so deep state roots cannot overflow sockaddr_un.
    public static func socketPath(for key: String, stateRoot: URL? = nil) throws -> String {
        let parent = try DisplayHost.socketParent()
        let namespace = stateRoot.map { "-" + keyHash($0.standardizedFileURL.resolvingSymlinksInPath().path) } ?? ""
        let dir = parent.appendingPathComponent("sb-\(key)\(namespace)", isDirectory: true)
        try DisplayHost.ensurePrivateDirectory(dir)
        let path = dir.appendingPathComponent("sb.sock").path
        guard path.utf8.count < 104 else {
            throw AgentSpaceError("socket_path_too_long", "derived session broker socket path exceeds 104 bytes")
        }
        return path
    }

    /// The locate rule mirrors DisplayHost: sibling binary next to
    /// `agentspace`, or an explicit AGENTSPACE_SESSION_BROKER override.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let explicit = environment["AGENTSPACE_SESSION_BROKER"], !explicit.isEmpty {
            let url = URL(fileURLWithPath: explicit).resolvingSymlinksInPath()
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        var executable = Bundle.main.executableURL
        if executable == nil {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 2)
            var size = UInt32(buffer.count)
            if _NSGetExecutablePath(&buffer, &size) != 0 {
                buffer = [CChar](repeating: 0, count: Int(size))
                guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
            }
            executable = URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        guard let binary = executable?.resolvingSymlinksInPath() else { return nil }
        let sibling = binary.deletingLastPathComponent().appendingPathComponent("agentspace-session-broker")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }
}

/// Expected-account constraint handling: plaintext exists only inside a
/// request/option; everything stored or compared is a salted digest.
public enum AccountConstraint {
    /// Lowercased, trimmed; gmail-style sites additionally drop localpart
    /// dots and +tags, which is documented and deterministic.
    public static func normalize(_ account: String) -> String {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = trimmed.firstIndex(of: "@") else { return trimmed }
        var local = String(trimmed[..<at])
        let rawDomain = String(trimmed[trimmed.index(after: at)...])
        let domain = rawDomain == "googlemail.com" ? "gmail.com" : rawDomain
        if domain == "gmail.com" || domain == "googlemail.com" {
            local = local.replacingOccurrences(of: ".", with: "")
            if let plus = local.firstIndex(of: "+") { local = String(local[..<plus]) }
        }
        return local + "@" + domain
    }
}
