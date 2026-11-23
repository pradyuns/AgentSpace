import Foundation
import AgentSpaceCore
import AgentSpaceEvalSupport

final class MCPAdapter: @unchecked Sendable {
    let tool: String
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private let errors: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let log: URL

    init(tool: String, directory: URL, binary: URL) throws {
        self.tool = tool
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        log = directory.appendingPathComponent("mcp.jsonl")
        let errorURL = directory.appendingPathComponent("adapter-stderr.log")
        _ = FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        errors = try FileHandle(forWritingTo: errorURL)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "Evals/mcp_adapter.py", tool, directory.path, binary.path]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTSPACE_CLOCK_OFFSET"] = String(ProcessInfo.processInfo.systemUptime-Date().timeIntervalSince1970)
        environment["AGENTSPACE_ADAPTER_STATE"] = directory.deletingLastPathComponent().appendingPathComponent("state").path
        process.environment = environment
        try process.run()
    }

    func action(_ command: String, workspace: String, arguments: [String]) -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        do {
            let request: JSONValue = .object(["command": .string(command), "workspace": .string(workspace),
                                              "arguments": .array(arguments.map(JSONValue.string))])
            try input.fileHandleForWriting.write(contentsOf: MCPFraming.encode(request))
            while buffer.firstIndex(of: 10) == nil {
                let data = output.fileHandleForReading.availableData
                guard !data.isEmpty else { throw AgentSpaceError("adapter_closed", "Inspect adapter-stderr.log") }
                buffer.append(data)
            }
            let newline = buffer.firstIndex(of: 10)!
            let data = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            return .object(["ok": .bool(false), "error": .object(["code": .string("adapter_error"), "message": .string(String(describing: error))])])
        }
    }

    func finish(trace: TraceWriter, trial: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        try errors.close()
        if FileManager.default.fileExists(atPath: log.path) {
            for event in try TraceParser.parse(Data(contentsOf: log)) {
                trace.emit(event.kind, trial: trial, event.payload, at: event.time)
            }
        }
    }
}
