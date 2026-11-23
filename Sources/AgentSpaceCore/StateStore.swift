import Foundation
import Darwin

/// The store is safe to touch from the spawn thread while the main actor
/// awaits the handshake: every write is an atomic file replace and the lock
/// only guards against a second process, so a single in-process concurrent
/// save cannot corrupt state.
public final class StateStore: @unchecked Sendable {
    public let root: URL
    private let lockFD: Int32
    public init(root: URL? = nil) throws {
        self.root = root ?? ProcessInfo.processInfo.environment["AGENTSPACE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentSpace", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        lockFD = Darwin.open(self.root.appendingPathComponent(".lock").path, O_CREAT | O_RDWR, 0o600)
        guard lockFD >= 0 else { throw AgentSpaceError("state_lock", "Cannot open state lock") }
        // The lock must die with THIS process - a helper that inherited the fd
        // would hold the workspace lock long after the CLI that spawned it
        // exited, making every later command report workspace_busy.
        _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            close(lockFD); throw AgentSpaceError("workspace_busy", "Another command is using the state directory; retry when it finishes")
        }
    }
    /// Regression-check surface: the state lock is close-on-exec so no spawned
    /// helper can inherit the flock.
    public func lockFileDescriptorIsCloseOnExec() -> Bool {
        (fcntl(lockFD, F_GETFD) & FD_CLOEXEC) != 0
    }
    deinit { flock(lockFD, LOCK_UN); close(lockFD) }
    public static func validate(_ name: String) throws {
        guard !name.isEmpty, name.count <= 80,
              name.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }) else {
            throw AgentSpaceError("invalid_workspace", "Workspace name must be 1–80 ASCII letters, digits, hyphens or underscores")
        }
    }
    public func directory(_ name: String) throws -> URL { try Self.validate(name); return root.appendingPathComponent(name, isDirectory: true) }
    public func load(_ name: String) throws -> Workspace {
        let path = try directory(name).appendingPathComponent("workspace.json")
        guard FileManager.default.fileExists(atPath: path.path) else { throw AgentSpaceError("workspace_not_found", "Create workspace '\(name)' first") }
        return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: path))
    }
    public func save(_ workspace: Workspace) throws {
        let dir = try directory(workspace.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace).write(to: dir.appendingPathComponent("workspace.json"), options: .atomic)
    }
    public func append(_ log: ActionLog, workspace: String) throws {
        let url = try directory(workspace).appendingPathComponent("actions.jsonl")
        let encoder=JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(log); data.append(0x0a)
        if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let file=try FileHandle(forWritingTo:url); defer {try? file.close()}
        try file.seekToEnd(); try file.write(contentsOf:data)
    }
    public func recent(_ name: String, limit: Int = 10) throws -> [JSONValue] {
        let url = try directory(name).appendingPathComponent("actions.jsonl")
        guard FileManager.default.fileExists(atPath:url.path) else {return []}
        return try String(contentsOf:url,encoding:.utf8).split(separator:"\n").suffix(limit).map {
            try JSONDecoder().decode(JSONValue.self,from:Data($0.utf8))
        }
    }
    public func list() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil)
            .filter {FileManager.default.fileExists(atPath:$0.appendingPathComponent("workspace.json").path)}.map(\.lastPathComponent).sorted()
    }
    public func create(_ name: String, backend: String? = nil, interaction: String? = nil) throws -> Workspace {
        let dir=try directory(name)
        guard !FileManager.default.fileExists(atPath:dir.appendingPathComponent("workspace.json").path) else {throw AgentSpaceError("workspace_exists","Workspace already exists")}
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("AgentSpace-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        var workspace=Workspace(name:name,temporaryDirectory:temp.path)
        workspace.requestedBackend=backend
        workspace.requestedInteraction=interaction
        do {try save(workspace)} catch {try? FileManager.default.removeItem(at:temp);throw error}
        return workspace
    }
}
