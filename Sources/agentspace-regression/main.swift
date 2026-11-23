import AgentSpaceCore
import ASDisplayShim
import Darwin
import Foundation

// agentspace-regression: the no-XCTest safety suite for the native
// virtual-display path. Every check here is read-only or drives a FAKE helper
// (AGENTSPACE_DISPLAY_FAKE is set only through the explicit `fake:` spawn
// opt-in) - no real display is ever created and no input is ever injected.
// Print one PASS/FAIL line per check and exit nonzero on any failure.

signal(SIGPIPE, SIG_IGN)

nonisolated(unsafe) var passed = 0
nonisolated(unsafe) var failed = 0
nonisolated(unsafe) var failures: [String] = []

func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    if condition {
        passed += 1
        print("PASS \(name)")
    } else {
        failed += 1
        failures.append(name)
        print("FAIL \(name) — \(detail)")
    }
}

final class Signals: @unchecked Sendable {
    var calls: [(Int32, Int32)] = []
    let lock = NSLock()
    func record(_ pid: Int32, _ sig: Int32) -> Int32 {
        lock.withLock { calls.append((pid, sig)) }
        return 0
    }
}

final class LaunchBox: @unchecked Sendable {
    var pid: Int32?
    var start: TimeInterval?
    let lock = NSLock()
    func record(pid: Int32, start: TimeInterval?) {
        lock.withLock { self.pid = pid; self.start = start }
    }
    func identity() -> (Int32, TimeInterval?)? {
        lock.withLock { pid.map { ($0, start) } }
    }
}

func makeState(hostPID: Int32?, hostStart: TimeInterval?, displayID: UInt32? = nil,
               pending: Bool = false) -> VirtualDisplayState {
    var state = VirtualDisplayState(hostPID: hostPID, hostStart: hostStart,
                                    socketPath: "/tmp/sock", token: "t",
                                    workspaceUUID: "ws", displayID: displayID,
                                    bounds: nil, preset: nil)
    state.pendingCreate = pending
    return state
}

// MARK: 1. Signal policy - injected probe, no real signal ever sent

do {
    let sink = Signals()
    let probe = DisplayHost.Probe(startTime: { _ in 500.0 },
                                  signal: { pid, sig in sink.record(pid, sig) })
    for pid: Int32 in [-1, -42, 0, 1] {
        check("canSignal rejects \(pid)", !DisplayHost.canSignal(pid))
        check("alive refuses pid \(pid)", !DisplayHost.alive(pid, start: 500, probe: probe))
        check("terminate refuses pid \(pid)", !DisplayHost.terminate(pid, start: 500, signal: SIGTERM, probe: probe))
    }
    for bad: TimeInterval? in [nil, 0, -3, .nan, .infinity] {
        check("alive refuses missing/invalid start", !DisplayHost.alive(4242, start: bad, probe: probe))
    }
    // PID-reuse: the process exists but its start time does not match the
    // recorded launch identity - only a harmless kill(pid,0) probe may fire.
    sink.lock.withLock { sink.calls = [] }
    check("alive detects recycled pid", !DisplayHost.alive(4242, start: 999, probe: probe))
    check("recycled pid only probes with signal 0",
          sink.calls.allSatisfy { $0.1 == 0 } && !sink.calls.isEmpty)
    sink.lock.withLock { sink.calls = [] }
    check("terminate sends SIGTERM to verified identity",
          DisplayHost.terminate(4242, start: 500, signal: SIGTERM, probe: probe))
    check("terminate sent one SIGTERM after the probe",
          sink.calls.count == 2 && sink.calls[0].0 == 4242 && sink.calls[0].1 == 0
            && sink.calls[1].0 == 4242 && sink.calls[1].1 == SIGTERM, "\(sink.calls)")
}

// MARK: 2. State decoding - pending vs established identity rules

