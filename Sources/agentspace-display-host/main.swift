import AgentSpaceCore
import ASDisplayShim
import CoreGraphics
import Darwin
import Foundation

// AgentSpace display host: a persistent per-workspace process whose sole job is
// owning a CGVirtualDisplay across CLI invocations and answering a small
// authenticated unix-socket protocol. It never touches Accessibility, CGEvent
// or NSWorkspace, so it runs with no TCC grants. A display dies with this
// process; CLI-side state treats that as honest evidence of loss. The process
// is a session leader (setsid): a Ctrl-C on the caller's terminal process group
// can never reach it.

enum HostError: Error, CustomStringConvertible {
    case usage(String), failure(String, code: String = "host_error")
    var description: String {
        switch self {
        case .usage(let m): return m
        case .failure(let m, _): return m
        }
    }
    var code: String {
        if case .failure(_, let c) = self { return c }; return "usage_error"
    }
}

struct Config {
    var workspaceUUID = ""
    var socketPath = ""
    var tokenFile = ""
    var width = 1920, height = 1080, refresh = 60.0, hiDPI = 0
    var name = ""
    var logPath = ""
    var ioTimeout: TimeInterval = 15
    var janitorInterval: TimeInterval = 5

    static func parse(_ args: [String]) throws -> Config {
        var config = Config()
        var i = 0
        while i < args.count {
            guard i + 1 < args.count else { throw HostError.usage("missing value for \(args[i])") }
            let value = args[i + 1]
            switch args[i] {
            case "--workspace-uuid": config.workspaceUUID = value
            case "--socket": config.socketPath = value
            case "--token-file": config.tokenFile = value
            case "--width": guard let v = UInt32(value), (64...8192).contains(v) else { throw HostError.usage("--width must be 64...8192") }; config.width = Int(v)
            case "--height": guard let v = UInt32(value), (64...8192).contains(v) else { throw HostError.usage("--height must be 64...8192") }; config.height = Int(v)
            case "--refresh": guard let v = Double(value), v > 0, v <= 240 else { throw HostError.usage("--refresh must be 0<r<=240") }; config.refresh = v
            case "--hidpi": config.hiDPI = value == "1" ? 1 : 0
            case "--name": config.name = value
            case "--log": config.logPath = value
            case "--io-timeout": guard let v = Double(value), (0.5...120).contains(v) else { throw HostError.usage("--io-timeout must be 0.5...120 seconds") }; config.ioTimeout = v
            case "--janitor-interval": guard let v = Double(value), (0.2...60).contains(v) else { throw HostError.usage("--janitor-interval must be 0.2...60 seconds") }; config.janitorInterval = v
            default: throw HostError.usage("unknown option \(args[i])")
            }
            i += 2
        }
        guard !config.workspaceUUID.isEmpty, !config.socketPath.isEmpty, !config.tokenFile.isEmpty else {
            throw HostError.usage("--workspace-uuid, --socket and --token-file are required")
        }
        return config
    }
}

final class DisplayOwner: @unchecked Sendable {
    var handle: UnsafeMutableRawPointer?
    var displayID: UInt32 = 0
    var bounds: CGRect?
    var fake = false
    /// Bumped on every create and every destroy: a queued termination callback
    /// only clears the generation it was installed for and can never clobber
    /// a later display.
    var generation: UInt64 = 0
    let lock = NSLock()

