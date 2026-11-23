import CryptoKit
import Darwin
import Foundation

/// AgentSpace's own display host: a persistent per-workspace helper process
/// (`agentspace-display-host`, built next to `agentspace`) that owns a
/// CGVirtualDisplay and answers a small authenticated unix-socket protocol.
/// The session token is a random hex string written 0600 inside the workspace's
/// 0700 state directory and sent on every request; the socket is 0600 under a
/// short, private per-user directory so deep workspace paths can never push it
/// past sockaddr_un's 104 bytes. All process-termination paths re-verify the
/// pid + start time recorded at launch - a recycled pid is never signalled, and
/// no pid <= 1 is ever signalled at all.
public enum DisplayHost {
    public static let spawnTimeout: TimeInterval = 12
    public static let requestTimeout: TimeInterval = 20
    public static let maximumReply = 8 * 1024 * 1024

    // MARK: Process identity + signalling policy

    /// The two system calls behind every identity check, injectable so the
    /// pid policy is exercised in tests without a real signal ever being sent.
    public struct Probe: Sendable {
        public var startTime: @Sendable (Int32) -> TimeInterval?
        public var signal: @Sendable (Int32, Int32) -> Int32
        public init(startTime: @escaping @Sendable (Int32) -> TimeInterval?,
                    signal: @escaping @Sendable (Int32, Int32) -> Int32) {
            self.startTime = startTime; self.signal = signal
        }
        public static let system = Probe(startTime: { processStartTime($0) },
                                         signal: { kill($0, $1) })
    }

    /// Only a pid that can name a single real userspace process is ever
    /// signalable: 0 and negatives address process GROUPS, 1 is launchd.
    public static func canSignal(_ pid: Int32) -> Bool { pid > 1 }