do {
    let base = """
    {"hostPID":%PID%,"hostStart":%START%,"socketPath":"/tmp/s","token":"t",
     "workspaceUUID":"ws","displayID":null,"bounds":null,"preset":null,
     "backend":"native","createdAt":1,"pendingCreate":%PENDING%,"observations":[]}
    """
    func decoded(pid: String, start: String, pending: Bool) -> VirtualDisplayState? {
        let json = base.replacingOccurrences(of: "%PID%", with: pid)
            .replacingOccurrences(of: "%START%", with: start)
            .replacingOccurrences(of: "%PENDING%", with: pending ? "true" : "false")
        return try? JSONDecoder().decode(VirtualDisplayState.self, from: Data(json.utf8))
    }
    check("pending record with no pid decodes",
          decoded(pid: "null", start: "null", pending: true) != nil)
    check("pending record with pid 0 normalizes identity",
          decoded(pid: "0", start: "1", pending: true)?.hostPID == nil)
    check("pending record with pid 1 normalizes identity",
          decoded(pid: "1", start: "1", pending: true)?.hostPID == nil)
    check("pending record missing start normalizes identity",
          decoded(pid: "4242", start: "null", pending: true)?.hostPID == nil)
    check("established record keeps real identity",
          decoded(pid: "4242", start: "500", pending: false)?.hostPID == 4242)
    check("established record rejects missing pid",
          decoded(pid: "null", start: "500", pending: false) == nil)
    check("established record rejects pid 0",
          decoded(pid: "0", start: "500", pending: false) == nil)
    check("established record rejects pid 1",
          decoded(pid: "1", start: "500", pending: false) == nil)
    check("established record rejects missing start",
          decoded(pid: "4242", start: "null", pending: false) == nil)
}

// MARK: 3. Environment sanitize - the fake hook never reaches a CLI-spawned child

do {
    let clean = DisplayHost.sanitizedEnvironment(["AGENTSPACE_DISPLAY_FAKE": "1", "PATH": "/bin", "X": "y"])
    check("sanitized environment drops AGENTSPACE_DISPLAY_FAKE",
          clean["AGENTSPACE_DISPLAY_FAKE"] == nil)
    check("sanitized environment keeps other entries",
          clean["PATH"] == "/bin" && clean["X"] == "y")
}

// MARK: 4. Helper discovery - real executable path, explicit override only

do {
    check("locate() finds the sibling agentspace-display-host",
          DisplayHost.locate() != nil,
          "expected agentspace-regression to be built next to the host")
    check("explicit AGENTSPACE_DISPLAY_HOST override wins",
          DisplayHost.locate(environment: ["AGENTSPACE_DISPLAY_HOST": "/bin/ls"])?.path == "/bin/ls")
    check("non-executable override is rejected",
          DisplayHost.locate(environment: ["AGENTSPACE_DISPLAY_HOST": "/definitely/not/here"]) == nil)
}

// MARK: 5. Socket paths stay short under a deep state root

do {
    var deep = NSTemporaryDirectory() + "asr-deep"
    for _ in 0..<8 { deep += "/very-long-directory-component-xx" }
    let store = try StateStore(root: URL(fileURLWithPath: deep))
    check("state lock is close-on-exec", store.lockFileDescriptorIsCloseOnExec())
    let longName = String(repeating: "w", count: 80)
    let path = try DisplayHost.socketPath(for: longName, store: store)
    check("socket path under 104 bytes with deep root + long name",
          path.utf8.count < 104, "\(path.utf8.count) bytes: \(path)")
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    check("socket directory is user-owned 0700", stat0(dir) == 0o700)
    check("token stays inside the workspace state directory",
          try DisplayHost.tokenPath(for: longName, store: store).contains(deep))
    DisplayHost.cleanupSocketDirectory(dir)
    try? FileManager.default.removeItem(atPath: NSTemporaryDirectory() + "asr-deep")
}

// MARK: 6. Bounded socket client - peer close, silence, trickle, oversize

func serveOnce(_ behavior: @escaping @Sendable (Int32) -> Void, _ body: (String) throws -> Void) throws {
    let dir = NSTemporaryDirectory() + "asr-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/srv.sock"
    let srv = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        path.withCString { strncpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), $0, 103) }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(srv, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, listen(srv, 1) == 0 else {
        throw AgentSpaceError("test_setup", "rogue server could not bind \(path)")
    }
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        let client = accept(srv, nil, nil)
        if client >= 0 { behavior(client); Darwin.close(client) }
        Darwin.close(srv)
        done.signal()
    }
    thread.start()
    try body(path)
    _ = done.wait(timeout: .now() + 10)
}