    func create(width: Int, height: Int, refresh: Double, hiDPI: Int, name: String, serial: UInt32) throws -> JSONValue {
        try lock.withLock {
            guard displayID == 0 else {
                throw HostError.failure("a display is already live on this host", code: "conflict")
            }
            generation &+= 1
            let current = generation
            if ProcessInfo.processInfo.environment["AGENTSPACE_DISPLAY_FAKE"] == "1" {
                // Explicit test hook, always marked synthetic in the reply so
                // no caller can mistake it for a real seat.
                fake = true
                displayID = 0x4147_5654
                bounds = CGRect(x: 1_048_576, y: 0, width: width, height: height)
                return .object(["id": .number(Double(displayID)), "bounds": boundsJSON(bounds!), "fake": .bool(true)])
            }
            var error = [CChar](repeating: 0, count: 512)
            guard ASVDProbe(&error, error.count) != 0 else {
                throw HostError.failure("virtual display API unavailable: \(decode(error))", code: "display_unavailable")
            }
            let mm = CGSize(width: Double(width) * 25.4 / 110.0, height: Double(height) * 25.4 / 110.0)
            let created = name.withCString { cname in
                ASVDCreate(UInt32(width), UInt32(height), refresh, Int32(hiDPI),
                           0x4147, 0x5350, serial, cname, mm, { [weak self] in
                        // The callback can fire while create/destroy holds the
                        // lock - it must never block on it inline.
                        let owner = self
                        DispatchQueue.global().async { owner?.noteTerminated(generation: current) }
                    }, &error, error.count)
            }
            guard let created else {
                throw HostError.failure("display creation failed: \(decode(error))", code: "display_creation_failed")
            }
            handle = created
            displayID = ASVDDisplayID(created)
            // The OS assigns an origin when the display joins the active set;
            // poll briefly so a later placement check can bound against it.
            var found: CGRect?
            for _ in 0..<40 {
                var count: UInt32 = 0
                if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
                    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
                    if CGGetActiveDisplayList(count, &ids, &count) == .success, ids.contains(displayID) {
                        found = CGDisplayBounds(displayID); break
                    }
                }
                usleep(50_000)
            }
            guard let found else {
                ASVDRelease(created); handle = nil; displayID = 0
                throw HostError.failure("display \(displayID) never joined the active display set", code: "display_activation_failed")
            }
            bounds = found
            return .object(["id": .number(Double(displayID)), "bounds": boundsJSON(found), "fake": .bool(false)])
        }
    }

    /// The descriptor-level termination callback, delivered asynchronously.
    /// It clears this generation's display identity under the lock - a stale
    /// callback from an older create is a no-op.
    func noteTerminated(generation: UInt64) {
        lock.withLock {
            guard generation == self.generation else { return }
            if let handle { ASVDRelease(handle) }
            handle = nil; displayID = 0; bounds = nil
        }
    }

    /// Whether the OS still reports this display as a real, independent seat:
    /// active AND online AND in the active display list AND not mirroring
    /// another display. A mirrored or dead display would make "private" input
    /// land on the user's own screens - it is treated as gone.
    func live() -> Bool {
        if fake { return true }
        guard displayID != 0 else { return false }
        guard CGDisplayIsActive(displayID) != 0, CGDisplayIsOnline(displayID) != 0 else { return false }
        guard CGDisplayMirrorsDisplay(displayID) == kCGNullDirectDisplay else { return false }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return false }
        return ids.contains(displayID)
    }

    func destroy() -> JSONValue {
        lock.withLock {
            let had = displayID != 0
            // A termination callback queued before this destroy is now stale.
            generation &+= 1
            if let handle { ASVDRelease(handle) }
            handle = nil; displayID = 0; bounds = nil; fake = false
            return .object(["released": .bool(had)])
        }
    }

    var terminated: Bool { lock.withLock { displayID == 0 } }

    func info() -> JSONValue {
        lock.withLock {
            guard let bounds, live() else { return .null }
            return .object(["id": .number(Double(displayID)), "bounds": boundsJSON(bounds), "fake": .bool(fake)])
        }
    }

    private func boundsJSON(_ rect: CGRect) -> JSONValue {
        .object(["x": .number(rect.origin.x), "y": .number(rect.origin.y),
                 "width": .number(rect.width), "height": .number(rect.height)])
    }
}

final class Host: @unchecked Sendable {
    let config: Config
    let token: String
    let owner = DisplayOwner()
    let startedAt = Date()
    /// Serializes the lifecycle: the accept loop, signal handlers and the
    /// janitor all read running/serverFD and all converge on stop(), which is
    /// idempotent - exactly one of them performs the teardown.
    private let stateLock = NSLock()
    private var _running = true
    private var _stopped = false
    private var _serverFD: Int32 = -1
    private var socketInode: UInt64 = 0

    init(config: Config) throws {
        self.config = config
        guard let raw = try? String(contentsOfFile: config.tokenFile, encoding: .utf8) else {
            throw HostError.failure("cannot read token file \(config.tokenFile)", code: "token_unreadable")
        }
        token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 32, token.allSatisfy({ $0.isHexDigit }) else {
            throw HostError.failure("token file is not an AgentSpace session token", code: "token_unreadable")
        }
    }

    private func running() -> Bool { stateLock.withLock { _running } }

    func reply(_ op: String, _ fields: [String: JSONValue]) -> JSONValue {
        var object = fields
        object["ok"] = .bool(true)
        object["op"] = .string(op)
        return .object(object)
    }
    func fail(_ op: String, _ code: String, _ message: String) -> JSONValue {
        .object(["ok": .bool(false), "op": .string(op),
                 "error": .object(["code": .string(code), "message": .string(message)])])
    }

