import Foundation

public struct MCPFraming {
    public static let maximumBytes = 1_048_576
    private var buffer = Data()
    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let newline = buffer.firstIndex(of: 10) {
            guard buffer.distance(from: buffer.startIndex, to: newline) <= Self.maximumBytes else {
                throw AgentSpaceError("frame_too_large", "MCP message exceeds one MiB")
            }
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            if !line.isEmpty { messages.append(line) }
        }
        guard buffer.count <= Self.maximumBytes else {
            throw AgentSpaceError("frame_too_large", "MCP message exceeds one MiB")
        }
        return messages
    }

    public func finish() throws {
        guard buffer.isEmpty else { throw AgentSpaceError("incomplete_frame", "MCP input ended before newline") }
    }

    public static func encode(_ value: JSONValue) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(10)
        return data
    }

    public static func response(id: JSONValue, result: JSONValue) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    public static func error(id: JSONValue = .null, code: Int, message: String) -> JSONValue {
        .object(["jsonrpc": .string("2.0"), "id": id,
                 "error": .object(["code": .number(Double(code)), "message": .string(message)])])
    }
}
