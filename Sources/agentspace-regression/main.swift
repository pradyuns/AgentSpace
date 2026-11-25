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

if CommandLine.arguments == [CommandLine.arguments[0], "--print-access-probe"] {
    print(SiteAccess.evidenceExpression)
    exit(0)
}

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--cdp-socket-probe",
   let url = URL(string: CommandLine.arguments[2]) {
    let mode = CommandLine.arguments[3]
    let socket = CDPSocket(endpoint: url)
    do {
        if mode == "unresolved" {
            _ = try await ChromeEndpoint.identify(transport: socket, endpoint: url, guid: "socket-test", timeout: 0.3)
        } else {
            for index in 1...(mode == "immediate" ? 250 : 1) {
                let reply = try await socket.send("Target.createTarget", params: [:], sessionId: nil, timeout: 2)
                guard int32Field(reply, "receipt") == Int32(index) else { throw AgentSpaceError("receipt_lost", "wrong socket receipt") }
            }
        }
        print("receipts-preserved")
    } catch let error as AgentSpaceError { print(error.code) }
    catch { print(String(describing: error)) }
    await socket.close()
    exit(0)
}

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

// MARK: 14. Chrome session broker - scripted CDP transport

final class ScriptedTransport: CDPTransport, @unchecked Sendable {
    struct Call { var method: String; var params: [String: JSONValue]; var sessionId: String? }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] { lock.withLock { _calls } }
    var responder: (String, [String: JSONValue], String?) -> JSONValue
    private var continuation: AsyncStream<CDPEvent>.Continuation?
    let events: AsyncStream<CDPEvent>
    init(responder: @escaping (String, [String: JSONValue], String?) -> JSONValue) {
        self.responder = responder
        var cont: AsyncStream<CDPEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }
    func send(_ method: String, params: [String: JSONValue], sessionId: String?,
              timeout: TimeInterval) async throws -> JSONValue {
        lock.withLock { _calls.append(Call(method: method, params: params, sessionId: sessionId)) }
        return responder(method, params, sessionId)
    }
    func push(_ method: String, _ params: JSONValue, sessionId: String?) {
        continuation?.yield(CDPEvent(method: method, params: params, sessionId: sessionId))
    }
    func finish() { continuation?.finish() }
    func close() async { continuation?.finish() }
    func sent(_ method: String) -> [Call] { calls.filter { $0.method == method } }
    func last(_ method: String) -> Call? { calls.last { $0.method == method } }
}

final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
    func snapshot() -> [String] { lock.withLock { entries } }
}

final class FakePage: @unchecked Sendable {
    var visible = false
    var passwordFocus = false
    var evidence: JSONValue = .null
}

func scriptedAXTree() -> JSONValue {
    func node(_ id: Int, _ role: String, _ name: String) -> JSONValue {
        .object(["backendDOMNodeId": .number(Double(id)), "ignored": .bool(false),
                 "role": .object(["value": .string(role)]),
                 "name": .object(["value": .string(name)]),
                 "properties": .array([])])
    }
    return .object(["nodes": .array([
        node(5, "textbox", "Search"), node(6, "button", "Go"), node(7, "link", "Docs")])])
}

