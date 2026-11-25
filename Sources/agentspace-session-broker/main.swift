import AgentSpaceCore
import AppKit
import Darwin
import Foundation

enum BrokerError: Error, CustomStringConvertible {
    case usage(String), failure(String, code: String = "broker_error")
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
    var key = ""
    var mode = ""
    var chromeRoot = ""
    var brokerDir = ""
    var socketPath = ""
    var profile = ""
    var chromeBinary = ""
    var logPath = ""
    var ioTimeout: TimeInterval = 120
    var janitorInterval: TimeInterval = 5
    var connectTimeout: TimeInterval = 15

    static func parse(_ args: [String]) throws -> Config {
        var config = Config()
        var i = 0
        while i < args.count {
            guard i + 1 < args.count else { throw BrokerError.usage("missing value for \(args[i])") }
            let value = args[i + 1]
            switch args[i] {
            case "--key": config.key = value
            case "--mode": config.mode = value
            case "--chrome-root": config.chromeRoot = value
            case "--broker-dir": config.brokerDir = value
            case "--socket": config.socketPath = value
            case "--profile": config.profile = value
            case "--chrome": config.chromeBinary = value
            case "--log": config.logPath = value
            case "--io-timeout": guard let v = Double(value), (0.5...300).contains(v) else { throw BrokerError.usage("--io-timeout must be 0.5...300 seconds") }; config.ioTimeout = v
            case "--janitor-interval": guard let v = Double(value), (0.2...60).contains(v) else { throw BrokerError.usage("--janitor-interval must be 0.2...60 seconds") }; config.janitorInterval = v
            case "--connect-timeout": guard let v = Double(value), (0.5...120).contains(v) else { throw BrokerError.usage("--connect-timeout must be 0.5...120 seconds") }; config.connectTimeout = v
            default: throw BrokerError.usage("unknown option \(args[i])")
            }
            i += 2
        }
        guard !config.key.isEmpty, !config.socketPath.isEmpty, !config.brokerDir.isEmpty,
              !config.chromeRoot.isEmpty, ["existing", "dedicated"].contains(config.mode) else {
            throw BrokerError.usage("--key, --mode existing|dedicated, --chrome-root, --broker-dir and --socket are required")
        }
        if config.mode == "dedicated", config.profile.isEmpty {
            throw BrokerError.usage("--profile is required for --mode dedicated")
        }
        return config
    }
}

enum SessionLog {
    static let allowedKeys: Set<String> = [
        "ts", "kind", "op", "ok", "code", "mode", "session",
    ]
    static func write(_ path: String, _ event: [String: JSONValue]) {
        var clean: [String: JSONValue] = ["ts": .number(Date().timeIntervalSince1970)]
        for (key, value) in event where allowedKeys.contains(key) { clean[key] = value }
        guard let data = try? JSONEncoder().encode(JSONValue.object(clean)) else { return }
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile(); fh.write(data); fh.write(Data([10])); try? fh.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile(); fh.write(data); fh.write(Data([10])); try? fh.close()
            }
        }
    }
}

final class Broker: @unchecked Sendable {
    let config: Config
    let token: String
    let startedAt = Date()
    let core: SessionCore
    let logPath: String
    private let stateLock = NSLock()
    private var _running = true
    private var _stopped = false
    private var _serverFD: Int32 = -1
    private var socketInode: UInt64 = 0
    private let lockFD: Int32
    private let journalLockFD: Int32
    private let clientSlots = DispatchSemaphore(value: 8)
    private let operationSlot = DispatchSemaphore(value: 1)
    private var signalSources: [DispatchSourceSignal] = []