    func dispatch(_ request: JSONValue) -> JSONValue {
        guard case .object(let fields) = request else {
            return fail("?", "protocol_error", "request must be a JSON object")
        }
        guard case .string(let op) = fields["op"] else {
            return fail("?", "protocol_error", "request needs a string op")
        }
        guard case .string(let supplied) = fields["token"], supplied == token else {
            return fail(op, "auth_failed", "bad or missing session token")
        }
        if let uuid = fields["workspaceUUID"], uuid != .string(config.workspaceUUID) {
            return fail(op, "workspace_mismatch", "request names a different workspace")
        }
        switch op {
        case "hello", "status":
            return reply(op, ["pid": .number(Double(getpid())), "protocol": .number(1),
                              "uptimeSeconds": .number(Date().timeIntervalSince(startedAt)),
                              "workspaceUUID": .string(config.workspaceUUID),
                              "display": owner.info()])
        case "create-display":
            do {
                var width = config.width, height = config.height, refresh = config.refresh, hiDPI = config.hiDPI
                func dimension(_ key: String) throws -> Int? {
                    guard let raw = fields[key], raw != .null else { return nil }
                    guard case .number(let v) = raw, v.isFinite, v.rounded() == v, (64...8192).contains(v) else {
                        throw HostError.failure("'\(key)' must be an integer 64...8192", code: "invalid_dimensions")
                    }
                    return Int(v)
                }
                if let v = try dimension("width") { width = v }
                if let v = try dimension("height") { height = v }
                if let raw = fields["refresh"], raw != .null {
                    guard case .number(let v) = raw, v.isFinite, v > 0, v <= 240 else {
                        throw HostError.failure("'refresh' must be a number 0<r<=240", code: "invalid_dimensions")
                    }
                    refresh = v
                }
                if let raw = fields["hiDPI"], raw != .null {
                    guard case .bool(let v) = raw else {
                        throw HostError.failure("'hiDPI' must be a boolean", code: "invalid_dimensions")
                    }
                    hiDPI = v ? 1 : 0
                }
                let display = try owner.create(width: width, height: height, refresh: refresh,
                                               hiDPI: hiDPI, name: config.name.isEmpty ? "AgentSpace" : config.name,
                                               serial: DisplayHost.displaySerial(for: config.workspaceUUID))
                return reply(op, ["display": display])
            } catch let error as HostError {
                return fail(op, error.code, error.description)
            } catch {
                return fail(op, "host_error", String(describing: error))
            }
        case "destroy-display":
            return reply(op, ["result": owner.destroy()])
        case "shutdown":
            return reply(op, ["result": owner.destroy(), "exiting": .bool(true)])
        default:
            return fail(op, "unknown_op", "unknown op '\(op)'")
        }
    }

    func writeReply(_ fd: Int32, _ response: JSONValue, _ deadline: ContinuousClock.Instant) {
        guard var out = try? JSONEncoder().encode(response) else { return }
        out.append(10)
        try? DisplayHost.writeAll(fd, out, deadline)
    }

