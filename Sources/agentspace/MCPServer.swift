import Foundation
import AgentSpaceCore
import Darwin

@MainActor
enum MCPServer {
    static func run() async {
        var framing = MCPFraming()
        do {
            var bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let count = Darwin.read(STDIN_FILENO, &bytes, 65_536)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw AgentSpaceError("stdin_read_failed", "Cannot read MCP input")
                }
                let data = Data(bytes.prefix(count))
                for line in try framing.append(data) {
                    let reply: JSONValue?
                    do { reply = await handle(try JSONDecoder().decode(JSONValue.self, from: line)) }
                    catch { reply = MCPFraming.error(code: -32700, message: "Parse error") }
                    if let reply { try FileHandle.standardOutput.write(contentsOf: MCPFraming.encode(reply)) }
                }
            }
            try framing.finish()
        } catch {
            try? FileHandle.standardOutput.write(contentsOf: MCPFraming.encode(MCPFraming.error(code: -32700, message: String(describing: error))))
        }
    }

    static func handle(_ request: JSONValue) async -> JSONValue? {
        guard case .object(let fields) = request, fields["jsonrpc"] == .string("2.0"),
              case .string(let method) = fields["method"] else {
            return MCPFraming.error(code: -32600, message: "Invalid request")
        }
        let id = fields["id"] ?? .null
        if let supplied = fields["id"] {
            switch supplied {
            case .string, .number, .null: break
            default: return MCPFraming.error(code: -32600, message: "Invalid request id")
            }
        } else { return nil }
        func result(_ value: JSONValue) -> JSONValue { MCPFraming.response(id: id, result: value) }
        func invalid(_ message: String) -> JSONValue { MCPFraming.error(id: id, code: -32602, message: message) }
        switch method {
        case "initialize":
            return result(.object(["protocolVersion": .string("2024-11-05"), "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("agentspace"), "version": .string("0.1.0")])]))
        case "ping": return result(.object([:]))
        case "tools/list":
            let tools = AgentSpaceCLI.commands.sorted().map { command -> JSONValue in
                let options = AgentSpaceCLI.common.union(AgentSpaceCLI.allowed[command] ?? [])
                let properties = Dictionary(uniqueKeysWithValues: options.map { key in
                    (key, JSONValue.object(["type": .string(AgentSpaceCLI.flags.contains(key) ? "boolean" : "string")]))
                })
                return .object(["name": .string(command), "description": .string("AgentSpace \(command); same options and verification semantics as the CLI"),
                    "inputSchema": .object(["type": .string("object"), "properties": .object(properties), "additionalProperties": .bool(false)])])
            }
            return result(.object(["tools": .array(tools)]))
        case "tools/call":
            guard case .object(let params) = fields["params"], case .string(let name) = params["name"],
                  AgentSpaceCLI.commands.contains(name) else { return invalid("Unknown tool") }
            let arguments = params["arguments"] ?? .object([:])
            guard case .object(let options) = arguments else { return invalid("arguments must be an object") }
            let allowed = AgentSpaceCLI.common.union(AgentSpaceCLI.allowed[name] ?? [])
            var values: [String: String] = [:], flags: Set<String> = []
            for (key, value) in options {
                guard allowed.contains(key) else { return invalid("Unknown option \(key)") }
                if AgentSpaceCLI.flags.contains(key) {
                    guard case .bool(let enabled) = value else { return invalid("\(key) must be boolean") }
                    if enabled { flags.insert(key) }
                } else {
                    guard case .string(let text) = value else { return invalid("\(key) must be string") }
                    values[key] = text
                }
            }
            let output: JSONValue
            do {
                output = await WorkspaceController(store: try StateStore()).run(name, workspace: values["workspace"] ?? "default",
                    options: CommandOptions(values: values, flags: flags))
            } catch {
                output = .object(["ok": .bool(false), "error": .string(String(describing: error))])
            }
            let text = (try? String(data: JSONEncoder().encode(output), encoding: .utf8)) ?? "null"
            let ok: Bool
            if case .object(let object) = output { ok = object["ok"] == .bool(true) } else { ok = false }
            return result(.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]), "isError": .bool(!ok)]))
        default: return MCPFraming.error(id: id, code: -32601, message: "Method not found")
        }
    }
}
