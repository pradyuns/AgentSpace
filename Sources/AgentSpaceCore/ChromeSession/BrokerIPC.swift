import Foundation

/// Client side of the broker unix-socket protocol, plus broker spawn/ensure.
/// Wire shape mirrors the display host: one newline-terminated JSON object
/// per request carrying `token` + `op`, one JSON object reply, bounded by an
/// absolute deadline and a frame cap. Every request re-sends the token; the
/// broker additionally checks the peer uid. Before trusting a socket the
/// client verifies the broker's pid+start against the broker.json record it
/// wrote, so a stale socket or recycled pid can never be replayed.
public enum BrokerIPC {
    public static let requestTimeout: TimeInterval = 90
    public static let maximumRequest = 1 << 20
    public static let maximumReply = 16 << 20
    public static let spawnTimeout: TimeInterval = 22

    public static func request(socketPath: String, token: String, op: String,
                               fields: [String: JSONValue] = [:],
                               timeout: TimeInterval = requestTimeout, expectedPeer: ProcessIdentity? = nil) throws -> JSONValue {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSpaceError("broker_socket", "socket() failed: \(errno)") }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard socketPath.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw AgentSpaceError("broker_socket", "socket path too long")
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            if errno == EINPROGRESS {
                try DisplayHost.waitIO(fd, Int16(POLLOUT), deadline)
                var soError: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
                guard soError == 0 else {
                    throw AgentSpaceError("broker_unreachable",
                        "session broker socket \(socketPath): \(String(cString: strerror(soError)))")
                }
            } else {
                throw AgentSpaceError("broker_unreachable",
                    "session broker socket \(socketPath): \(String(cString: strerror(errno)))")
            }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else {
            throw AgentSpaceError("broker_identity", "the IPC peer is not the current user")
        }
        if let expectedPeer {
            var peerPID: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0,
                  peerPID == expectedPeer.pid, DisplayHost.alive(peerPID, start: expectedPeer.start) else {
                throw AgentSpaceError("broker_identity", "the IPC peer does not match the bound broker process")
            }
        }
        var request = fields
        request["token"] = .string(token)
        request["op"] = .string(op)
        var data = try JSONEncoder().encode(JSONValue.object(request))
        guard data.count <= maximumRequest else {
            throw AgentSpaceError("broker_protocol", "request exceeds the \(maximumRequest)-byte cap")
        }
        data.append(10)
        try DisplayHost.writeAll(fd, data, deadline)
        var reply = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        var line: Data?, scanned = 0
        while line == nil {
            try DisplayHost.waitIO(fd, Int16(POLLIN), deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                reply.append(contentsOf: buffer[0..<count])
                if reply.count > maximumReply {
                    throw AgentSpaceError("broker_protocol", "broker reply exceeded the \(maximumReply)-byte cap")
                }
                if let cut = reply[scanned...].firstIndex(of: 10) { line = Data(reply[..<cut]) }
                scanned = reply.count
                continue
            }
            if count == 0 {
                throw AgentSpaceError("broker_closed", "session broker closed the connection without a reply")
            }
            if errno == EINTR || errno == EAGAIN { continue }
            throw AgentSpaceError("broker_io", "broker read failed: \(String(cString: strerror(errno)))")
        }
        guard let line, let parsed = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            throw AgentSpaceError("broker_protocol", "broker reply was not one JSON object")
        }
        return parsed
    }

    /// Checked call: ok:true unwraps, ok:false maps the broker's own code.
    public static func call(socketPath: String, token: String, op: String,
                            fields: [String: JSONValue] = [:],
                            timeout: TimeInterval = requestTimeout, expectedPeer: ProcessIdentity? = nil) throws -> JSONValue {
        let reply = try request(socketPath: socketPath, token: token, op: op, fields: fields, timeout: timeout, expectedPeer: expectedPeer)
        if field(reply, "ok") == .bool(true) { return reply }
        let error = field(reply, "error")
        throw AgentSpaceError(stringField(error, "code") ?? "broker_error",
                              stringField(error, "message") ?? "session broker rejected \(op)",
                              details: field(error, "details") == .null ? nil : field(error, "details"))
    }

    /// The live broker record for a key, or nil. The record's pid+start are
    /// re-verified against the running process; a stale file is never
    /// trusted.
    public static func liveRecord(_ store: StateStore, key: String,
                                  probe: DisplayHost.Probe = .system) -> BrokerRecord? {
        let dir = SessionBroker.brokerDirectory(store, key: key)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("broker.json")),
              let record = try? JSONDecoder().decode(BrokerRecord.self, from: data),
              record.brokerKey == key,
              record.socketPath == (try? SessionBroker.socketPath(for: key, stateRoot: store.root)),
              DisplayHost.alive(record.pid, start: record.start, probe: probe) else { return nil }
        return record
    }

    public static func token(_ store: StateStore, key: String) throws -> String {
        let path = SessionBroker.brokerDirectory(store, key: key).appendingPathComponent("broker-token").path
        guard let token = (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            throw AgentSpaceError("broker_unavailable", "session broker token is missing for \(key)")
        }
        return token
    }

    /// Ensure a live broker for `key`: reuse the recorded one when it is
    /// still the same process, else spawn and handshake-verify it. The
    /// freshly launched child's pid+start are verified against its own
    /// hello reply before it is ever talked to; the broker itself writes
    /// broker.json + broker-token inside its private directory during
    /// startup.
    @discardableResult
    public static func ensure(_ store: StateStore, key: String, mode: SessionMode, chromeRoot: URL,
                              profileDir: String? = nil,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              probe: DisplayHost.Probe = .system,
                              timeout: TimeInterval = spawnTimeout) throws -> BrokerRecord {
        if let record = liveRecord(store, key: key, probe: probe) { return record }
        let dir = SessionBroker.brokerDirectory(store, key: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let socketPath = try SessionBroker.socketPath(for: key, stateRoot: store.root)
        guard let executable = SessionBroker.locate(environment: environment) else {
            throw AgentSpaceError("broker_unavailable",
                "agentspace-session-broker is not built next to the agentspace binary")
        }
        let process = Process()
        process.executableURL = executable
        var arguments = ["--key", key, "--mode", mode.rawValue,
                         "--chrome-root", chromeRoot.path, "--broker-dir", dir.path,
                         "--socket", socketPath]
        if let profileDir { arguments += ["--profile", profileDir] }
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { throw AgentSpaceError("broker_spawn_failed", "could not run the session broker: \(error)") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var lastError: AgentSpaceError?
        while ContinuousClock.now < deadline {
            if let record = liveRecord(store, key: key, probe: probe) {
                do {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    let seconds = Double(remaining.components.seconds)
                        + Double(remaining.components.attoseconds) / 1e18
                    let token = try self.token(store, key: key)
                    let reply = try request(socketPath: record.socketPath, token: token, op: "hello",
                                            timeout: min(3, max(0.1, seconds)), expectedPeer: ProcessIdentity(pid: record.pid, start: record.start))
                    if field(reply, "ok") == .bool(true),
                       let pid = int32Field(reply, "pid"), pid == record.pid,
                       stringField(reply, "brokerKey") == key {
                        return record
                    }
                    if let code = stringField(field(reply, "error"), "code") {
                        throw AgentSpaceError(code, stringField(field(reply, "error"), "message") ?? "connection unresolved")
                    }
                    lastError = AgentSpaceError("broker_protocol", "broker hello did not confirm its record")
                } catch let error as AgentSpaceError {
                    lastError = error
                    if !["broker_unreachable", "broker_io", "broker_closed",
                         "broker_protocol", "broker_timeout", "broker_unavailable"].contains(error.code) {
                        throw error
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AgentSpaceError("broker_spawn_failed",
            "session broker did not come up for \(key): \(lastError?.description ?? "no live record")")
    }
}