do {
    let dir = NSTemporaryDirectory() + "asr-session-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let guid = "test-guid-0001"
    try Data("43000\n/devtools/browser/\(guid)\n".utf8)
        .write(to: URL(fileURLWithPath: dir + "/DevToolsActivePort"))
    let identity = BrowserIdentity(endpoint: "ws://127.0.0.1:43000/devtools/browser/\(guid)",
                                   guid: guid, browser: ProcessIdentity(pid: 4242, start: 500))

    let order = OrderLog()
    let page = FakePage()
    page.evidence = .object([
        "url": .string("http://localhost:8080/"), "host": .string("localhost"),
        "title": .string("Fixture"), "password": .bool(false), "loginPath": .bool(false),
        "fixtureSignedIn": .bool(true), "fixtureAccount": .string("alice@fixture.io")])
    final class Ids { var n = 0; var closed = false }
    let ids = Ids()
    let transport = ScriptedTransport { method, params, sessionId in
        order.add("send:\(method)")
        switch method {
        case "Target.createTarget":
            ids.n += 1
            return .object(["targetId": .string("T-OWNED-\(ids.n)")])
        case "Target.attachToTarget":
            return .object(["sessionId": .string("S-OWNED-\(ids.n)")])
        case "Page.navigate": return .object([:])
        case "Page.addScriptToEvaluateOnNewDocument": return .object(["identifier": .string("policy-1")])
        case "Target.closeTarget": ids.closed = true; return .object(["success": .bool(true)])
        case "Target.getTargets":
            return .object(["targetInfos": .array(ids.closed ? [] : [.object(["targetId": .string("T-OWNED-1")])])])
        case "Runtime.evaluate":
            let expr = stringField(.object(params), "expression") ?? ""
            if expr.contains("visibilityState") {
                return .object(["result": .object(["value": .string(page.visible ? "visible" : "hidden")])])
            }
            if expr.contains("fixtureSignedIn") || expr.contains("gmailMain") {
                return .object(["result": .object(["value": page.evidence])])
            }
            if expr.contains("readyState") {
                return .object(["result": .object(["value": .bool(true)])])
            }
            if expr.contains("activeElement") {
                return .object(["result": .object(["value": page.passwordFocus
                    ? .object(["type": .string("password"), "tag": .string("INPUT")])
                    : .object(["type": .string("text"), "tag": .string("INPUT")])])])
            }
            if expr.contains("scroll") || expr.hasPrefix("scrollY") || expr.hasPrefix("scrollX") {
                return .object(["result": .object(["value": .number(0)])])
            }
            return .object(["result": .object(["value": .null])])
        case "Accessibility.getFullAXTree": return scriptedAXTree()
        case "DOM.resolveNode": return .object(["object": .object(["objectId": .string("obj-1")])])
        case "Runtime.callFunctionOn":
            let fn = stringField(.object(params), "functionDeclaration") ?? ""
            if fn.contains("getBoundingClientRect") {
                return .object(["result": .object(["value": .object(["x": .number(10), "y": .number(20)])])])
            }
            if fn.contains("this.type") {
                return .object(["result": .object(["value": .object(["type": .string(page.passwordFocus ? "password" : "text"), "tag": .string("INPUT")])])])
            }
            return .object(["result": .object(["value": .string("alice")])])
        default: return .object([:])
        }
    }

    let core = try SessionCore(config: SessionCore.Config(
        brokerKey: "sb-test", mode: .shared,
        chromeRoot: URL(fileURLWithPath: dir), brokerDir: URL(fileURLWithPath: dir),
        probe: DisplayHost.Probe(startTime: { _ in 500 }, signal: { _, _ in 0 }),
        onJournalSaved: { journal in
            order.add("journal:\(journal.sessions.values.flatMap(\.targets).count)-targets")
        }))
    try await core.adoptTransport(transport, identity: identity, ownedByBroker: false)

    let open = try await core.handle("open", .object([
        "requestId": .string("r1"), "session": .string("s1"),
        "url": .string("http://localhost:8080/"), "site": .string("fixture"),
        "expectedAccount": .string("alice@fixture.io")]))
    check("session open returns ok + session summary",
          field(open, "ok") == .bool(true) && field(open, "session") != .null)
    let create = transport.last("Target.createTarget")
    check("createTarget is a fresh background about:blank",
          create != nil
            && field(.object(create!.params), "url") == .string("about:blank")
            && field(.object(create!.params), "background") == .bool(true))
    check("no browserContextId on a shared target",
          field(.object(create!.params), "browserContextId") == .null)
    let attach = transport.last("Target.attachToTarget")
    check("attach is flatten-mode on the receipt id",
          attach != nil && field(.object(attach!.params), "targetId") == .string("T-OWNED-1")
            && field(.object(attach!.params), "flatten") == .bool(true))
    let autoAttach = transport.last("Target.setAutoAttach")
    check("auto-attach waits for debugger start on the page session",
          autoAttach != nil && autoAttach!.sessionId == "S-OWNED-1"
            && field(.object(autoAttach!.params), "waitForDebuggerOnStart") == .bool(true))
    check("shared mode arms Fetch interception on the page session",
          transport.last("Fetch.enable")?.sessionId == "S-OWNED-1")
    let calls = order.snapshot()
    let navIndex = calls.firstIndex(of: "send:Page.navigate") ?? -1
    let journalIndex = calls.firstIndex(of: "journal:1-targets") ?? -1
    check("target was journaled before navigate",
          journalIndex >= 0 && navIndex > journalIndex, "\(calls)")
    let forbidden: Set<String> = ["Browser.close",
                                  "Browser.setDownloadBehavior", "Browser.grantPermissions",
                                  "Network.setCookies", "Storage.getCookies"]
    check("no forbidden protocol methods so far",
          transport.calls.allSatisfy { !forbidden.contains($0.method) },
          "\(transport.calls.map { $0.method })")
    var journal = await core.journalSnapshot
    check("identity verified by supported-site readback",
          stringField(field(open, "access"), "identity") == "verified"
            && stringField(field(open, "access"), "access") == "accessible")
    let journalData = try Data(contentsOf: URL(fileURLWithPath: dir + "/journal.json"))
    check("expected account is a digest, never plaintext",
          !String(decoding: journalData, as: UTF8.self).contains("alice@fixture.io"))
    let replay = try await core.handle("open", .object([
        "requestId": .string("r1"), "session": .string("s1"),
        "url": .string("http://localhost:8080/"), "site": .string("fixture"),
        "expectedAccount": .string("alice@fixture.io")]))
    let changedConstraint = try? await core.handle("open", .object([
        "requestId": .string("r1"), "session": .string("s1"), "url": .string("http://localhost:8080/"),
        "site": .string("fixture"), "expectedAccount": .string("bob@fixture.io")]))
    check("an open replay cannot silently replace its account constraint", changedConstraint == nil)
    check("open replay is idempotent",
          field(replay, "idempotent") == .bool(true)
            && transport.sent("Target.createTarget").count == 1)
    let obs = try await core.handle("perform", .object([
        "session": .string("s1"), "command": .string("observe"),
        "options": .object(["limit": .number(100), "depth": .number(5)])]))
    check("observe returns a tree from the owned page",
          field(obs, "ok") == .bool(true) && field(obs, "tree") != .null)
    transport.push("Target.attachedToTarget", .object([
        "targetInfo": .object(["targetId": .string("USER-CHILD"), "type": .string("page"),
                               "openerId": .string("USER-TAB")]),
        "sessionId": .string("S-USER-1")]), sessionId: "S-OWNED-1")
    try await Task.sleep(for: .milliseconds(150))
    check("foreign page attachment is released, never adopted or closed",
          !transport.sent("Target.closeTarget").contains { field(.object($0.params), "targetId") == .string("USER-CHILD") }
            && transport.sent("Runtime.runIfWaitingForDebugger").contains { $0.sessionId == "S-USER-1" })
    transport.push("Fetch.requestPaused", .object([
        "requestId": .string("rq-1"),
        "responseHeaders": .array([.object(["name": .string("Content-Disposition"),
                                            "value": .string("attachment; filename=a.bin")])])]),
        sessionId: "S-OWNED-1")
    transport.push("Fetch.requestPaused", .object([
        "requestId": .string("rq-2"), "responseHeaders": .array([])]), sessionId: "S-OWNED-1")
    try await Task.sleep(for: .milliseconds(200))
    check("attachment response is failed per-request",
          transport.sent("Fetch.failRequest").contains {
              field(.object($0.params), "requestId") == .string("rq-1") })
    check("ordinary response continues",
          transport.sent("Fetch.continueRequest").contains {
              field(.object($0.params), "requestId") == .string("rq-2") })
    journal = await core.journalSnapshot
    check("blocked download counted", journal.sessions["s1"]?.downloadsBlocked == 1)
    let open2 = try await core.handle("open", .object([
        "requestId": .string("r2"), "session": .string("s2"),
        "url": .string("http://localhost:8080/two"), "site": .string("fixture")]))
    check("second session opens its own owned target",
          field(open2, "ok") == .bool(true))
    transport.push("Target.detachedFromTarget", .object(["sessionId": .string("S-GHOST")]),
                   sessionId: nil)
    transport.push("Target.targetDestroyed", .object(["targetId": .string("T-FOREIGN")]),
                   sessionId: nil)
    transport.push("Fetch.requestPaused", .object([
        "requestId": .string("rq-foreign"), "responseHeaders": .array([
            .object(["name": .string("Content-Disposition"),
                     "value": .string("attachment; filename=x.bin")])])]),
        sessionId: "S-GHOST")
    try await Task.sleep(for: .milliseconds(150))
    check("foreign detach/destroy/paused events are ignored",
          !transport.sent("Fetch.failRequest").contains {
              field(.object($0.params), "requestId") == .string("rq-foreign") }
            && !transport.sent("Fetch.continueRequest").contains {
                field(.object($0.params), "requestId") == .string("rq-foreign") })
    journal = await core.journalSnapshot
    check("foreign events mutate no owned state",
          journal.sessions["s1"]?.targets.last?.state == .open
            && journal.sessions["s2"]?.targets.last?.state == .open
            && journal.sessions["s1"]?.downloadsBlocked == 1)
    let obs2 = try await core.handle("perform", .object([
        "session": .string("s1"), "command": .string("observe"), "options": .object([:])]))
    check("owned session unaffected by foreign events",
          field(obs2, "ok") == .bool(true))
    transport.push("Target.targetDestroyed", .object(["targetId": .string("T-OWNED-2")]),
                   sessionId: nil)
    try await Task.sleep(for: .milliseconds(150))
    journal = await core.journalSnapshot
    check("user-closed owned target is journaled closed",
          journal.sessions["s2"]?.targets.last?.state == .closed)
    let goneTarget = try? await core.handle("perform", .object([
        "session": .string("s2"), "command": .string("observe"), "options": .object([:])]))
    check("dead owned target reports session_target_gone",
          goneTarget == nil || field(goneTarget!, "ok") != .bool(true))
    let close2 = try await core.handle("close-session", .object(["session": .string("s2")]))
    check("close-session on user-closed tab confirms cleanup honestly",
          field(close2, "cleanupConfirmed") == .bool(true)
            && arrayField(close2, "uncertainTargets").isEmpty)
    page.passwordFocus = true
    let pwType = try? await core.handle("perform", .object([
        "session": .string("s1"), "command": .string("type-text"),
        "options": .object(["ref": .string("0.5"), "text": .string("hunter2")])]))
    check("password-field typing refused (throws password_input_refused)",
          pwType == nil)
    check("no text was inserted after refusal",
          !transport.sent("Input.insertText").contains {
              field(.object($0.params), "text") == .string("hunter2") })
    page.passwordFocus = false
    let handoff = try await core.handle("handoff", .object(["session": .string("s1")]))
    check("handoff activates the owned target",
          field(handoff, "ok") == .bool(true)
            && transport.last("Target.activateTarget")
                .map { field(.object($0.params), "targetId") == .string("T-OWNED-1") } == true)
    let blocked = try? await core.handle("perform", .object([
        "session": .string("s1"), "command": .string("click"),
        "options": .object(["ref": .string("0.6")])]))
    check("automation paused during handoff",
          blocked == nil || field(blocked!, "ok") != .bool(true))
    page.visible = true
    let resumeVisible = try await core.handle("resume", .object(["session": .string("s1")]))
    check("visible tab reports awaiting_background",
          field(resumeVisible, "handoff") == .string("awaiting_background"))
    check("no activateTarget was sent for a user tab",
          transport.sent("Target.activateTarget").count == 1)
    page.visible = false
    let resumed = try await core.handle("resume", .object(["session": .string("s1")]))
    check("hidden tab resumes to background + reassess",
          field(resumed, "ok") == .bool(true)
            && field(resumed, "handoff") == .string("background"))
    let close = try await core.handle("close-session", .object(["session": .string("s1")]))
    check("close-session closes the owned target by receipt id",
          transport.sent("Target.closeTarget").contains {
              field(.object($0.params), "targetId") == .string("T-OWNED-1") })
    let closeReplay = try await core.handle("close-session", .object(["session": .string("s1")]))
    check("confirmed close replay returns its settled receipt", closeReplay == close)
    check("close report confirms cleanup",
          field(close, "cleanupConfirmed") == .bool(true)
            && arrayField(close, "uncertainTargets").isEmpty)
    check("STILL no forbidden methods after full lifecycle",
          transport.calls.allSatisfy { !forbidden.contains($0.method) },
          "\(transport.calls.map { $0.method })")
    check("every activateTarget ever sent named the owned receipt id",
          transport.sent("Target.activateTarget").allSatisfy {
              field(.object($0.params), "targetId") == .string("T-OWNED-1") })
    transport.finish()
    try await Task.sleep(for: .milliseconds(200))
    journal = await core.journalSnapshot
    check("disconnect keeps live browser generation uncertain",
          journal.generation?.gone == false)
    let goneErr = try? await core.handle("perform", .object([
        "session": .string("s1"), "command": .string("observe"), "options": .object([:])]))
    check("dead browser reports browser_gone honestly",
          goneErr == nil || field(goneErr!, "ok") != .bool(true))
}