    /// Seconds-since-boot process start time, used to prove a pid still names
    /// the same process before it is ever signalled.
    public static func processStartTime(_ pid: Int32) -> TimeInterval? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6
    }

    /// Live process check that survives pid reuse: a signalable pid, a recorded
    /// finite positive start, alive AND the same start time the launch
    /// recorded (1 ms tolerance for the usec field).
    public static func alive(_ pid: Int32, start: TimeInterval?, probe: Probe = .system) -> Bool {
        guard canSignal(pid), let start, start.isFinite, start > 0,
              let current = probe.startTime(pid), probe.signal(pid, 0) == 0 else { return false }
        return abs(current - start) < 0.001
    }

    /// Signal a host only when the recorded pid+start still name the same
    /// process. Returns false - and sends nothing - otherwise.
    @discardableResult
    public static func terminate(_ pid: Int32, start: TimeInterval?, signal sig: Int32,
                                 probe: Probe = .system) -> Bool {
        guard alive(pid, start: start, probe: probe) else { return false }
        return probe.signal(pid, sig) == 0
    }

    // MARK: Environment

    /// The fake-display test hook is stripped from every child the CLI spawns:
    /// production code paths can never inherit a synthetic display, even when
    /// the caller's own environment carries the variable.
    public static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        var clean = environment
        clean.removeValue(forKey: "AGENTSPACE_DISPLAY_FAKE")
        return clean
    }

    // MARK: Paths

    /// SHA-256 (CryptoKit) hex of the workspace's canonical state directory -
    /// the per-workspace key for the socket directory name.
    static func socketHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public static func displaySerial(for workspaceUUID: String) -> UInt32 {
        let serial = SHA256.hash(data: Data(workspaceUUID.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return max(1, serial)
    }

    /// lstat-verified: a real (non-symlink) directory owned by this user with
    /// mode exactly 0700.
    static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = Darwin.stat()
        guard lstat(url.path, &info) == 0 else { return false }
        guard (info.st_mode & S_IFMT) == S_IFDIR, info.st_uid == getuid(),
              (info.st_mode & 0o777) == 0o700 else { return false }
        return true
    }

    /// Create-or-verify a directory that is ours alone: it must not exist as
    /// anything but a user-owned non-symlink 0700 directory.
    static func ensurePrivateDirectory(_ url: URL) throws {
        if isPrivateDirectory(url) { return }
        var info = Darwin.stat()
        if lstat(url.path, &info) == 0 {
            throw AgentSpaceError("socket_dir_unsafe",
                "\(url.path) exists but is not a user-owned 0700 directory; "
                + "refusing to place a display socket there")
        }
        guard errno == ENOENT else {
            throw AgentSpaceError("socket_dir_unsafe",
                "cannot inspect \(url.path): \(String(cString: strerror(errno)))")
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard isPrivateDirectory(url) else {
            throw AgentSpaceError("socket_dir_unsafe",
                "\(url.path) failed ownership/mode verification after creation")
        }
    }

    /// The short private parent every workspace socket dir lives under: the
    /// per-user TMPDIR when it verifies as a private 0700 directory, else a
    /// dedicated 0700 directory under /private/tmp. State roots can be
    /// arbitrarily deep; the socket parent never is.
    public static func socketParent() throws -> URL {
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
            let url = URL(fileURLWithPath: tmp, isDirectory: true)
            if isPrivateDirectory(url) { return url }
        }
        let fallback = URL(fileURLWithPath: "/private/tmp/asdh-\(getuid())", isDirectory: true)
        try ensurePrivateDirectory(fallback)
        return fallback
    }

    /// The per-workspace socket directory `dh-<hash>` under the private
    /// parent; created 0700 and re-verified every time (a foreign or
    /// weakened entry is refused, never reused).
    public static func socketDirectory(for workspace: String, store: StateStore) throws -> URL {
        let parent = try socketParent()
        let workspaceDir = try store.directory(workspace)
        let digest = socketHash(workspaceDir.standardizedFileURL.resolvingSymlinksInPath().path)
        let dir = parent.appendingPathComponent("dh-\(digest)", isDirectory: true)
        try ensurePrivateDirectory(dir)
        return dir
    }

    /// Deterministic short socket path: `<private parent>/dh-<hash>/dh.sock`,
    /// always under 104 bytes regardless of state-root depth.
    public static func socketPath(for workspace: String, store: StateStore) throws -> String {
        let path = try socketDirectory(for: workspace, store: store)
            .appendingPathComponent("dh.sock").path
        guard path.utf8.count < 104 else {
            throw AgentSpaceError("socket_path_too_long",
                "derived display socket path \(path) exceeds the 104-byte unix-socket limit")
        }
        return path
    }

    /// Remove our socket directory after the host is gone - only while it is
    /// still the user-owned 0700 directory we created, and only empty (rmdir):
    /// foreign entries are never deleted.
    public static func cleanupSocketDirectory(_ dir: URL) {
        guard isPrivateDirectory(dir) else { return }
        rmdir(dir.path)
    }

    public static func tokenPath(for workspace: String, store: StateStore) throws -> String {
        try store.directory(workspace).appendingPathComponent("display-token").path
    }

    /// The helper lives next to the CLI binary; an explicit
    /// AGENTSPACE_DISPLAY_HOST path is the only override. The binary's real
    /// location comes from the runtime executable path (Bundle /
    /// _NSGetExecutablePath with symlinks resolved) - never argv[0], which a
    /// PATH lookup or `exec -a` can lie about.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        if let explicit = environment["AGENTSPACE_DISPLAY_HOST"], !explicit.isEmpty {
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
        let sibling = binary.deletingLastPathComponent().appendingPathComponent("agentspace-display-host")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }

    public static func locateOrThrow() throws -> URL {
        guard let url = locate() else {
            throw AgentSpaceError("virtual_display_unavailable",
                "The virtual-display backend needs the AgentSpace display host "
                + "(agentspace-display-host), built next to the agentspace binary by "
                + "`swift build`; no external display service is used or required")
        }
        return url
    }

    // MARK: Bounded socket I/O

    /// poll(2) until `events` (or an error/hangup) fires on `fd`, bounded by an
    /// ABSOLUTE deadline - a peer that trickles one byte per interval cannot
    /// extend it, unlike a per-read SO_RCVTIMEO.
    public static func waitIO(_ fd: Int32, _ events: Int16,
                              _ deadline: ContinuousClock.Instant) throws {
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            let ms = remaining.components.seconds * 1000
                + remaining.components.attoseconds / 1_000_000_000_000_000
            guard ms > 0 else {
                throw AgentSpaceError("host_timeout", "display host socket deadline exceeded")
            }
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&pfd, 1, Int32(min(ms, 1000)))
            if ready > 0 {
                let mask = events | Int16(POLLERR) | Int16(POLLHUP) | Int16(POLLNVAL)
                if (pfd.revents & mask) != 0 { return }
                continue
            }
            if ready == 0 { continue }
            if errno == EINTR { continue }
            throw AgentSpaceError("host_io", "poll on display host socket failed: \(String(cString: strerror(errno)))")
        }
    }

    /// Write every byte of `data`, looping past EINTR and short writes until
    /// `deadline`; SIGPIPE is suppressed at the socket.
    public static func writeAll(_ fd: Int32, _ data: Data, _ deadline: ContinuousClock.Instant) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, !data.isEmpty else { return }
            var sent = 0
            while sent < data.count {
                try waitIO(fd, Int16(POLLOUT), deadline)
                let written = Darwin.write(fd, base + sent, data.count - sent)
                if written > 0 { sent += written; continue }
                if written < 0, errno == EINTR || errno == EAGAIN { continue }
                throw AgentSpaceError("host_io",
                    "display host write failed: \(written == 0 ? "no progress" : String(cString: strerror(errno)))")
            }
        }
    }

    /// One bounded request: connect → send `{token, op, ...}+\n` → read one
    /// newline-terminated reply under the reply cap, all inside a single
    /// absolute deadline. Errors map straight through the host's own
    /// error.code.
    public static func request(socketPath: String, token: String, op: String,
                        fields: [String: JSONValue] = [:], timeout: TimeInterval = requestTimeout) throws -> JSONValue {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSpaceError("host_socket", "socket() failed: \(errno)") }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AgentSpaceError("host_socket", "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } }
        if connected != 0 {
            if errno == EINPROGRESS {
                try waitIO(fd, Int16(POLLOUT), deadline)
                var soError: Int32 = 0
                var optLen = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &optLen)
                guard soError == 0 else {
                    throw AgentSpaceError("host_unreachable",
                        "display host socket \(socketPath): \(String(cString: strerror(soError)))")
                }
            } else {
                throw AgentSpaceError("host_unreachable",
                    "display host socket \(socketPath): \(String(cString: strerror(errno)))")
            }
        }
        var request: [String: JSONValue] = fields
        request["token"] = .string(token)
        request["op"] = .string(op)
        var data = try JSONEncoder().encode(JSONValue.object(request))
        data.append(10)
        try writeAll(fd, data, deadline)
        var reply = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var line: Data?, scanned = 0
        while line == nil {
            try waitIO(fd, Int16(POLLIN), deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                reply.append(contentsOf: buffer[0..<count])
                if reply.count > maximumReply {
                    throw AgentSpaceError("host_protocol", "display host reply exceeded the \(maximumReply)-byte cap")
                }
                // Scan only the newly-arrived bytes; the already-scanned prefix
                // provably holds no newline.
                if let cut = reply[scanned...].firstIndex(of: 10) { line = Data(reply[..<cut]) }
                scanned = reply.count
                continue
            }
            if count == 0 {
                throw AgentSpaceError("host_closed", "display host closed the connection without a reply")
            }
            if errno == EINTR || errno == EAGAIN { continue }
            throw AgentSpaceError("host_io", "display host read failed: \(String(cString: strerror(errno)))")
        }
        guard let line, let parsed = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            throw AgentSpaceError("host_protocol", "display host reply was not one JSON object")
        }
        return parsed
    }

    /// Checked call: unwraps ok:true replies, maps ok:false to an
    /// AgentSpaceError carrying the host's own error code.
    public static func call(socketPath: String, token: String, op: String,
                     fields: [String: JSONValue] = [:], timeout: TimeInterval = requestTimeout) throws -> JSONValue {
        let reply = try request(socketPath: socketPath, token: token, op: op, fields: fields, timeout: timeout)
        if field(reply, "ok") == .bool(true) { return reply }
        let error = field(reply, "error")
        let code = stringField(error, "code") ?? "host_error"
        let message = stringField(error, "message") ?? "display host rejected \(op)"
        throw AgentSpaceError(code == "auth_failed" ? "host_auth" : code, message)
    }

    // MARK: Spawn + handshake

    /// Spawn the helper with the display spec and wait for its handshake: the
    /// socket appears, `hello` authenticates, and the reply confirms pid and a
    /// live displayID.
    ///
    /// The child's identity (pid + start time) is recorded the instant
    /// `process.run()` returns and handed to `onLaunched` BEFORE the
    /// handshake, so a caller can persist it for recovery. The launch can only
    /// proceed when that identity is complete: a missing or invalid start time
    /// fails the spawn immediately and the freshly launched child - still
    /// owned through its `Process` object - is terminated, never left running
    /// as an untrackable process. Any later failure - early exit, bad reply,
    /// timeout - kills the proven child with that same recorded identity; a
    /// start time is never re-derived at termination time (a recomputed value
    /// would bless a recycled pid). `AGENTSPACE_DISPLAY_FAKE` is always
    /// stripped from the child's environment; only an explicit `fake:` opt-in
    /// sets it, for tests.
    @discardableResult
    public static func spawn(executable: URL, workspaceUUID: String, socketPath: String, tokenPath: String,
                      width: Int, height: Int, hiDPI: Bool, name: String, logPath: String,
                      environment: [String: String] = ProcessInfo.processInfo.environment,
                      fake: Bool = false, timeout: TimeInterval = spawnTimeout,
                      janitorInterval: TimeInterval? = nil,
                      probe: Probe = .system,
                      onLaunched: @Sendable (Int32, TimeInterval?) -> Void = { _, _ in }) throws -> (pid: Int32, start: TimeInterval, reply: JSONValue) {
        let process = Process()
        process.executableURL = executable
        var arguments = [
            "--workspace-uuid", workspaceUUID,
            "--socket", socketPath,
            "--token-file", tokenPath,
            "--width", String(width), "--height", String(height),
            "--hidpi", hiDPI ? "1" : "0", "--name", name, "--log", logPath,
        ]
        if let janitorInterval { arguments += ["--janitor-interval", String(janitorInterval)] }
        process.arguments = arguments
        var env = sanitizedEnvironment(environment)
        if fake { env["AGENTSPACE_DISPLAY_FAKE"] = "1" }
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw AgentSpaceError("host_spawn_failed", "Could not run \(executable.path): \(error)") }
        let pid = process.processIdentifier
        let launchStart = probe.startTime(pid)
        onLaunched(pid, launchStart)
        guard let start = launchStart, start.isFinite, start > 0 else {
            // Without a trustworthy identity the handshake can never confirm a
            // stoppable host - fail before it. `process` still names exactly
            // the child we just spawned: terminate through the Process object
            // itself, and only while it still reports that child running may
            // a bounded SIGKILL land on the same pid. No group signal, no
            // recomputed or guessed identity.
            if process.isRunning {
                process.terminate()
                var until = ContinuousClock.now.advanced(by: .milliseconds(400))
                while process.isRunning, ContinuousClock.now < until {
                    Thread.sleep(forTimeInterval: 0.02)
                }
                if process.isRunning {
                    _ = probe.signal(pid, SIGKILL)
                    until = ContinuousClock.now.advanced(by: .seconds(1))
                    while process.isRunning, ContinuousClock.now < until {
                        Thread.sleep(forTimeInterval: 0.02)
                    }
                }
            }
            if !process.isRunning { process.waitUntilExit() }
            throw AgentSpaceError("host_spawn_failed",
                "could not read the spawned host's start time; the child was terminated — "
                + "AgentSpace never tracks a helper it cannot re-identify")
        }
        let token = (try? String(contentsOfFile: tokenPath, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var lastError: AgentSpaceError?
        do {
            while ContinuousClock.now < deadline {
                if !process.isRunning {
                    throw lastError ?? AgentSpaceError("host_spawn_failed",
                        "display host exited during startup (see display-host.log next to the workspace)")
                }
                do {
                    let remaining = ContinuousClock.now.duration(to: deadline).components
                    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                    let reply = try request(socketPath: socketPath, token: token, op: "hello",
                                            fields: ["workspaceUUID": .string(workspaceUUID)],
                                            timeout: min(3, max(0.1, seconds)))
                    if field(reply, "ok") == .bool(true) {
                        guard let replyPID = numberField(reply, "pid"), Int32(exactly: replyPID) == pid else {
                            throw AgentSpaceError("host_protocol", "hello reply pid does not match the spawned host")
                        }
                        return (pid, start, reply)
                    }
                    let error = field(reply, "error")
                    throw AgentSpaceError(stringField(error, "code") ?? "host_error",
                        stringField(error, "message") ?? "display host rejected hello")
                } catch let error as AgentSpaceError {
                    lastError = error
                    // Connection races (socket not yet bound, host still
                    // starting) retry inside the spawn deadline; a definite
                    // auth/workspace failure fails the spawn immediately.
                    if !["host_unreachable", "host_io", "host_closed", "host_protocol", "host_timeout"].contains(error.code) { throw error }
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            throw AgentSpaceError("host_spawn_failed",
                "display host did not answer hello within \(Int(timeout))s: \(lastError?.description ?? "no socket")")
        } catch {
            // Whatever went wrong post-launch, the helper is ours and we hold
            // its recorded identity - it is never left half-owned. SIGTERM
            // first so the host can unlink its socket, then SIGKILL.
            if process.isRunning {
                _ = terminate(pid, start: start, signal: SIGTERM, probe: probe)
                let until = ContinuousClock.now.advanced(by: .milliseconds(400))
                while process.isRunning, ContinuousClock.now < until {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            if process.isRunning {
                _ = terminate(pid, start: start, signal: SIGKILL, probe: probe)
                let until = ContinuousClock.now.advanced(by: .seconds(1))
                while process.isRunning, ContinuousClock.now < until {
                    Thread.sleep(forTimeInterval: 0.02)
                }
            }
            if !process.isRunning { process.waitUntilExit() }
            throw error
        }
    }
}
