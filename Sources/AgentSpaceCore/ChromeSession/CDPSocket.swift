import Foundation

/// Persistent CDP websocket transport for the session broker. Unlike
/// CDPBrowser's per-call transport, the broker holds this socket for the
/// whole browser generation, which is what makes durable target ownership
/// and event routing (popups, downloads, target destruction) possible.
/// Failure semantics are uniform: any socket error fails every pending
/// request and finishes the event stream exactly once.
public actor CDPSocket: CDPTransport {
    public enum SocketFailure: Error, Sendable {
        case closed
        case timedOut
        case queueFull
        case eventOverflow
    }

    private let task: URLSessionWebSocketTask
    private var serial: Int32 = 0
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }
    private var pending: [Int32: Pending] = [:]
    private var receiveTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<CDPEvent>.Continuation?
    private var finished = false
    public private(set) var terminalFailure: String?
    private let maxPending = 64

    public nonisolated let events: AsyncStream<CDPEvent>

    public init(endpoint: URL) {
        task = URLSession.shared.webSocketTask(with: endpoint)
        task.maximumMessageSize = 16 << 20
        var continuation: AsyncStream<CDPEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingOldest(256)) { continuation = $0 }
        eventContinuation = continuation
        task.resume()
    }

    public func start() {
        guard receiveTask == nil else { return }
        receiveTask = Task { await self.receiveLoop() }
    }

    public func send(_ method: String, params: [String: JSONValue], sessionId: String?) async throws -> JSONValue {
        try await send(method, params: params, sessionId: sessionId, timeout: 30)
    }

    public func send(_ method: String, params: [String: JSONValue], sessionId: String?,
                     timeout: TimeInterval) async throws -> JSONValue {
        if finished { throw SocketFailure.closed }
        guard pending.count < maxPending else { throw SocketFailure.queueFull }
        serial += 1
        let id = serial
        var request: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method)]
        if !params.isEmpty { request["params"] = .object(params) }
        if let sessionId { request["sessionId"] = .string(sessionId) }
        let encoded = String(decoding: try JSONEncoder().encode(JSONValue.object(request)), as: UTF8.self)
        start()
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(timeout, 0.1))) }
                catch { return }
                await self?.timeout(id)
            }
            pending[id] = Pending(continuation: continuation, timeout: timer)
            Task {
                do { try await self.task.send(.string(encoded)) }
                catch { self.failAll() }
            }
        }
    }

    private func timeout(_ id: Int32) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: SocketFailure.timedOut)
    }

    private func receiveLoop() async {
        while true {
            do {
                let message = try await task.receive()
                guard case .string(let text) = message,
                      let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
                      case .object(let object) = decoded else { continue }
                if let id = int32Field(decoded, "id") {
                    if let request = pending.removeValue(forKey: id) {
                        request.timeout.cancel()
                        let continuation = request.continuation
                        if let error = object["error"], error != .null {
                            let code = int32Field(error, "code") ?? 0
                            let message = stringField(error, "message") ?? "CDP error"
                            continuation.resume(throwing: AgentSpaceError("cdp_\(code)", message))
                        } else {
                            continuation.resume(returning: object["result"] ?? .object([:]))
                        }
                    }
                } else if let method = stringField(decoded, "method") {
                    guard text.utf8.count <= 256 << 10 else {
                        failAll(SocketFailure.eventOverflow)
                        task.cancel(with: .policyViolation, reason: nil)
                        return
                    }
                    let delivered = eventContinuation?.yield(CDPEvent(
                        method: method,
                        params: object["params"] ?? .object([:]),
                        sessionId: stringField(decoded, "sessionId")))
                    if case .dropped = delivered {
                        failAll(SocketFailure.eventOverflow)
                        task.cancel(with: .policyViolation, reason: nil)
                        return
                    }
                }
            } catch {
                failAll()
                return
            }
        }
    }

    private func failAll(_ error: Error = SocketFailure.closed) {
        guard !finished else { return }
        finished = true
        if case SocketFailure.eventOverflow = error { terminalFailure = "event_backlog_overflow" }
        else { terminalFailure = "connection_unresolved" }
        let waiting = pending
        pending = [:]
        for request in waiting.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: error)
        }
        eventContinuation?.finish()
    }

    public func close() {
        guard !finished else { return }
        task.cancel(with: .normalClosure, reason: nil)
        receiveTask?.cancel()
        failAll()
    }
}
