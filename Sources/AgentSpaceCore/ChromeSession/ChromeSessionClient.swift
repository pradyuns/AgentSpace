import AppKit
import Foundation

public enum ChromeSession {
    /// Validate the whole --chrome-session option set BEFORE any effect:
    /// unknown combos are usage errors, never silent fallbacks.
    public static func validateLaunch(_ o: CommandOptions) throws -> SessionMode {
        guard let raw = o["chrome-session"] else {
            throw AgentSpaceError("missing_option", "--chrome-session is required")
        }
        guard let mode = SessionMode(rawValue: raw.lowercased()) else {
            throw AgentSpaceError("invalid_option", "--chrome-session must be existing or dedicated")
        }
        guard (o["app"] ?? "").lowercased() == "chrome" else {
            throw AgentSpaceError("invalid_option", "--chrome-session requires --app chrome")
        }
        if let backend = o["backend"], !["auto", "cdp"].contains(backend.lowercased()) {
            throw AgentSpaceError("invalid_option",
                "--chrome-session rides the cdp route; --backend \(backend) is incompatible")
        }
        if let interaction = o["interaction"], interaction.lowercased() != "semantic" {
            throw AgentSpaceError("invalid_option",
                "--chrome-session delivers semantic interaction only; coordinate input is not available")
        }
        switch mode {
        case .dedicated:
            guard let profile = o["profile"], !profile.isEmpty else {
                throw AgentSpaceError("missing_option",
                    "--chrome-session dedicated requires --profile NAME (an AgentSpace-owned profile under the state root, never your real one)")
            }
            try StateStore.validate(profile)
        case .shared:
            guard o["profile"] == nil else {
                throw AgentSpaceError("invalid_option", "--profile only applies to --chrome-session dedicated")
            }
        }
        if let site = o["site"] {
            guard site.count <= 32, site.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
                throw AgentSpaceError("invalid_option", "--site must be a short site token (letters, digits, - or _)")
            }
        }
        guard !(o["url"] != nil && o["file"] != nil) else {
            throw AgentSpaceError("invalid_option", "Use --url or --file, not both")
        }
        guard o["url"] != nil || o["file"] != nil else {
            throw AgentSpaceError("missing_option", "--chrome-session launch needs --url or --file")
        }
        return mode
    }

    public static func launch(_ workspace: inout Workspace, options o: CommandOptions,
                              store: StateStore) async throws -> (String, JSONValue) {
        guard workspace.chromeSession == nil || workspace.chromeSession?.opening == true else {
            throw AgentSpaceError("session_exists",
                "this workspace already holds a chrome session (\(workspace.chromeSession!.session)); "
                + "stop-workspace first or use a new workspace")
        }
        let mode = try validateLaunch(o)
        let raw = try (o["file"] ?? o.required("url"))
        var url: URL
        if o["file"] != nil {
            let source = URL(fileURLWithPath: raw)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw AgentSpaceError("file_not_found", "local page does not exist")
            }
            let copy = URL(fileURLWithPath: workspace.temporaryDirectory)
                .appendingPathComponent("Page-\(UUID().uuidString).html")
            try FileManager.default.copyItem(at: source, to: copy)
            url = copy
        } else {
            guard let parsed = URL(string: raw),
                  ["file", "http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                throw AgentSpaceError("invalid_url", "Expected a file, http or https URL")
            }
            if parsed.isFileURL, !FileManager.default.fileExists(atPath: parsed.path) {
                throw AgentSpaceError("file_not_found", "Local page does not exist")
            }
            url = parsed
        }

        let chromeRoot: URL
        var profileDir: String?
        let key: String
        switch mode {
        case .shared:
            chromeRoot = SessionBroker.sharedChromeRoot()
            let (_, guid) = try ChromeEndpoint.discover(chromeRoot: chromeRoot)
            key = SessionBroker.brokerKey(mode: .shared, chromeRoot: chromeRoot.path, guid: guid)
        case .dedicated:
            let dir = try SessionBroker.dedicatedProfileDir(store, name: o["profile"]!)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            guard dir.resolvingSymlinksInPath().path.hasPrefix(
                SessionBroker.dedicatedProfilesRoot(store).resolvingSymlinksInPath().path) else {
                throw AgentSpaceError("invalid_option", "--profile must resolve under the AgentSpace profile root")
            }
            chromeRoot = dir
            profileDir = dir.path
            key = SessionBroker.brokerKey(mode: .dedicated, chromeRoot: dir.path)
        }
        let record: BrokerRecord
        let sessionID: String
        if let pending = workspace.chromeSession {
            guard pending.brokerKey == key else { throw AgentSpaceError("opening_incomplete", "the pending opening belongs to another profile; stop it before changing launch options") }
            (_, record, _) = try binding(workspace, store)
            sessionID = pending.session
        } else {
            record = try BrokerIPC.ensure(store, key: key, mode: mode, chromeRoot: chromeRoot, profileDir: profileDir)
            sessionID = UUID().uuidString
            var ref = ChromeSessionRef(session: sessionID, brokerKey: key, brokerPID: record.pid,
                brokerStart: record.start, mode: mode.rawValue, site: o["site"], expectedAccountDigest: nil)
            ref.opening = true
            workspace.chromeSession = ref
            try store.save(workspace)
        }
        let token = try BrokerIPC.token(store, key: key)
        var fields: [String: JSONValue] = [
            "requestId": .string("open-\(sessionID)"),
            "session": .string(sessionID),
            "url": .string(url.absoluteString),
        ]
        if let site = o["site"] { fields["site"] = .string(site) }
        if let account = o["expected-account"] { fields["expectedAccount"] = .string(account) }
        let reply = try BrokerIPC.call(socketPath: record.socketPath, token: token,
                                       op: "open", fields: fields, timeout: 60, expectedPeer: ProcessIdentity(pid: record.pid, start: record.start))
        let digest = stringField(field(reply, "session"), "expectedAccount")
        workspace.chromeSession?.expectedAccountDigest = digest
        workspace.chromeSession?.opening = false
        try store.save(workspace)
        return ("SessionBroker.open", stripOK(reply))
    }

    private static func binding(_ workspace: Workspace, _ store: StateStore) throws -> (ref: ChromeSessionRef, record: BrokerRecord, token: String) {
        guard let ref = workspace.chromeSession else {
            throw AgentSpaceError("no_session",
                "this workspace holds no chrome session; launch with "
                + "`launch-app --app chrome --chrome-session existing|dedicated`")
        }
        guard let record = BrokerIPC.liveRecord(store, key: ref.brokerKey),
              record.pid == ref.brokerPID, record.start == ref.brokerStart else {
            throw AgentSpaceError("session_broker_gone",
                "the session broker for this workspace is gone; stop-workspace can still "
                + "settle the journal, or --abandon-session drops the local record")
        }
        let token = try BrokerIPC.token(store, key: ref.brokerKey)
        return (ref, record, token)
    }

    private static func performOptions(_ command: String, _ o: CommandOptions) throws -> [String: JSONValue] {
        for name in BackendRouter.pointerOptions where o.values[name] != nil {
            throw AgentSpaceError("unsupported_option",
                "--\(name) needs coordinate input; chrome sessions are semantic only")
        }
        var opts: [String: JSONValue] = [:]
        if let ref = o["ref"] { opts["ref"] = .string(ref) }
        let selector = try o.selector()
        if let role = selector.role { opts["role"] = .string(role) }
        if let title = selector.title { opts["title"] = .string(title) }
        if let label = selector.label { opts["label"] = .string(label) }
        if let vc = selector.valueContains { opts["value-contains"] = .string(vc) }
        if let index = selector.index { opts["index"] = .number(Double(index)) }
        switch command {
        case "observe":
            opts["limit"] = .number(Double(try o.integer("max-nodes", default: 1000, range: 1...10000)))
            opts["depth"] = .number(Double(try o.integer("depth", default: 16, range: 0...30)))
            opts["screenshot"] = .bool(o.has("screenshot"))
        case "type-text":
            opts["text"] = .string(try o.required("text"))
            opts["replace"] = .bool(o.has("replace"))
            if !o.has("replace"), (o["ref"] == nil && selector.isEmpty) {
                throw AgentSpaceError("element_required", "type-text on a chrome session needs --ref or a selector")
            }
        case "key":
            opts["key"] = .string(try o.required("key"))
        case "scroll":
            for name in ["direction", "amount", "unit"] {
                if let v = o[name] { opts[name] = .string(v) }
            }
        case "click":
            break
        default:
            break
        }
        return opts
    }

    public static func perform(_ command: String, workspace: inout Workspace,
                               options o: CommandOptions, store: StateStore) async throws -> (String, JSONValue) {
        let (ref, record, token) = try binding(workspace, store)
        let opts = try performOptions(command, o)
        let reply = try BrokerIPC.call(socketPath: record.socketPath, token: token, op: "perform",
            fields: ["session": .string(ref.session), "command": .string(command),
                     "options": .object(opts)], timeout: 60, expectedPeer: ProcessIdentity(pid: record.pid, start: record.start))
        return ("SessionBroker.\(command)", stripOK(reply))
    }

    public static func handoff(_ workspace: inout Workspace, store: StateStore) async throws -> (String, JSONValue) {
        let (ref, record, token) = try binding(workspace, store)
        let reply = try BrokerIPC.call(socketPath: record.socketPath, token: token, op: "handoff",
                                       fields: ["session": .string(ref.session)], timeout: 60, expectedPeer: ProcessIdentity(pid: record.pid, start: record.start))
        return ("SessionBroker.handoff", stripOK(reply))
    }

    public static func resume(_ workspace: inout Workspace, store: StateStore) async throws -> (String, JSONValue) {
        let (ref, record, token) = try binding(workspace, store)
        let reply = try BrokerIPC.call(socketPath: record.socketPath, token: token, op: "resume",
                                       fields: ["session": .string(ref.session)], timeout: 120, expectedPeer: ProcessIdentity(pid: record.pid, start: record.start))
        return ("SessionBroker.resume", stripOK(reply))
    }

    public static func status(_ workspace: Workspace, store: StateStore) -> JSONValue {
        guard let ref = workspace.chromeSession else { return .null }
        var out: [String: JSONValue] = [
            "session": .string(ref.session),
            "mode": .string(ref.mode),
            "site": ref.site.map { .string($0) } ?? .null,
            "expectedAccount": ref.expectedAccountDigest.map { .string($0) } ?? .null,
            "brokerKey": .string(ref.brokerKey),
        ]
        guard let record = BrokerIPC.liveRecord(store, key: ref.brokerKey),
              record.pid == ref.brokerPID, record.start == ref.brokerStart,
              let token = try? BrokerIPC.token(store, key: ref.brokerKey) else {
            out["brokerAlive"] = .bool(false)
            out["note"] = .string("session broker is not running; session state lives in its journal only")
            return .object(out)
        }
        out["brokerAlive"] = .bool(true)
        out["brokerPid"] = .number(Double(record.pid))
        if let reply = try? BrokerIPC.call(socketPath: record.socketPath, token: token,
                                           op: "status", timeout: 10, expectedPeer: ProcessIdentity(pid: record.pid, start: record.start)) {
            out["broker"] = .object([
                "browserGone": field(reply, "browserGone"),
                "generation": field(reply, "generation"),
            ])
            if let session = field(field(reply, "sessions"), ref.session).objectValue {
                out["session"] = .object(session)
            }
        } else {
            out["brokerReachable"] = .bool(false)
        }
        return .object(out)
    }

    /// stop-workspace's session stage: close every journal-recorded target
    /// through the broker; when the broker is dead, settle what is provably
    /// true without it and report honestly.
    public static func closeSession(_ workspace: inout Workspace, store: StateStore) async throws -> JSONValue {
        guard let ref = workspace.chromeSession else { return .null }
        if let record = BrokerIPC.liveRecord(store, key: ref.brokerKey),
           record.pid == ref.brokerPID, record.start == ref.brokerStart {
            let token = try BrokerIPC.token(store, key: ref.brokerKey)
            let reply = try BrokerIPC.call(socketPath: record.socketPath, token: token,
                op: "close-session", fields: ["session": .string(ref.session)], timeout: 60, expectedPeer: ProcessIdentity(pid: record.pid, start: record.start))
            guard field(reply, "cleanupConfirmed") == .bool(true) else {
                throw AgentSpaceError("cleanup_uncertain", "Chrome did not confirm all owned targets closed. The workspace binding was retained for retry.")
            }
            workspace.chromeSession = nil
            return reply
        }
        let dir = SessionBroker.brokerDirectory(store, key: ref.brokerKey)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("journal.json")),
              let journal = try? JSONDecoder().decode(SessionJournal.self, from: data),
              let generation = journal.generation,
              let session = journal.sessions[ref.session] else {
            throw AgentSpaceError("cleanup_uncertain", "the bound broker is unavailable and no complete cleanup evidence exists. The workspace binding was retained.")
        }
        if session.ended, let receipt = session.cleanupReceipt, field(receipt, "cleanupConfirmed") == .bool(true) {
            workspace.chromeSession = nil
            return receipt
        }
        var terminated = false
        if !SessionProcess.isDead(generation.identity.browser) {
            guard ref.mode == SessionMode.dedicated.rawValue, journal.mode == .dedicated,
                  generation.ownedByBroker, generation.profileDir == journal.profileDir,
                  journal.sessions.values.allSatisfy({ $0.ended || $0.session == ref.session }) else {
                throw AgentSpaceError("cleanup_uncertain", "the broker is unavailable while its bound Chrome process remains live. No replacement connection, approval, or tab adoption was attempted.")
            }
            terminated = await SessionProcess.stop(generation.identity.browser)
        }
        guard SessionProcess.isDead(generation.identity.browser),
              session.targets.allSatisfy({ target in
                  let identity = target.generation ?? generation.identity
                  return SessionProcess.isDead(identity.browser)
              }) else {
            throw AgentSpaceError("cleanup_uncertain", "the recorded browser process remains live; the workspace binding was retained")
        }
        workspace.chromeSession = nil
        return .object(["ok": .bool(true), "cleanupConfirmed": .bool(true),
            "closedTargets": .array(session.targets.map { .string($0.targetId) }), "uncertainTargets": .array([]),
            "browserTerminated": .bool(terminated), "browserGone": .bool(true)])
    }

    /// --abandon-session: drop the local record; report the broker identity
    /// so the session can be inspected later. Nothing is signalled.
    public static func abandon(_ workspace: inout Workspace) -> JSONValue {
        guard let ref = workspace.chromeSession else {
            return .object(["sessionDropped": .bool(false), "reason": .string("no chrome session record")])
        }
        workspace.abandonedChromeSession = ref
        workspace.chromeSession = nil
        return .object([
            "sessionDropped": .bool(true),
            "brokerKey": .string(ref.brokerKey),
            "brokerPid": .number(Double(ref.brokerPID)),
            "note": .string("broker + journal retained for inspection; owned targets may still exist"),
        ])
    }

    /// The only fields a session action may ever put into the persisted
    /// ActionLog: enums, counts, booleans and our own error code. Page trees,
    /// readback values, URLs, titles and any observed identity string are
    /// never persisted - the caller still receives them in the live reply.
    public static func project(_ result: JSONValue) -> JSONValue {
        let allowed: Set<String> = [
            "session", "mode", "handoff", "ended", "idempotent",
            "verified", "dispatched", "truncated", "cleanupConfirmed",
            "browserTerminated", "browserGone", "focusChange",
            "popupsRejected", "downloadsBlocked", "access", "code",
            "closedTargets", "uncertainTargets", "brokerRespawned",
        ]
        guard case .object(let o) = result else { return .null }
        var out: [String: JSONValue] = [:]
        for (key, value) in o where allowed.contains(key) {
            switch key {
            case "access":
                if let a = value.objectValue {
                    out["access"] = .object([
                        "access": a["access"] ?? .null,
                        "identity": a["identity"] ?? .null,
                    ])
                }
            case "closedTargets", "uncertainTargets":
                out[key + "Count"] = .number(Double(value.arrayValue?.count ?? 0))
            case "session":
                if case .string = value {
                    out[key] = value
                } else if let s = value.objectValue {
                    var clean: [String: JSONValue] = [:]
                    for k in ["session", "mode", "handoff", "ended", "popupsRejected", "downloadsBlocked"]
                    where s[k] != nil { clean[k] = s[k]! }
                    if let a = s["access"]?.objectValue {
                        clean["access"] = .object(["access": a["access"] ?? .null,
                                                   "identity": a["identity"] ?? .null])
                    }
                    if let targets = s["targets"]?.arrayValue {
                        clean["targetCount"] = .number(Double(targets.count))
                    }
                    out["session"] = .object(clean)
                }
            default:
                out[key] = value
            }
        }
        if let tree = o["tree"], let decoded = try? JSONDecoder().decode(ElementNode.self, from: JSONEncoder().encode(tree)) {
            out["treeNodes"] = .number(Double(decoded.flattened.count))
        }
        if o["screenshot"] != .null && o["screenshot"] != nil {
            out["screenshotTaken"] = .bool(true)
        }
        if let error = o["error"]?.objectValue, let code = error["code"] {
            out["code"] = code
        }
        return .object(out)
    }

    private static func stripOK(_ reply: JSONValue) -> JSONValue {
        guard var o = reply.objectValue else { return reply }
        o.removeValue(forKey: "ok")
        return .object(o)
    }
}