    init(config: Config) throws {
        self.config = config
        logPath = config.brokerDir + "/session-log.jsonl"
        let parent = URL(fileURLWithPath: config.socketPath).deletingLastPathComponent()
        var parentInfo = Darwin.stat()
        guard lstat(parent.path, &parentInfo) == 0, parentInfo.st_uid == geteuid(),
              (parentInfo.st_mode & S_IFMT) == S_IFDIR, (parentInfo.st_mode & 0o777) == 0o700 else {
            throw BrokerError.failure("unsafe socket directory", code: "socket_dir_unsafe")
        }
        let acquired = Darwin.open(config.socketPath + ".lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard acquired >= 0 else { throw BrokerError.failure("cannot open broker lock", code: "broker_conflict") }
        guard flock(acquired, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(acquired)
            throw BrokerError.failure("another broker owns this socket namespace", code: "broker_conflict")
        }
        lockFD = acquired
        let journalLock = Darwin.open(config.brokerDir + "/broker.lock", O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard journalLock >= 0, flock(journalLock, LOCK_EX | LOCK_NB) == 0 else {
            if journalLock >= 0 { Darwin.close(journalLock) }
            Darwin.close(acquired)
            throw BrokerError.failure("another broker owns this journal", code: "broker_conflict")
        }
        journalLockFD = journalLock
        token = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        let tokenPath = config.brokerDir + "/broker-token"
        try Data(token.utf8).write(to: URL(fileURLWithPath: tokenPath), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenPath)

        var chromeExecutable: URL?
        if !config.chromeBinary.isEmpty {
            chromeExecutable = URL(fileURLWithPath: config.chromeBinary)
        } else if config.mode == "dedicated" {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                chromeExecutable = Bundle(url: app)?.executableURL
            }
            if chromeExecutable == nil {
                let fallback = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                if FileManager.default.isExecutableFile(atPath: fallback) {
                    chromeExecutable = URL(fileURLWithPath: fallback)
                }
            }
        }
        core = try SessionCore(config: SessionCore.Config(
            brokerKey: config.key,
            mode: SessionMode(rawValue: config.mode) ?? .shared,
            chromeRoot: URL(fileURLWithPath: config.chromeRoot),
            brokerDir: URL(fileURLWithPath: config.brokerDir),
            profileDir: config.profile.isEmpty ? nil : config.profile,
            chromeExecutable: chromeExecutable,
            launchTimeout: config.connectTimeout))
    }

    deinit { Darwin.close(lockFD); Darwin.close(journalLockFD) }

    func writeRecord() throws {
        let record = BrokerRecord(brokerKey: config.key,
                                  mode: SessionMode(rawValue: config.mode) ?? .shared,
                                  pid: getpid(), start: DisplayHost.processStartTime(getpid()) ?? 0,
                                  socketPath: config.socketPath, chromeRoot: config.chromeRoot)
        try JSONEncoder().encode(record)
            .write(to: URL(fileURLWithPath: config.brokerDir + "/broker.json"), options: .atomic)
    }

    private func running() -> Bool { stateLock.withLock { _running } }

    func fail(_ op: String, _ code: String, _ message: String, details: JSONValue? = nil) -> JSONValue {
        .object(["ok": .bool(false), "op": .string(op),
                 "error": .object(["code": .string(code), "message": .string(message), "details": details ?? .null])])
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
        guard operationSlot.wait(timeout: .now()) == .success else {
            return fail(op, "broker_busy", "another operation is still settling; no mutation was replayed")
        }
        defer { operationSlot.signal() }
        let box = ReplyBox()
        box.value = fail(op, "broker_error", "unreachable")
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                box.value = try await core.handle(op, request)
            } catch let error as AgentSpaceError {
                box.value = fail(op, error.code, error.description, details: error.details)
            } catch let error as BrokerError {
                box.value = fail(op, error.code, error.description)
            } catch {
                box.value = fail(op, "broker_error", "the broker operation failed; its receipts remain unsettled")
            }
        }
        sem.wait()
        var result = box.value
        var entry: [String: JSONValue] = ["kind": .string("rpc"), "op": .string(["hello","status","journal","open","perform","handoff","resume","close-session","shutdown"].contains(op) ? op : "invalid"),
                                        "mode": .string(config.mode)]
        if case .object(let o) = result {
            entry["ok"] = o["ok"] ?? .bool(false)
            if let code = stringField(field(result, "error"), "code") { entry["code"] = .string(code) }
        }
        if let s = stringField(request, "session"), s.count <= 128, s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) { entry["session"] = .string(s) }
        SessionLog.write(logPath, entry)
        if op == "shutdown", field(result, "ok") == .bool(true) {
            var o = result.objectValue ?? [:]
            o["exiting"] = .bool(true)
            result = .object(o)
        }
        return result
    }

    func writeReply(_ fd: Int32, _ response: JSONValue, _ deadline: ContinuousClock.Instant) {
        guard var out = try? JSONEncoder().encode(response) else { return }
        out.append(10)
        try? DisplayHost.writeAll(fd, out, deadline)
    }

    private func peerAllowed(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == geteuid()
    }

    func handle(_ fd: Int32) {
        defer { Darwin.close(fd) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(config.ioTimeout))
        guard peerAllowed(fd) else { return }
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
                if data.count > BrokerIPC.maximumRequest { oversized = true; break }
                if let cut = data[scanned...].firstIndex(of: 10) { line = Data(data[..<cut]) }
                scanned = data.count
                continue
            }
            if count == 0 { break }
            if errno == EINTR || errno == EAGAIN { continue }
            break
        }
        if oversized {
            writeReply(fd, fail("?", "request_too_large", "request exceeds the 1 MiB cap"), deadline)
            return
        }
        guard let line else { return }
        guard let request = try? JSONDecoder().decode(JSONValue.self, from: line) else {
            writeReply(fd, fail("?", "protocol_error", "request is not one JSON object"), deadline)
            return
        }
        let response = dispatch(request)
        writeReply(fd, response, deadline)
        if field(response, "exiting") == .bool(true) { initiateShutdown() }
    }

    func stop() {
        let fdToClose: Int32? = stateLock.withLock {
            if _stopped { return nil }
            _stopped = true
            var current = Darwin.stat()
            if socketInode != 0, lstat(config.socketPath, &current) == 0,
               current.st_ino == socketInode, current.st_uid == geteuid() {
                unlink(config.socketPath)
            }
            _running = false
            defer { _serverFD = -1 }
            return _serverFD >= 0 ? _serverFD : nil
        }
        if let fdToClose { Darwin.close(fdToClose) }
    }

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
            signalSources.append(source)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerError.failure("socket() failed: \(errno)") }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = config.socketPath
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            throw BrokerError.failure("socket path too long", code: "socket_path_too_long")
        }
        if let info = statInfo(path) {
            guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else {
                throw BrokerError.failure("refusing to replace an unsafe socket path", code: "socket_path_unsafe")
            }
            unlink(path)
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
        guard bound == 0 else { throw BrokerError.failure("bind(\(path)) failed: \(errno)", code: "socket_bind_failed") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { throw BrokerError.failure("listen() failed: \(errno)") }
        stateLock.withLock { _serverFD = fd }
        if let info = statInfo(path) { socketInode = info.st_ino }

        let core = self.core
        Task {
            do { try await core.connectBrowser() }
            catch {
                fputs("agentspace-session-broker: browser connect: \(error)\n", stderr)
            }
            try? self.writeRecord()
        }

        DispatchQueue.global().async { [weak self] in
            while self?.running() == true {
                Thread.sleep(forTimeInterval: self?.config.janitorInterval ?? 5)
                guard let self, self.running() else { return }
                var current = Darwin.stat()
                guard lstat(path, &current) == 0, current.st_ino == self.socketInode else {
                    self.initiateShutdown()
                    return
                }
                var brokerStat = Darwin.stat()
                guard lstat(self.config.brokerDir, &brokerStat) == 0 else {
                    self.initiateShutdown()
                    return
                }
                let sem = DispatchSemaphore(value: 0)
                let box = FlagBox()
                Task {
                    box.value = await self.core.shouldExitWhenIdle
                    sem.signal()
                }
                sem.wait()
                if box.value {
                    SessionLog.write(self.logPath, ["kind": .string("idle_shutdown"),
                                                    "mode": .string(self.config.mode)])
                    let closed = DispatchSemaphore(value: 0)
                    Task { await self.core.closeConnection(); closed.signal() }
                    closed.wait()
                    self.initiateShutdown()
                    return
                }
            }
        }

        while running() {
            let client = accept(fd, nil, nil)
            if client >= 0 {
                if clientSlots.wait(timeout: .now()) == .success {
                    DispatchQueue.global().async { [self] in
                        defer { clientSlots.signal() }
                        handle(client)
                    }
                } else { Darwin.close(client) }
            }
            else if !running() { break }
            else { usleep(10_000) }
        }
        return 0
    }
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

private final class ReplyBox: @unchecked Sendable { var value: JSONValue = .null }
private final class FlagBox: @unchecked Sendable { var value = false }

private func statInfo(_ path: String) -> Darwin.stat? {
    var info = Darwin.stat()
    return lstat(path, &info) == 0 ? info : nil
}

do {
    let config = try Config.parse(Array(CommandLine.arguments.dropFirst()))
    if !config.logPath.isEmpty {
        let log = Darwin.open(config.logPath, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        if log >= 0 { dup2(log, STDERR_FILENO) }
    }
    if setsid() == -1, errno != EPERM {
        FileHandle.standardError.write(Data("agentspace-session-broker: setsid failed: \(String(cString: strerror(errno)))\n".utf8))
        exit(2)
    }
    if statInfo(config.brokerDir) == nil {
        try FileManager.default.createDirectory(atPath: config.brokerDir, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    guard let info = statInfo(config.brokerDir), info.st_uid == geteuid(),
          (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700 else {
        throw BrokerError.failure("broker state must be a user-owned 0700 directory", code: "broker_dir_unsafe")
    }
    let broker = try Broker(config: config)
    exit(try broker.run())
} catch {
    FileHandle.standardError.write(Data("agentspace-session-broker: \(error)\n".utf8))
    exit(2)
}