func errorCode(_ body: () throws -> JSONValue) -> String {
    do { _ = try body(); return "no_error" }
    catch let error as AgentSpaceError { return error.code }
    catch { return String(describing: error) }
}

do {
    // Peer closes as soon as we connect - the request must fail, not hang.
    try serveOnce({ _ in usleep(50_000) }) { path in
        let code = errorCode { try DisplayHost.request(socketPath: path, token: "t", op: "hello", timeout: 3) }
        check("peer close before write surfaces an error",
              ["host_closed", "host_io"].contains(code), code)
    }
    // Silent peer: absolute deadline bounds the read.
    try serveOnce({ _ in sleep(3) }) { path in
        let started = Date()
        let code = errorCode { try DisplayHost.request(socketPath: path, token: "t", op: "hello", timeout: 1) }
        check("silent peer hits the absolute deadline", code == "host_timeout", code)
        check("deadline elapsed roughly on time",
              Date().timeIntervalSince(started) < 4, "\(Date().timeIntervalSince(started))")
    }
    // Trickle: a byte every 300 ms can never outrun the 1 s absolute deadline.
    try serveOnce({ fd in
        for _ in 0..<30 { Darwin.write(fd, "x", 1); usleep(300_000) }
    }) { path in
        let code = errorCode { try DisplayHost.request(socketPath: path, token: "t", op: "hello", timeout: 1) }
        check("slow-trickle peer cannot extend the deadline",
              code == "host_timeout", code)
    }
    // Oversize reply: the 8 MiB cap triggers before the client waits forever.
    try serveOnce({ fd in
        var chunk = Data(repeating: 0x41, count: 1 << 20)
        for _ in 0..<(DisplayHost.maximumReply / chunk.count + 2) {
            _ = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
        }
        chunk = Data()
    }) { path in
        let code = errorCode { try DisplayHost.request(socketPath: path, token: "t", op: "hello", timeout: 10) }
        check("oversize reply hits the reply cap", code == "host_protocol", code)
    }
    // Well-formed reply decodes.
    try serveOnce({ fd in
        let reply = Data(#"{"ok":true,"pid":4242}"#.utf8) + Data([10])
        _ = reply.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    }) { path in
        let reply = try? DisplayHost.request(socketPath: path, token: "t", op: "hello", timeout: 3)
        check("well-formed reply decodes", reply.map { field($0, "ok") } == .bool(true))
    }
}

// MARK: 7. Shim - read-only probe + name echo

do {
    var out = [CChar](repeating: 0, count: 64)
    check("ASVDProbeName echoes a UTF-8 name",
          ASVDProbeName("AgentSpace ✓", &out, out.count) != 0
            && decode(out) == "AgentSpace ✓",
          decode(out))
    out = [CChar](repeating: 0, count: 64)
    check("ASVDProbeName handles NULL name",
          ASVDProbeName(nil, &out, out.count) != 0 && decode(out) == "")
    var err = [CChar](repeating: 0, count: 512)
    let probe = ASVDProbe(&err, err.count)
    // The probe must never crash and must return a definitive verdict; a
    // missing private API on a CLT-only runner is a legitimate "unavailable".
    print("INFO ASVDProbe=\(probe != 0 ? "available" : "unavailable") \(decode(err))")
    check("ASVDProbe returns a verdict without crashing", true)
}

// MARK: 8. End-to-end fake host - the one place AGENTSPACE_DISPLAY_FAKE exists

do {
    guard let executable = DisplayHost.locate() else {
        check("fake host spawn", false, "agentspace-display-host not built next to this binary")
        throw AgentSpaceError("test_setup", "host binary missing")
    }
    let dir = NSTemporaryDirectory() + "asr-fake-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let socketPath = dir + "/dh.sock"
    let tokenPath = dir + "/token"
    let token = String(repeating: "ab", count: 32)
    try Data(token.utf8).write(to: URL(fileURLWithPath: tokenPath))
    chmod(tokenPath, 0o600)

    let launched = LaunchBox()
    let spawned = try DisplayHost.spawn(
        executable: executable, workspaceUUID: "regression", socketPath: socketPath,
        tokenPath: tokenPath, width: 640, height: 480, hiDPI: false,
        name: "regression-fake", logPath: dir + "/host.log",
        environment: ["PATH": "/usr/bin:/bin"], fake: true, timeout: 10,
        onLaunched: { pid, start in launched.record(pid: pid, start: start) })
    check("fake spawn records pid+start before handshake",
          launched.identity()?.0 == spawned.pid && spawned.pid > 1)
    check("fake spawn identity is alive",
          DisplayHost.alive(spawned.pid, start: spawned.start))
    let display = field(spawned.reply, "display")
    check("fake host marks its display synthetic",
          field(display, "fake") == .bool(true))
    // verifyHello must reject the synthetic display - fake is never a seat.
    do {
        _ = try VirtualDisplay.verifyHello(
            makeState(hostPID: spawned.pid, hostStart: spawned.start), reply: spawned.reply)
        check("verifyHello rejects a fake display", false, "no throw")
    } catch let error as AgentSpaceError {
        check("verifyHello rejects a fake display", error.code == "synthetic_display", error.code)
    }
    // The host answers status and shuts down cleanly with its recorded identity.
    let status = try? DisplayHost.call(socketPath: socketPath, token: token, op: "status",
                                       fields: ["workspaceUUID": .string("regression")], timeout: 5)
    check("fake host status answers", status.map { field($0, "ok") } == .bool(true))
    _ = try? DisplayHost.call(socketPath: socketPath, token: token, op: "shutdown",
                              fields: ["workspaceUUID": .string("regression")], timeout: 5)
    var gone = false
    for _ in 0..<50 where !gone {
        usleep(100_000)
        gone = !DisplayHost.alive(spawned.pid, start: spawned.start)
    }
    check("fake host exits after authenticated shutdown", gone)
    check("host removed its socket", !FileManager.default.fileExists(atPath: socketPath))
    check("launch recorded a start identity", launched.identity()?.1 != nil)
}

// MARK: 9. Spawn failure cleanup - a helper that never handshakes is killed

do {
    guard let executable = DisplayHost.locate() else {
        check("spawn-failure cleanup", false, "host binary missing")
        throw AgentSpaceError("test_setup", "host binary missing")
    }
    let dir = NSTemporaryDirectory() + "asr-bad-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // A token file the host rejects (too short) → the host exits during
    // startup; the spawn must fail AND the child must be dead, not leaked.
    let tokenPath = dir + "/token"
    try Data("short".utf8).write(to: URL(fileURLWithPath: tokenPath))
    let launched = LaunchBox()
    var threw = false
    do {
        _ = try DisplayHost.spawn(executable: executable, workspaceUUID: "regression",
                                  socketPath: dir + "/dh.sock", tokenPath: tokenPath,
                                  width: 640, height: 480, hiDPI: false, name: "x",
                                  logPath: dir + "/host.log", environment: ["PATH": "/usr/bin:/bin"],
                                  timeout: 6, onLaunched: { pid, start in
            launched.record(pid: pid, start: start) })
    } catch { threw = true }
    check("bad-token spawn fails", threw)
    if let (pid, start) = launched.identity(), pid > 1 {
        var gone = false
        for _ in 0..<50 where !gone {
            usleep(100_000)
            gone = !DisplayHost.alive(pid, start: start)
        }
        check("failed spawn leaves no live helper", gone, "pid \(pid) still alive")
    } else {
        check("failed spawn leaves no live helper", true)
    }
}

// MARK: 10. Stop ordering - apps die before the session, failures keep state

do {
    var order: [String] = []
    let (method, _) = try await WorkspaceController.stopSequence(
        terminateApps: { order.append("apps"); return ["terminated": .array([])] },
        destroySession: { order.append("session"); return ["session": .bool(true)] },
        cleanupLocal: { order.append("local"); return ["cleaned": .bool(true)] })
    check("stop order: apps then session then local",
          order == ["apps", "session", "local"], "\(order)")
    check("stop method names the real order",
          method.hasPrefix("terminate-apps") && method.contains("session-destroy")
            && method.hasSuffix("cleanup-local"), method)
    // No session → method stays honest.
    let (plainMethod, _) = try await WorkspaceController.stopSequence(
        terminateApps: { [:] }, destroySession: { nil }, cleanupLocal: { [:] })
    check("sessionless stop method has no destroy stage",
          plainMethod == "terminate-apps+cleanup-local", plainMethod)
    // App teardown failure: the session destroy must never run - the host is
    // retained for retry.
    order = []
    var sessionRan = false, localRan = false
    _ = try? await WorkspaceController.stopSequence(
        terminateApps: { order.append("apps")
            throw AgentSpaceError("processes_remaining", "still running") },
        destroySession: { sessionRan = true; return nil },
        cleanupLocal: { localRan = true; return [:] })
    check("failed app teardown keeps the host: session+local never ran",
          order == ["apps"] && !sessionRan && !localRan, "\(order)")
    // Session failure: local state is never cleared underneath it.
    order = []
    _ = try? await WorkspaceController.stopSequence(
        terminateApps: { order.append("apps"); return [:] },
        destroySession: { order.append("session")
            throw AgentSpaceError("host_unreachable", "no answer") },
        cleanupLocal: { order.append("local"); return [:] })
    check("failed session destroy keeps local state",
          order == ["apps", "session"], "\(order)")
}

// MARK: 11. Spawn without a provable start time - child cleaned, record safe

do {
    guard let executable = DisplayHost.locate() else {
        check("nil-start spawn cleanup", false, "host binary missing")
        throw AgentSpaceError("test_setup", "host binary missing")
    }
    let dir = NSTemporaryDirectory() + "asr-nilstart-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let tokenPath = dir + "/token"
    try Data(String(repeating: "cd", count: 32).utf8).write(to: URL(fileURLWithPath: tokenPath))
    // The injected provider can never prove a start time - spawn must fail
    // before the handshake AND the freshly launched child must be gone.
    // The signal channel stays real so the cleanup actually happens.
    let nilStart = DisplayHost.Probe(startTime: { _ in nil }, signal: { kill($0, $1) })
    let launched = LaunchBox()
    var threw = false
    do {
        _ = try DisplayHost.spawn(executable: executable, workspaceUUID: "regression",
                                  socketPath: dir + "/dh.sock", tokenPath: tokenPath,
                                  width: 640, height: 480, hiDPI: false, name: "x",
                                  logPath: dir + "/host.log", environment: ["PATH": "/usr/bin:/bin"],
                                  fake: true, timeout: 4, probe: nilStart,
                                  onLaunched: { pid, start in launched.record(pid: pid, start: start) })
    } catch let error as AgentSpaceError {
        threw = error.code == "host_spawn_failed"
    } catch { threw = false }
    check("spawn fails when the start time is unprovable", threw)
    if let (pid, _) = launched.identity(), pid > 1 {
        var gone = false
        for _ in 0..<50 where !gone {
            usleep(100_000)
            gone = kill(pid, 0) != 0
        }
        check("unidentifiable child is terminated, not leaked", gone, "pid \(pid) still alive")
    } else {
        check("unidentifiable child is terminated, not leaked", true)
    }
    // The pending record such an interrupted launch leaves behind stays
    // decodable (identity normalizes away) and abandon still works on it.
    let store = try StateStore(root: URL(fileURLWithPath: dir + "/state"))
    var ws = try store.create("nilstart-test")
    var pending = VirtualDisplayState(hostPID: 4242, hostStart: nil, socketPath: "/tmp/s",
                                      token: "t", workspaceUUID: "u", displayID: nil,
                                      bounds: nil, preset: nil)
    pending.pendingCreate = true
    ws.virtualDisplay = pending
    try store.save(ws)
    let reloaded = try store.load("nilstart-test")
    check("nil-start pending record decodes with identity normalized",
          reloaded.virtualDisplay?.pendingCreate == true
            && reloaded.virtualDisplay?.hostPID == nil)
    let receipt = try VirtualDisplay.abandon(&ws, store: store)
    check("abandon works on the recoverable record",
          field(receipt, "cleanupUnconfirmed") == .bool(true)
            && ws.virtualDisplay == nil && ws.abandonedVirtualDisplay != nil)
    try? FileManager.default.removeItem(atPath: ws.temporaryDirectory)
}

// MARK: 12. destroy() escalates past a stuck host - SIGSTOP'd fake helper

do {
    guard let executable = DisplayHost.locate() else {
        check("destroy escalation", false, "host binary missing")
        throw AgentSpaceError("test_setup", "host binary missing")
    }
    let dir = NSTemporaryDirectory() + "asr-destroy-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let socketPath = dir + "/dh.sock"
    let tokenPath = dir + "/token"
    let token = String(repeating: "ef", count: 32)
    try Data(token.utf8).write(to: URL(fileURLWithPath: tokenPath))
    let spawned = try DisplayHost.spawn(
        executable: executable, workspaceUUID: "regression", socketPath: socketPath,
        tokenPath: tokenPath, width: 640, height: 480, hiDPI: false,
        name: "regression-stuck", logPath: dir + "/host.log",
        environment: ["PATH": "/usr/bin:/bin"], fake: true, timeout: 10)
    let store = try StateStore(root: URL(fileURLWithPath: dir + "/state"))
    var ws = try store.create("destroy-test")
    var state = VirtualDisplayState(hostPID: spawned.pid, hostStart: spawned.start,
                                    socketPath: socketPath, token: token,
                                    workspaceUUID: "regression", displayID: 0x41475654,
                                    bounds: nil, preset: nil)
    state.pendingCreate = false
    ws.virtualDisplay = state
    try store.save(ws)
    // SIGSTOP: the host can't answer shutdown and SIGTERM only queues -
    // destroy must escalate to SIGKILL inside its bounded waits.
    kill(spawned.pid, SIGSTOP)
    let policy = VirtualDisplay.DestroyPolicy(shutdownTimeout: 0.5, shutdownGrace: 0.3,
                                              termGrace: 0.3, killGrace: 2, poll: 0.05)
    let receipt = try await VirtualDisplay.destroy(&ws, store: store, policy: policy)
    check("destroy claims the session only after death", field(receipt, "sessionDestroyed") == .bool(true))
    check("forced kill recorded honestly", field(receipt, "forcedTermination") == .bool(true))
    check("IPC failure kept in the receipt, not hidden", stringField(receipt, "shutdownError") != nil)
    check("teardown honesty: not marked complete", field(receipt, "teardownComplete") == .bool(false))
    check("workspace session state cleared", ws.virtualDisplay == nil)
    var gone = false
    for _ in 0..<50 where !gone {
        usleep(100_000)
        gone = kill(spawned.pid, 0) != 0
    }
    check("stopped helper really exited", gone)
    try? FileManager.default.removeItem(atPath: ws.temporaryDirectory)
}

// MARK: 13. Janitor exits the host when its socket disappears

do {
    guard let executable = DisplayHost.locate() else {
        check("janitor socket-loss exit", false, "host binary missing")
        throw AgentSpaceError("test_setup", "host binary missing")
    }
    let dir = NSTemporaryDirectory() + "asr-janitor-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let socketPath = dir + "/dh.sock"
    let tokenPath = dir + "/token"
    try Data(String(repeating: "9a", count: 32).utf8).write(to: URL(fileURLWithPath: tokenPath))
    // A raw Process so we own the exit status - the janitor must exit(0)
    // while the host sits idle.
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--workspace-uuid", "regression", "--socket", socketPath,
                         "--token-file", tokenPath, "--width", "640", "--height", "480",
                         "--hidpi", "0", "--name", "janitor-test", "--log", dir + "/host.log",
                         "--janitor-interval", "0.3"]
    var env = DisplayHost.sanitizedEnvironment(ProcessInfo.processInfo.environment)
    env["AGENTSPACE_DISPLAY_FAKE"] = "1"
    env["PATH"] = "/usr/bin:/bin"
    process.environment = env
    try process.run()
    var socketSeen = false
    for _ in 0..<100 where !socketSeen {
        usleep(50_000)
        socketSeen = FileManager.default.fileExists(atPath: socketPath)
    }
    check("idle host bound its socket", socketSeen)
    unlink(socketPath)
    process.waitUntilExit()
    check("janitor exits the host when its socket disappears",
          process.terminationReason == .exit && process.terminationStatus == 0,
          "status \(process.terminationStatus)")
}

// MARK: Report

print(#"{"passed":\#(passed),"failed":\#(failed),"failures":\#(failures)}"#)
exit(failed == 0 ? 0 : 1)

private func stat0(_ url: URL) -> Int? {
    var info = Darwin.stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return Int(info.st_mode & 0o777)
}

private func decode(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
