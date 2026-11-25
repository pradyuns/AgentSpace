import Foundation

public struct CDPEvent: Sendable {
    public var method: String
    public var params: JSONValue
    /// Flatten-mode session the event belongs to; nil for browser-domain.
    public var sessionId: String?
    public init(method: String, params: JSONValue, sessionId: String?) {
        self.method = method; self.params = params; self.sessionId = sessionId
    }
}

public protocol CDPTransport: Sendable {
    /// One request/response. `sessionId` addresses an attached page in
    /// flatten mode; nil means the browser-level domain.
    func send(_ method: String, params: [String: JSONValue], sessionId: String?,
              timeout: TimeInterval) async throws -> JSONValue
    /// Browser and attached-session events until the socket dies.
    var events: AsyncStream<CDPEvent> { get }
    func close() async
}

public extension CDPTransport {
    func send(_ method: String, params: [String: JSONValue], sessionId: String?) async throws -> JSONValue {
        try await send(method, params: params, sessionId: sessionId, timeout: 30)
    }
}

public enum ChromeEndpoint {
    /// Read + strictly parse `<chromeRoot>/DevToolsActivePort` into a
    /// loopback-only `ws://127.0.0.1:<port>/devtools/browser/<guid>` URL.
    /// Missing or malformed content is a setup problem, not a Chrome quirk.
    public static func discover(chromeRoot: URL) throws -> (endpoint: URL, guid: String) {
        let file = chromeRoot.appendingPathComponent("DevToolsActivePort")
        guard let contents = try? String(contentsOf: file, encoding: .utf8),
              let url = CDPBrowser.debugEndpoint(contents) else {
            throw AgentSpaceError("chrome_not_configured",
                "Chrome is not advertising a remote-debugging endpoint at \(file.path). "
                + "Open chrome://inspect/#remote-debugging in Chrome and enable remote debugging. "
                + "Approve the connection in Chrome when prompted; "
                + "AgentSpace never enables it for you and never touches your profile settings")
        }
        let guid = String(url.path.dropFirst("/devtools/browser/".count))
        return (url, guid)
    }

    public static func identify(transport: any CDPTransport, endpoint: URL, guid: String,
                                timeout: TimeInterval) async throws -> BrowserIdentity {
        do {
            let info = try await transport.send("SystemInfo.getProcessInfo", params: [:],
                                                sessionId: nil, timeout: timeout)
            guard let entry = arrayField(info, "processInfo").first(where: { stringField($0, "type") == "browser" }),
                  let pid = int32Field(entry, "id") ?? int32Field(entry, "pid"),
                  let start = DisplayHost.processStartTime(pid) else {
                throw AgentSpaceError("chrome_unavailable", "the endpoint did not report a live browser process identity")
            }
            return BrowserIdentity(endpoint: endpoint.absoluteString, guid: guid,
                                   browser: ProcessIdentity(pid: pid, start: start))
        } catch CDPSocket.SocketFailure.timedOut {
            throw AgentSpaceError("approval_unresolved", "Chrome has not answered the connection request. Check Chrome's remote-debugging approval prompt. No denial was inferred; no new connection was requested.")
        } catch let error as AgentSpaceError { throw error }
        catch {
            throw AgentSpaceError("connection_unresolved", "The debugging connection failed before Chrome confirmed access. Check Chrome's remote-debugging setup and approval prompt. No denial was inferred.")
        }
    }
}