do {
    let identity = ProcessIdentity(pid: 4242, start: 500)
    let unknown = DisplayHost.Probe(startTime: { _ in nil }, signal: { _, _ in 0 })
    check("missing process metadata does not prove browser death", !SessionProcess.isDead(identity, probe: unknown))
    let replaced = DisplayHost.Probe(startTime: { _ in 501 }, signal: { _, _ in 0 })
    check("a changed start time proves the original browser died", SessionProcess.isDead(identity, probe: replaced))
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("asr-corrupt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bytes = Data("invalid journal evidence".utf8)
    try bytes.write(to: dir.appendingPathComponent("journal.json"))
    let core = try? SessionCore(config: .init(brokerKey: "sb-corrupt", mode: .shared, chromeRoot: dir, brokerDir: dir))
    check("unreadable journals refuse startup", core == nil)
    check("unreadable journal evidence is preserved", (try? Data(contentsOf: dir.appendingPathComponent("journal.json"))) == bytes)
}

// MARK: 15. Chrome session broker IPC - real broker process

do {
    guard let brokerBinary = SessionBroker.locate() else {
        check("session broker binary exists next to CLI", false, "agentspace-session-broker not built")
        throw AgentSpaceError("test_setup", "broker binary missing")
    }
    check("session broker binary located", FileManager.default.isExecutableFile(atPath: brokerBinary.path))
    let dir = NSTemporaryDirectory() + "asr-broker-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let brokerDir = dir + "/broker"
    try FileManager.default.createDirectory(atPath: brokerDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let chromeRoot = dir + "/ChromeRoot"
    try FileManager.default.createDirectory(atPath: chromeRoot, withIntermediateDirectories: true)
    let socketPath = dir + "/sb.sock"
    let proc = Process()
    proc.executableURL = brokerBinary
    proc.arguments = ["--key", "sb-regtest", "--mode", "existing",
                      "--chrome-root", chromeRoot, "--broker-dir", brokerDir,
                      "--socket", socketPath, "--janitor-interval", "0.3",
                      "--connect-timeout", "1"]
    proc.environment = ["PATH": "/usr/bin:/bin"]
    proc.standardInput = FileHandle.nullDevice
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try proc.run()
    var recordData: Data?
    for _ in 0..<100 where recordData == nil {
        usleep(100_000)
        recordData = try? Data(contentsOf: URL(fileURLWithPath: brokerDir + "/broker.json"))
    }
    check("broker wrote its identity record", recordData != nil)
    let record = recordData.flatMap { try? JSONDecoder().decode(BrokerRecord.self, from: $0) }
    check("broker record matches spawned pid",
          record?.pid == proc.processIdentifier && record != nil)
    let tokenPath = brokerDir + "/broker-token"
    var token = ""
    for _ in 0..<50 where token.isEmpty {
        usleep(50_000)
        token = (try? String(contentsOfFile: tokenPath))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    check("broker token is 0600 and 32+ hex",
          token.count >= 32 && token.allSatisfy(\.isHexDigit)
            && (stat0(URL(fileURLWithPath: tokenPath)) == 0o600))
    let bad = try? BrokerIPC.request(socketPath: socketPath, token: "wrong", op: "status", timeout: 3)
    check("bad token rejected",
          bad.map { field($0, "ok") == .bool(false)
                    && stringField(field($0, "error"), "code") == "auth_failed" } == true)
    let hello = try? BrokerIPC.request(socketPath: socketPath, token: token, op: "hello", timeout: 3)
    check("hello preserves setup failure",
          hello.map { stringField(field($0, "error"), "code") == "chrome_not_configured" } == true)
    let status = try? BrokerIPC.request(socketPath: socketPath, token: token, op: "status", timeout: 3)
    check("status reports degraded honestly (no browser bound)",
          status.map { field($0, "ok") == .bool(true) } == true)
    let unknown = try? BrokerIPC.request(socketPath: socketPath, token: token, op: "nope", timeout: 3)
    check("unknown op rejected",
          unknown.map { stringField(field($0, "error"), "code") == "unknown_op" } == true)
    let big = String(repeating: "A", count: 1_100_000)
    let oversized = try? BrokerIPC.request(socketPath: socketPath, token: token, op: "status",
                                           fields: ["blob": .string(big)], timeout: 5)
    check("oversized frame refused by client cap",
          oversized == nil || stringField(field(oversized!, "error"), "code") == "request_too_large")
    let proc2 = Process()
    proc2.executableURL = brokerBinary
    proc2.arguments = ["--key", "sb-regtest", "--mode", "existing",
                       "--chrome-root", chromeRoot, "--broker-dir", brokerDir,
                       "--socket", socketPath]
    proc2.environment = ["PATH": "/usr/bin:/bin"]
    proc2.standardInput = FileHandle.nullDevice
    proc2.standardOutput = FileHandle.nullDevice
    proc2.standardError = FileHandle.nullDevice
    try proc2.run()
    proc2.waitUntilExit()
    check("second broker on the same key refused (singleton lock)",
          proc2.terminationStatus != 0)
    check("first broker still alive after the conflict",
          kill(proc.processIdentifier, 0) == 0)
    _ = try? BrokerIPC.call(socketPath: socketPath, token: token, op: "shutdown", timeout: 5)
    var gone = false
    for _ in 0..<50 where !gone { usleep(100_000); gone = kill(proc.processIdentifier, 0) != 0 }
    check("broker exits on authenticated shutdown", gone)
    check("broker unlinked its socket", !FileManager.default.fileExists(atPath: socketPath))
    let proc3 = Process()
    proc3.executableURL = brokerBinary
    proc3.arguments = ["--key", "sb-janitor", "--mode", "existing",
                       "--chrome-root", chromeRoot, "--broker-dir", dir + "/broker2",
                       "--socket", dir + "/sb2.sock", "--janitor-interval", "0.3"]
    proc3.environment = ["PATH": "/usr/bin:/bin"]
    proc3.standardInput = FileHandle.nullDevice
    proc3.standardOutput = FileHandle.nullDevice
    proc3.standardError = FileHandle.nullDevice
    try proc3.run()
    var seen = false
    for _ in 0..<100 where !seen { usleep(50_000); seen = FileManager.default.fileExists(atPath: dir + "/sb2.sock") }
    check("janitor test broker bound its socket", seen)
    unlink(dir + "/sb2.sock")
    proc3.waitUntilExit()
    check("janitor exits broker when socket disappears",
          proc3.terminationReason == .exit && proc3.terminationStatus == 0,
          "status \(proc3.terminationStatus)")
    if let logData = try? Data(contentsOf: URL(fileURLWithPath: brokerDir + "/session-log.jsonl")),
       !logData.isEmpty {
        let lines = String(decoding: logData, as: UTF8.self).split(separator: "\n")
        let allowed: Set<String> = ["ts", "kind", "op", "ok", "code", "mode", "session",
                                    "site", "alias", "state", "handoff", "access", "identity",
                                    "count", "file", "pid"]
        let allClean = lines.allSatisfy { line in
            guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)),
                  case .object(let o) = parsed else { return false }
            return o.keys.allSatisfy(allowed.contains)
        }
        check("session log envelope is allowlisted only", allClean)
    }
}

// MARK: 16. Access + identity classifier - evidence rules, no guessing

do {
    func facts(_ markerPairs: [(String, String)], url: String = "http://127.0.0.1/app",
               password: Bool = false, loginPath: Bool = false) -> PageFacts {
        PageFacts(url: url, host: URL(string: url)?.host() ?? "",
                  title: "t", hasPasswordField: password,
                  loginPathHint: loginPath, markers: Dictionary(uniqueKeysWithValues: markerPairs))
    }
    let hash = SessionBroker.accountDigest
    let expected = hash("alice@fixture.io", "salt")
    let good = SiteAccess.assess(facts([("fixtureSignedIn", "1"), ("fixtureAccount", "alice@fixture.io")]),
                               site: "fixture", expectedDigest: expected) { hash($0, "salt") }
    check("readback match verifies", good.access == .accessible && good.identity == .verified,
          "\(good)")
    check("verification method names the site readback",
          good.identityMethod == "fixture-account-readback")
    let wrong = SiteAccess.assess(facts([("fixtureSignedIn", "1"), ("fixtureAccount", "bob@fixture.io")]),
                                site: "fixture", expectedDigest: expected) { hash($0, "salt") }
    check("readback mismatch is mismatch, never verified",
          wrong.identity == .mismatch && wrong.access == .accessible, "\(wrong)")
    let silent = SiteAccess.assess(facts([("fixtureSignedIn", "1")]),
                                 site: "fixture", expectedDigest: expected) { hash($0, "salt") }
    check("missing readback with constraint is unknown, not verified",
          silent.identity == .unknown && silent.access == .accessible, "\(silent)")
    let slotted = SiteAccess.assess(facts([("fixtureSignedIn", "1")],
                                        url: "http://127.0.0.1/u/2/app?authuser=2"),
                                    site: "fixture", expectedDigest: expected) { hash($0, "salt") }
    check("URL account slot can never verify identity",
          slotted.identity == .unknown, "\(slotted)")
    let wall = SiteAccess.assess(facts([("fixtureLogin", "1")], password: true),
                                 site: "fixture", expectedDigest: nil) { hash($0, "salt") }
    check("fixture login marker -> login_required",
          wall.access == .loginRequired && wall.evidence.contains("fixture-login-marker"))
    let pw = SiteAccess.assess(facts([], password: true), site: nil,
                               expectedDigest: nil) { hash($0, "salt") }
    check("a password field alone is a login wall, not an account",
          pw.access == .loginRequired && pw.identity == .notRequired)
    let generic = SiteAccess.assess(facts([("fixtureSignedIn", "1")]), site: "github",
                                    expectedDigest: expected) { hash($0, "salt") }
    check("unsupported site stays unknown even with stray markers",
          generic.access == .unknown && generic.identity == .unknown, "\(generic)")
    let noSite = SiteAccess.assess(facts([("fixtureSignedIn", "1")]), site: nil,
                                   expectedDigest: expected) { hash($0, "salt") }
    check("fixture markers mean nothing without the fixture host rule",
          noSite.access == .unknown && noSite.identity == .unknown, "\(noSite)")
    let crossHost = SiteAccess.assess(facts([("fixtureSignedIn", "1"), ("fixtureAccount", "alice@fixture.io")],
                                          url: "https://mail.google.com/mail/u/0/"),
                                      site: "fixture", expectedDigest: expected) { hash($0, "salt") }
    check("site rule does not apply off its declared hosts",
          crossHost.access == .unknown && crossHost.identity == .unknown, "\(crossHost)")
    check("gmail normalization drops dots and +tags",
          AccountConstraint.normalize("Al.Ice+work@Gmail.com") == "alice@gmail.com")
    check("non-gmail domains keep dots",
          AccountConstraint.normalize("al.ice@fixture.io") == "al.ice@fixture.io")
    check("account digest never embeds the plaintext",
          !hash("alice@fixture.io", "salt").contains("alice"))
    let gmailWall = SiteAccess.assess(facts([], url: "https://accounts.google.com/signin"),
                                      site: "gmail", expectedDigest: nil) { hash($0, "salt") }
    check("supported-site login host -> login_required",
          gmailWall.access == .loginRequired && gmailWall.evidence.contains("login-host"))
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
