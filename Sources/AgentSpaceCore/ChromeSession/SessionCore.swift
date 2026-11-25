import Foundation

public actor SessionCore {
    public struct Config: Sendable {
        public var brokerKey: String
        public var mode: SessionMode
        /// Shared: canonical user Chrome root. Dedicated: the AgentSpace
        /// profile dir the broker owns.
        public var chromeRoot: URL
        public var brokerDir: URL
        public var profileDir: String?
        /// Dedicated only: Chrome executable + a spawn seam for tests.
        public var chromeExecutable: URL?
        public var chromeSpawn: (@Sendable (URL, [String]) throws -> Process)?
        public var probe: DisplayHost.Probe
        public var transportFactory: (@Sendable (URL) -> any CDPTransport)?
        public var launchTimeout: TimeInterval
        public var onProtocolEvent: (@Sendable (String) -> Void)?
        /// Called after a journal mutation is persisted.
        public var onJournalSaved: (@Sendable (SessionJournal) -> Void)?

        public init(brokerKey: String, mode: SessionMode, chromeRoot: URL, brokerDir: URL,
                    profileDir: String? = nil, chromeExecutable: URL? = nil,
                    chromeSpawn: (@Sendable (URL, [String]) throws -> Process)? = nil,
                    probe: DisplayHost.Probe = .system,
                    transportFactory: (@Sendable (URL) -> any CDPTransport)? = nil,
                    launchTimeout: TimeInterval = 15,
                    onProtocolEvent: (@Sendable (String) -> Void)? = nil,
                    onJournalSaved: (@Sendable (SessionJournal) -> Void)? = nil) {
            self.brokerKey = brokerKey; self.mode = mode; self.chromeRoot = chromeRoot
            self.brokerDir = brokerDir; self.profileDir = profileDir
            self.chromeExecutable = chromeExecutable; self.chromeSpawn = chromeSpawn
            self.probe = probe; self.transportFactory = transportFactory
            self.launchTimeout = launchTimeout
            self.onProtocolEvent = onProtocolEvent; self.onJournalSaved = onJournalSaved
        }
    }

    let config: Config
    var journal: SessionJournal
    let salt: String
    var transport: (any CDPTransport)?
    var eventTask: Task<Void, Never>?
    var transportEpoch = 0
    var attachments: [String: String] = [:]
    var sessionByCDPSession: [String: String] = [:]
    var policyScripts: [String: String] = [:]
    var live: [String: LiveSession] = [:]
    var pendingDownloads: [String: String] = [:]
    var executionContexts: [String: Set<Int32>] = [:]
    var ownedHeadless: Bool?
    var ownedProcess: Process?
    var browserGone = false
    var aliasCounter = 0
    var busySessions = Set<String>()
    var connectionError: AgentSpaceError?
    var lastActivity = Date()

    struct LiveSession {
        var access: AccessReport?
        var lastURL: String?
        var document: String?
        var revision = 0
    }

    public init(config: Config) throws {
        self.config = config
        let journalURL = config.brokerDir.appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath: journalURL.path) {
            guard let data = try? Data(contentsOf: journalURL),
                  let existing = try? JSONDecoder().decode(SessionJournal.self, from: data),
                  existing.brokerKey == config.brokerKey, existing.mode == config.mode,
                  URL(fileURLWithPath: existing.chromeRoot).standardizedFileURL.resolvingSymlinksInPath() == config.chromeRoot.standardizedFileURL.resolvingSymlinksInPath() else {
                throw AgentSpaceError("journal_unreadable", "the existing target journal is unreadable or belongs to another browser; it was preserved")
            }
            journal = existing
        } else {
            journal = SessionJournal(brokerKey: config.brokerKey, mode: config.mode,
                                     chromeRoot: config.chromeRoot.path, profileDir: config.profileDir)
        }
        journal.brokerBoots += 1
        aliasCounter = journal.sessions.values.flatMap(\.targets).count
        let saltURL = config.brokerDir.appendingPathComponent("account-salt")
        if let existing = try? String(contentsOf: saltURL, encoding: .utf8), !existing.isEmpty {
            salt = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            salt = UUID().uuidString
            try Data(salt.utf8).write(to: saltURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: saltURL.path)
        }
        try? FileManager.default.removeItem(at: config.brokerDir.appendingPathComponent("captures"))
        try Self.writeJournal(journal, to: journalURL)
        config.onJournalSaved?(journal)
    }

    var journalURL: URL { config.brokerDir.appendingPathComponent("journal.json") }

    nonisolated static func writeJournal(_ journal: SessionJournal, to url: URL) throws {
        try JSONEncoder().encode(journal).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func saveJournal() throws {
        try Self.writeJournal(journal, to: journalURL)
        config.onJournalSaved?(journal)
    }

    func accountHash(_ account: String) -> String { SessionBroker.accountDigest(account, salt: salt) }

    func cdp(_ method: String, params: [String: JSONValue] = [:],
             sessionId: String? = nil, timeout: TimeInterval = 30) async throws -> JSONValue {
        config.onProtocolEvent?(method)
        guard let transport else { throw AgentSpaceError("connection_unresolved", "no live debugging connection; cleanup remains uncertain") }
        let epoch = transportEpoch
        let result = try await transport.send(method, params: params, sessionId: sessionId, timeout: timeout)
        guard epoch == transportEpoch else { throw AgentSpaceError("browser_generation_changed", "the browser connection changed during the operation") }
        return result
    }

    public func connectBrowser() async throws {
        if let generation = journal.generation, SessionProcess.isDead(generation.identity.browser, probe: config.probe) {
            for (id, session) in journal.sessions where !session.ended {
                guard session.targets.allSatisfy({ target in
                    target.state == .closed || SessionProcess.isDead((target.generation ?? generation.identity).browser, probe: config.probe)
                }) else { continue }
                for index in journal.sessions[id]!.targets.indices { journal.sessions[id]!.targets[index].state = .closed }
                journal.sessions[id]?.ended = true
                journal.sessions[id]?.cleanupReceipt = .object(["ok": .bool(true), "session": .string(id),
                    "cleanupConfirmed": .bool(true), "closedTargets": .array(session.targets.map { .string($0.targetId) }),
                    "uncertainTargets": .array([]), "unreceiptedTarget": .bool(false),
                    "browserTerminated": .bool(false), "browserGone": .bool(true)])
            }
            try saveJournal()
        }
        if journal.sessions.values.contains(where: { !$0.ended }) {
            connectionError = AgentSpaceError("broker_recovery_required", "A previous broker left unsettled sessions. No replacement connection or approval was requested. Restart the bound Chrome instance before launching again. Stop can settle receipts only when that browser process is proved dead. --abandon-session drops a local binding; it does not recover the broker or close tabs.")
            throw connectionError!
        }
        do {
            if config.mode == .dedicated { try await connectDedicated() }
            else {
                let found = try ChromeEndpoint.discover(chromeRoot: config.chromeRoot)
                try await connectEndpoint(found.endpoint, guid: found.guid, owned: false)
            }
        } catch {
            let failure = error as? AgentSpaceError ?? AgentSpaceError("connection_unresolved", "Chrome did not confirm the debugging connection")
            connectionError = failure
            throw failure
        }
    }

    func connectEndpoint(_ endpoint: URL, guid: String, owned: Bool, expectedPID: Int32? = nil) async throws {
        let socket = config.transportFactory?(endpoint) ?? CDPSocket(endpoint: endpoint)
        do {
            let identity = try await ChromeEndpoint.identify(transport: socket, endpoint: endpoint,
                                                            guid: guid, timeout: config.launchTimeout)
            if let expectedPID, identity.browser.pid != expectedPID {
                throw AgentSpaceError("cdp_launch_failed", "the owned endpoint reported a different browser process")
            }
            try await adoptTransport(socket, identity: identity, ownedByBroker: owned)
        } catch {
            await socket.close()
            throw error
        }
    }

    public func adoptTransport(_ socket: any CDPTransport, identity: BrowserIdentity,
                              ownedByBroker: Bool = false) async throws {
        if var previous = journal.generation, previous.identity != identity {
            guard SessionProcess.isDead(previous.identity.browser, probe: config.probe) else {
                throw AgentSpaceError("browser_generation_changed", "the previous browser generation is still live; refusing to rebind its targets")
            }
            settleDeadGeneration(previous.identity)
            previous.gone = true
            journal.staleGenerations.append(previous)
        }
        transportEpoch += 1
        let epoch = transportEpoch
        transport = socket
        journal.generation = BrowserGeneration(identity: identity, ownedByBroker: ownedByBroker, profileDir: config.profileDir)
        browserGone = false
        connectionError = nil
        try saveJournal()
        eventTask = Task { await self.drainEvents(socket, epoch: epoch) }
    }

    func processAlive(_ identity: ProcessIdentity) -> Bool {
        DisplayHost.alive(identity.pid, start: identity.start, probe: config.probe)
    }

    func connectDedicated() async throws {
        guard config.mode == .dedicated, let profile = config.profileDir,
              let executable = config.chromeExecutable else {
            throw AgentSpaceError("app_unavailable", "Google Chrome and an AgentSpace-owned profile are required")
        }
        if let generation = journal.generation, !SessionProcess.isDead(generation.identity.browser, probe: config.probe) {
            throw AgentSpaceError("profile_in_use", "the profile's previous browser is still running; it will not be rebound")
        }
        try await launchOwnedChrome(executable: executable, profile: profile, headless: true)
    }

    func launchOwnedChrome(executable: URL, profile: String, headless: Bool) async throws {
        var arguments = ["--remote-debugging-port=0", "--remote-debugging-address=127.0.0.1",
                         "--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check"]
        if headless { arguments.insert("--headless=new", at: 0) }
        let process: Process
        if let spawn = config.chromeSpawn { process = try spawn(executable, arguments) }
        else {
            process = Process(); process.executableURL = executable; process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
        }
        ownedProcess = process
        guard let start = config.probe.startTime(process.processIdentifier) else {
            if process.isRunning { process.terminate() }
            throw AgentSpaceError("cdp_launch_failed", "could not record the owned Chrome process identity")
        }
        let spawned = ProcessIdentity(pid: process.processIdentifier, start: start)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(config.launchTimeout))
            while ContinuousClock.now < deadline {
                guard process.isRunning else { throw AgentSpaceError("profile_in_use", "Chrome exited during startup; check whether this profile is locked by another Chrome") }
                if let found = try? ChromeEndpoint.discover(chromeRoot: config.chromeRoot) {
                    // A stale file from the last generation must not initiate a connection.
                    if found.endpoint.absoluteString != journal.generation?.identity.endpoint {
                        try await connectEndpoint(found.endpoint, guid: found.guid, owned: true, expectedPID: spawned.pid)
                        ownedHeadless = headless
                        return
                    }
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw AgentSpaceError("cdp_launch_failed", "owned Chrome did not publish its debugging endpoint")
        } catch {
            _ = await SessionProcess.stop(spawned, probe: config.probe)
            throw error
        }
    }

    func drainEvents(_ socket: any CDPTransport, epoch: Int) async {
        for await event in socket.events {
            guard epoch == transportEpoch else { return }
            await handleEvent(event, epoch: epoch)
        }
        guard epoch == transportEpoch else { return }
        let reason = await (socket as? CDPSocket)?.terminalFailure ?? "connection_unresolved"
        guard epoch == transportEpoch else { return }
        transport = nil; eventTask = nil
        connectionError = AgentSpaceError(reason, "The debugging connection ended. Target cleanup is uncertain until the bound process is proved dead.")
        for id in journal.sessions.keys {
            live[id] = nil
            for index in journal.sessions[id]!.targets.indices where journal.sessions[id]!.targets[index].state != .closed {
                journal.sessions[id]!.targets[index].state = .uncertain
            }
        }
        if let generation = journal.generation, SessionProcess.isDead(generation.identity.browser, probe: config.probe) {
            settleDeadGeneration(generation.identity)
            browserGone = true
        }
        try? saveJournal()
    }

    func settleDeadGeneration(_ identity: BrowserIdentity) {
        for id in journal.sessions.keys {
            for i in journal.sessions[id]!.targets.indices {
                let target = journal.sessions[id]!.targets[i]
                if target.generation == identity || (target.generation == nil && journal.generation?.identity == identity) {
                    journal.sessions[id]!.targets[i].state = .closed
                }
            }
            live[id] = nil
        }
        if journal.generation?.identity == identity { journal.generation?.gone = true }
    }

    func guardBrowser() throws -> BrowserGeneration {
        if let connectionError { throw connectionError }
        guard let generation = journal.generation else { throw AgentSpaceError("connection_unresolved", "no browser generation is bound") }
        guard processAlive(generation.identity.browser) else {
            guard SessionProcess.isDead(generation.identity.browser, probe: config.probe) else {
                throw AgentSpaceError("process_identity_unresolved", "the browser process identity could not be checked; cleanup remains uncertain")
            }
            settleDeadGeneration(generation.identity); browserGone = true; try saveJournal()
            throw AgentSpaceError("browser_gone", "the bound browser process is proved dead")
        }
        guard transport != nil, !generation.gone else { throw AgentSpaceError("connection_unresolved", "the bound debugging connection is unavailable") }
        return generation
    }

    func configureOwnedDownloads(_ sessionID: String) async throws {
        guard config.mode == .dedicated, journal.generation?.ownedByBroker == true else { return }
        let downloads = config.brokerDir.appendingPathComponent("downloads/\(sessionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        _ = try await cdp("Browser.setDownloadBehavior", params: ["behavior": .string("allow"),
            "downloadPath": .string(downloads.path), "eventsEnabled": .bool(true)])
    }

    @discardableResult
    func createOwnedTarget(sessionID: String, url: String, human: Bool = false) async throws -> (String, String) {
        let generation = try guardBrowser()
        journal.sessions[sessionID]?.openState = .creatingTarget
        try saveJournal()
        let receipt = try await cdp("Target.createTarget", params: ["url": .string("about:blank"), "background": .bool(!human)])
        guard let targetId = stringField(receipt, "targetId") else { throw AgentSpaceError("cdp_protocol", "createTarget returned no receipt; cleanup is uncertain") }
        aliasCounter += 1
        var target = OwnedTarget(targetId: targetId, alias: "t\(aliasCounter)")
        target.generation = generation.identity
        journal.sessions[sessionID]?.targets.append(target)
        journal.sessions[sessionID]?.openState = .targetCreated
        try saveJournal()
        let cdpSession = try await attach(targetId, sessionID: sessionID)
        if !human { try await armPage(cdpSession: cdpSession, sessionID: sessionID) }
        _ = try await cdp("Page.enable", sessionId: cdpSession)
        if url != "about:blank" {
            let navigation = try await cdp("Page.navigate", params: ["url": .string(url)], sessionId: cdpSession)
            guard field(navigation, "errorText") == .null else { throw AgentSpaceError("navigation_failed", "Chrome could not navigate the owned page") }
            try await settle(cdpSession)
        }
        return (targetId, cdpSession)
    }

    func attach(_ targetId: String, sessionID: String) async throws -> String {
        if let existing = attachments[targetId] { return existing }
        let attached = try await cdp("Target.attachToTarget", params: ["targetId": .string(targetId), "flatten": .bool(true)])
        guard let cdpSession = stringField(attached, "sessionId") else { throw AgentSpaceError("cdp_protocol", "attachToTarget returned no session") }
        attachments[targetId] = cdpSession; sessionByCDPSession[cdpSession] = sessionID
        return cdpSession
    }

    func markTarget(_ targetId: String, state: TargetState) {
        for id in journal.sessions.keys {
            guard let index = journal.sessions[id]!.targets.firstIndex(where: { $0.targetId == targetId }),
                  journal.sessions[id]!.targets[index].state != .closed else { continue }
            journal.sessions[id]!.targets[index].state = state
            try? saveJournal()
        }
    }

    func pageSession(_ sessionID: String) throws -> (targetId: String, cdpSession: String) {
        guard let target = journal.sessions[sessionID]?.targets.last(where: { $0.state == .open }),
              target.generation == journal.generation?.identity,
              let cdpSession = attachments[target.targetId] else {
            throw AgentSpaceError("session_target_gone", "the owned page is unavailable; partial openings remain bound for cleanup")
        }
        return (target.targetId, cdpSession)
    }

    public func open(requestId: String, session: String, url: String,
                     site: String?, expectedAccount: String?) async throws -> JSONValue {
        lastActivity = Date()
        if config.mode == .dedicated, journal.sessions.values.contains(where: { !$0.ended && $0.session != session }) {
            throw AgentSpaceError("profile_in_use", "a dedicated profile permits one active workspace; stop its current workspace before starting another")
        }
        if let existing = journal.sessions[session] {
            guard existing.openRequestId == requestId,
                  existing.site?.lowercased() == site?.lowercased(),
                  existing.expectedAccountDigest == expectedAccount.map(accountHash) else {
                throw AgentSpaceError("request_conflict", "the opening request's site or account constraint differs from its saved receipt")
            }
            guard !existing.ended, existing.openState == .ready else {
                throw AgentSpaceError("opening_incomplete", "this opening did not settle; its saved binding and target receipts remain available to stop-workspace. It was not replayed.")
            }
            return .object(["ok": .bool(true), "session": sessionSummary(existing), "idempotent": .bool(true)])
        }
        if config.mode == .dedicated, transport == nil { try await connectDedicated() }
        _ = try guardBrowser()
        journal.sessions[session] = SessionRecord(session: session, openRequestId: requestId, site: site,
                                                  expectedAccountDigest: expectedAccount.map(accountHash))
        try saveJournal()
        _ = try await createOwnedTarget(sessionID: session, url: url)
        let report = try await assess(session)
        journal.sessions[session]?.openState = .ready
        try saveJournal()
        return .object(["ok": .bool(true), "session": sessionSummary(journal.sessions[session]!), "access": accessValue(report)])
    }

    public func handoff(sessionID: String) async throws -> JSONValue {
        guard let session = journal.sessions[sessionID], !session.ended else { throw AgentSpaceError("session_not_found", "unknown session") }
        _ = try guardBrowser()
        if session.handoff == .background {
            journal.sessions[sessionID]?.handoff = .awaitingHuman
            live[sessionID]?.access = nil
            try saveJournal()
        }
        if config.mode == .shared {
            let (target, cdpSession) = try pageSession(sessionID)
            try await disarmPage(cdpSession)
            _ = try await cdp("Target.activateTarget", params: ["targetId": .string(target)])
        } else if ownedHeadless != false {
            let (_, page) = try pageSession(sessionID)
            let url = try await evaluate(page, "location.href")
            guard case .string(let destination) = url else { throw AgentSpaceError("handoff_failed", "could not read the current destination") }
            try await relaunchOwned(headless: false)
            _ = try await createOwnedTarget(sessionID: sessionID, url: destination, human: true)
        }
        _ = try pageSession(sessionID)
        return .object(["ok": .bool(true), "session": sessionSummary(journal.sessions[sessionID]!),
                        "handoff": .string(journal.sessions[sessionID]!.handoff.rawValue),
                        "note": .string("Complete sign-in in the owned tab, then switch away and run session-resume. All automation is paused during handoff.")])
    }

    public func resume(sessionID: String) async throws -> JSONValue {
        guard let session = journal.sessions[sessionID], !session.ended else { throw AgentSpaceError("session_not_found", "unknown session") }
        _ = try guardBrowser()
        let (_, page) = try pageSession(sessionID)
        let report = try await assess(sessionID)
        try gate(sessionID, command: "resume", allowHandoff: true)
        guard report.access != .loginRequired else { throw AgentSpaceError("login_required", "sign-in has not completed; handoff remains active") }
        if session.handoff != .background {
            if config.mode == .shared {
                guard try await evaluate(page, "document.visibilityState") == .string("hidden") else {
                    journal.sessions[sessionID]?.handoff = .awaitingBackground; try saveJournal()
                    return .object(["ok": .bool(true), "handoff": .string(HandoffState.awaitingBackground.rawValue), "note": .string("Switch away from the owned tab and run session-resume again")])
                }
            } else if ownedHeadless != true {
                guard let destination = live[sessionID]?.lastURL else { throw AgentSpaceError("resume_failed", "no live destination is available") }
                try await relaunchOwned(headless: true)
                _ = try await createOwnedTarget(sessionID: sessionID, url: destination, human: true)
                _ = try await assess(sessionID)
                try gate(sessionID, command: "resume", allowHandoff: true)
                if live[sessionID]?.access?.access == .loginRequired {
                    throw AgentSpaceError("login_required", "the background profile did not retain access; handoff remains active")
                }
            }
        }
        let (_, backgroundPage) = try pageSession(sessionID)
        let priorHandoff = journal.sessions[sessionID]!.handoff
        journal.sessions[sessionID]?.handoff = .background
        do {
            try await armPage(cdpSession: backgroundPage, sessionID: sessionID)
            for page in sessionByCDPSession.filter({ $0.value == sessionID }).map(\.key) where page != backgroundPage {
                try await armPage(cdpSession: page, sessionID: sessionID)
            }
        } catch {
            journal.sessions[sessionID]?.handoff = priorHandoff
            try? await disarmPage(backgroundPage)
            try saveJournal()
            throw error
        }
        journal.sessions[sessionID]?.openState = .ready
        try saveJournal()
        return .object(["ok": .bool(true), "session": sessionSummary(journal.sessions[sessionID]!), "handoff": .string(HandoffState.background.rawValue)])
    }

    func disconnect() async {
        transportEpoch += 1
        let oldTransport = transport
        let oldTask = eventTask
        transport = nil; eventTask = nil
        await oldTransport?.close()
        await oldTask?.value
        attachments.removeAll(); sessionByCDPSession.removeAll(); policyScripts.removeAll(); live.removeAll(); executionContexts.removeAll()
    }

    func stopOwnedBrowser() async throws {
        guard config.mode == .dedicated, let generation = journal.generation,
              generation.ownedByBroker, generation.profileDir == config.profileDir else {
            throw AgentSpaceError("ownership_required", "this broker has no dedicated browser termination capability")
        }
        // Browser.close flushes the persistent profile before process exit.
        if transport != nil {
            _ = try? await cdp("Browser.close", timeout: 2)
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !SessionProcess.isDead(generation.identity.browser, probe: config.probe), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard await SessionProcess.stop(generation.identity.browser, probe: config.probe) else {
            throw AgentSpaceError("cleanup_uncertain", "the owned browser did not exit; its generation remains unsettled")
        }
        await disconnect()
        settleDeadGeneration(generation.identity)
        browserGone = true
        try saveJournal()
    }

    func relaunchOwned(headless: Bool) async throws {
        guard !journal.sessions.values.contains(where: { !$0.ended && $0.handoff == .background }) else {
            throw AgentSpaceError("profile_in_use", "an active background workspace still leases this profile")
        }
        try await stopOwnedBrowser()
        guard let executable = config.chromeExecutable, let profile = config.profileDir else { throw AgentSpaceError("broker_config", "no dedicated browser executable") }
        try await launchOwnedChrome(executable: executable, profile: profile, headless: headless)
    }

    func targetExists(_ targetID: String) async throws -> Bool {
        let reply = try await cdp("Target.getTargets", timeout: 10)
        guard case .array(let targets) = field(reply, "targetInfos"),
              targets.allSatisfy({ stringField($0, "targetId") != nil }) else {
            throw AgentSpaceError("cdp_protocol", "Chrome did not return a valid target inventory; cleanup remains uncertain")
        }
        return targets.contains { stringField($0, "targetId") == targetID }
    }

    public func closeSession(_ sessionID: String) async throws -> JSONValue {
        guard let session = journal.sessions[sessionID] else {
            return .object(["ok": .bool(true), "cleanupConfirmed": .bool(true), "closedTargets": .array([]), "uncertainTargets": .array([])])
        }
        if let receipt = session.cleanupReceipt, session.ended { return receipt }
        var terminated = false
        if config.mode == .dedicated {
            guard !journal.sessions.values.contains(where: { !$0.ended && $0.session != sessionID }) else { throw AgentSpaceError("profile_in_use", "another workspace still leases this browser") }
            let wasLive = journal.generation.map { processAlive($0.identity.browser) } ?? false
            do { try await stopOwnedBrowser(); terminated = wasLive } catch {}
        }
        for target in journal.sessions[sessionID]!.targets where target.state != .closed {
            let identity = target.generation ?? journal.generation?.identity
            if let identity, SessionProcess.isDead(identity.browser, probe: config.probe) { markTarget(target.targetId, state: .closed); continue }
            guard identity == journal.generation?.identity, transport != nil else { markTarget(target.targetId, state: .uncertain); continue }
            markTarget(target.targetId, state: .closing)
            do {
                if try await !targetExists(target.targetId) {
                    markTarget(target.targetId, state: .closed)
                    continue
                }
                let result = try await cdp("Target.closeTarget", params: ["targetId": .string(target.targetId)], timeout: 10)
                guard field(result, "success") == .bool(true) else { throw AgentSpaceError("cleanup_uncertain", "Chrome did not confirm closeTarget") }
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while try await targetExists(target.targetId) {
                    guard ContinuousClock.now < deadline else { throw AgentSpaceError("cleanup_uncertain", "the target remains live after closeTarget") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                markTarget(target.targetId, state: .closed)
            } catch { markTarget(target.targetId, state: .uncertain) }
        }
        let current = journal.sessions[sessionID]!
        let uncertain = current.targets.filter { $0.state != .closed }.map(\.targetId)
        let unreceipted = current.openState == .creatingTarget && journal.generation.map { SessionProcess.isDead($0.identity.browser, probe: config.probe) } != true
        let confirmed = uncertain.isEmpty && !unreceipted
        let reply: JSONValue = .object(["ok": .bool(true), "session": .string(sessionID),
            "cleanupConfirmed": .bool(confirmed), "closedTargets": .array(current.targets.filter { $0.state == .closed }.map { .string($0.targetId) }),
            "uncertainTargets": .array(uncertain.map { .string($0) }), "unreceiptedTarget": .bool(unreceipted),
            "browserTerminated": .bool(terminated), "browserGone": .bool(browserGone)])
        if confirmed {
            journal.sessions[sessionID]?.ended = true
            journal.sessions[sessionID]?.cleanupReceipt = reply
            live[sessionID] = nil
        }
        try saveJournal()
        lastActivity = Date()
        return reply
    }

    public var isBrowserGone: Bool { browserGone }
    public var shouldExitWhenIdle: Bool {
        journal.sessions.values.allSatisfy(\.ended) && Date().timeIntervalSince(lastActivity) > 30
    }
    public func closeConnection() async {
        if config.mode == .dedicated, journal.sessions.values.allSatisfy(\.ended) { try? await stopOwnedBrowser() }
        await disconnect()
    }
    public var journalSnapshot: SessionJournal { journal }

    static func validateToken(_ value: String, maximum: Int = 128) throws {
        guard !value.isEmpty, value.count <= maximum,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw AgentSpaceError("protocol_error", "identifiers must be bounded ASCII tokens")
        }
    }

    public func handle(_ op: String, _ fields: JSONValue) async throws -> JSONValue {
        lastActivity = Date()
        let id = stringField(fields, "session")
        if let id { try Self.validateToken(id) }
        if let request = stringField(fields, "requestId") { try Self.validateToken(request) }
        if let site = stringField(fields, "site") { try Self.validateToken(site, maximum: 32) }
        let exclusive = ["open", "perform", "handoff", "resume", "close-session"].contains(op)
        if exclusive, let id {
            guard busySessions.insert(id).inserted else { throw AgentSpaceError("session_busy", "another operation is still settling; mutations were not replayed") }
        }
        defer { if exclusive, let id { busySessions.remove(id) } }
        switch op {
        case "hello":
            if let connectionError { throw connectionError }
            return .object(["ok": .bool(true), "pid": .number(Double(getpid())), "brokerKey": .string(config.brokerKey),
                "mode": .string(config.mode.rawValue), "protocol": .number(1), "browserGone": .bool(browserGone)])
        case "status": return status()
        case "journal": return .object(["ok": .bool(true), "journal": try .encoded(journal)])
        case "shutdown": return .object(["ok": .bool(true), "shutdown": .bool(true)])
        case "open":
            guard let id, let request = stringField(fields, "requestId"), let url = stringField(fields, "url") else { throw AgentSpaceError("protocol_error", "open needs session, requestId and url") }
            guard let parsed = URL(string: url), ["http","https","file"].contains(parsed.scheme?.lowercased() ?? "") else { throw AgentSpaceError("invalid_url", "open requires an http, https, or file destination") }
            return try await open(requestId: request, session: id, url: url, site: stringField(fields, "site"), expectedAccount: stringField(fields, "expectedAccount"))
        case "perform":
            guard let id, let command = stringField(fields, "command") else { throw AgentSpaceError("protocol_error", "perform needs session and command") }
            var result = try await perform(sessionID: id, command: command, options: field(fields, "options")).objectValue ?? [:]
            result["ok"] = .bool(true); return .object(result)
        case "handoff", "resume", "close-session":
            guard let id else { throw AgentSpaceError("protocol_error", "session is required") }
            if op == "handoff" { return try await handoff(sessionID: id) }
            if op == "resume" { return try await resume(sessionID: id) }
            return try await closeSession(id)
        default: throw AgentSpaceError("unknown_op", "unknown broker operation")
        }
    }

    func sessionSummary(_ session: SessionRecord) -> JSONValue {
        var value: [String: JSONValue] = ["session": .string(session.session), "mode": .string(config.mode.rawValue),
            "site": session.site.map(JSONValue.string) ?? .null, "handoff": .string(session.handoff.rawValue),
            "ended": .bool(session.ended), "openState": .string(session.openState?.rawValue ?? "ready"),
            "popupsRejected": .number(Double(session.popupRejected)), "downloadsBlocked": .number(Double(session.downloadsBlocked)),
            "downloadsSaved": .array(session.downloadsSaved.map(JSONValue.string)),
            "targets": .array(session.targets.map { .object(["id": .string($0.targetId), "alias": .string($0.alias), "state": .string($0.state.rawValue)]) })]
        if let report = live[session.session]?.access { value["access"] = accessValue(report) }
        if let digest = session.expectedAccountDigest { value["expectedAccount"] = .string(digest) }
        return .object(value)
    }

    func status() -> JSONValue {
        var value: [String: JSONValue] = ["ok": .bool(true), "brokerKey": .string(config.brokerKey),
            "mode": .string(config.mode.rawValue), "pid": .number(Double(getpid())), "browserGone": .bool(browserGone),
            "connection": .string(connectionError?.code ?? "connected"),
            "sessions": .object(journal.sessions.mapValues(sessionSummary))]
        if let generation = journal.generation {
            value["generation"] = .object(["browserPid": .number(Double(generation.identity.browser.pid)),
                "ownedByBroker": .bool(generation.ownedByBroker), "connected": .bool(transport != nil && !generation.gone)])
        }
        return .object(value)
    }
}