    /// One connection: read a single newline-terminated request (256 KiB cap),
    /// dispatch, write one reply - everything bounded by one ABSOLUTE
    /// deadline so a slow-trickling client cannot hold the accept loop.
    func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(config.ioTimeout))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var line: Data?, scanned = 0
        var oversized = false
        while line == nil {
            guard (try? DisplayHost.waitIO(fd, Int16(POLLIN), deadline)) != nil else { return }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.count > 262_144 { oversized = true; break }
                if let cut = data[scanned...].firstIndex(of: 10) { line = Data(data[..<cut]) }
                scanned = data.count
                continue
            }
            if count == 0 { break }
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        if oversized {
            writeReply(fd, fail("?", "request_too_large", "request exceeds the 256 KiB cap"), deadline)
            return
        }
        guard let line else { return }
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            writeReply(fd, fail("?", "protocol_error", "request is not one JSON object"), deadline)
            return
        }
        let response = dispatch(request)
        writeReply(fd, response, deadline)
        if case .object(let fields) = response, fields["exiting"] == .bool(true) {
            stop()
        }
    }

    /// Idempotent serialized teardown. The socket file is unlinked only while
    /// it is still provably ours - same inode recorded at bind, same owner -
    /// so a replaced or foreign file is never deleted.
    func stop() {
        let fdToClose: Int32? = stateLock.withLock {
            if _stopped { return nil }
            _stopped = true; _running = false
            defer { _serverFD = -1 }
            return _serverFD >= 0 ? _serverFD : nil
        }
        _ = owner.destroy()
        if let fdToClose { Darwin.close(fdToClose) }
        var current = Darwin.stat()
        if socketInode != 0, lstat(config.socketPath, &current) == 0,
           current.st_ino == socketInode, current.st_uid == geteuid() {
            unlink(config.socketPath)
        }
    }

    /// Signal-driven shutdown: serialized through stop() so it composes safely
    /// with the janitor and the shutdown op, then a clean exit.
    func initiateShutdown() {
        stop()
        exit(0)
    }

    func run() throws -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global())
            source.setEventHandler { [weak self] in self?.initiateShutdown() }
            source.resume()
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HostError.failure("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = config.socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw HostError.failure("socket path too long", code: "socket_path_too_long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        unlink(path)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { throw HostError.failure("bind(\(path)) failed: \(errno)", code: "socket_bind_failed") }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { throw HostError.failure("listen() failed: \(errno)") }
        stateLock.withLock { _serverFD = fd }
        if let info = statInfo(path) { socketInode = info.st_ino }

        // Eager display from argv: a host that cannot create its display fails
        // its first hello honestly instead of hanging the spawn handshake.
        var startupError: String?
        do {
            _ = try owner.create(width: config.width, height: config.height, refresh: config.refresh,
                                 hiDPI: config.hiDPI, name: config.name.isEmpty ? "AgentSpace \(config.workspaceUUID)" : config.name,
                                 serial: DisplayHost.displaySerial(for: config.workspaceUUID))
        } catch { startupError = String(describing: error) }

        // Janitor: if our socket file or the workspace directory disappears the
        // workspace was torn down - do not keep a display alive past it. Bare
        // stop() would leave the main thread blocked in accept() forever, so
        // the janitor goes through initiateShutdown (stop + exit); stop() is
        // already idempotent against the signal and shutdown-op paths.
        DispatchQueue.global().async { [weak self] in
            while self?.running() == true {
                Thread.sleep(forTimeInterval: self?.config.janitorInterval ?? 5)
                guard let self, self.running() else { return }
                var current = Darwin.stat()
                guard lstat(path, &current) == 0, current.st_ino == self.socketInode else {
                    self.initiateShutdown()
                    return
                }
            }
        }

        if let startupError {
            fputs("agentspace-display-host: \(startupError)\n", stderr)
            // Serve the precise failure over the socket once so the spawn
            // handshake reports it instead of a bare exit code.
            let client = accept(fd, nil, nil)
            if client >= 0 { serveStartupError(client, startupError) }
            stop()
            return 2
        }

        while running() {
            let client = accept(fd, nil, nil)
            if client >= 0 { handle(client) }
            else if !running() { break }
            else { usleep(10_000) }
        }
        return 0
    }

    /// The startup-failure handshake: one bounded read, one reply carrying the
    /// display-creation error - the spawn path can then report the real cause.
    private func serveStartupError(_ fd: Int32, _ message: String) {
        defer { Darwin.close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(config.ioTimeout))
        var data = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var line: Data?, scanned = 0
        while line == nil {
            guard (try? DisplayHost.waitIO(fd, Int16(POLLIN), deadline)) != nil else { return }
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                if data.count > 262_144 { return }
                if let cut = data[scanned...].firstIndex(of: 10) { line = Data(data[..<cut]) }
                scanned = data.count
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            return
        }
        guard let line,
              let request = try? JSONDecoder().decode(JSONValue.self, from: line),
              case .object(let fields) = request,
              case .string(let supplied) = fields["token"], supplied == token else { return }
        writeReply(fd, fail("hello", "display_creation_failed", message), deadline)
    }
}

private func statInfo(_ path: String) -> Darwin.stat? {
    var info = Darwin.stat()
    return lstat(path, &info) == 0 ? info : nil
}

private func decode(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

do {
    let config = try Config.parse(Array(CommandLine.arguments.dropFirst()))
    if !config.logPath.isEmpty {
        let log = Darwin.open(config.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if log >= 0 { dup2(log, STDERR_FILENO) }
    }
    // Own session from here on: the caller's terminal process group can no
    // longer deliver Ctrl-C to us, and the CLI exiting doesn't drag us with
    // it. EPERM means we already lead our own group - equally detached.
    if setsid() == -1, errno != EPERM {
        FileHandle.standardError.write(Data("agentspace-display-host: setsid failed: \(String(cString: strerror(errno)))\n".utf8))
        exit(2)
    }
    let host = try Host(config: config)
    exit(try host.run())
} catch {
    FileHandle.standardError.write(Data("agentspace-display-host: \(error)\n".utf8))
    exit(2)
}
