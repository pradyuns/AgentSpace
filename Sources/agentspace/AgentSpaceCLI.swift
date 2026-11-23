import AgentSpaceCore
import Foundation
import Darwin

@main
struct AgentSpaceCLI {
    // The command/option contract lives in AgentSpaceCore.AgentSpaceCommands so the CLI and the
    // MCP server stay identical; these aliases keep existing call sites readable.
    static let commands=AgentSpaceCommands.commands
    static let common=AgentSpaceCommands.common
    static let selectors=AgentSpaceCommands.selectors
    static let allowed=AgentSpaceCommands.allowed
    static let flags=AgentSpaceCommands.flags

    @MainActor static func main() async {
        var output:JSONValue
        var success=false
        do {
            let args=Array(CommandLine.arguments.dropFirst())
            if args == ["mcp"] { await MCPServer.run(); return }
            if args.isEmpty || args==["--help"] || args==["help"] {
                output = .object(["ok":.bool(true),"commands":.array(commands.sorted().map{.string($0)}),
                    "usage":.string("agentspace <command> --workspace <name> [--option value]. Default workspace: default. See README.md for commands.")])
                success=true
            } else {
                let command=args[0]
                guard commands.contains(command) else {throw AgentSpaceError("unknown_command","Unknown command '\(command)'")}
                var values:[String:String]=[:];var present:Set<String>=[];var i=1
                let valid=common.union(allowed[command] ?? [])
                while i<args.count {
                    guard args[i].hasPrefix("--") else {throw AgentSpaceError("invalid_argument","Expected a named option, got '\(args[i])'")}
                    let key=String(args[i].dropFirst(2))
                    guard valid.contains(key) else {throw AgentSpaceError("unknown_option","Unknown option --\(key) for \(command)")}
                    guard values[key]==nil && !present.contains(key) else {throw AgentSpaceError("duplicate_option","Duplicate --\(key)")}
                    if flags.contains(key) {present.insert(key);i+=1}
                    else {
                        guard i+1<args.count else {throw AgentSpaceError("missing_value","Missing value for --\(key)")}
                        values[key]=args[i+1];i+=2
                    }
                }
                let store=try StateStore()
                output=await WorkspaceController(store:store).run(command,workspace:values["workspace"] ?? "default",options:CommandOptions(values:values,flags:present))
                if case .object(let object)=output,object["ok"] == .bool(true) {success=true}
            }
        } catch {
            let error=error as? AgentSpaceError ?? AgentSpaceError("operation_failed",String(describing:error))
            output = .object(["ok":.bool(false),"error":.object(["code":.string(error.code),"message":.string(error.description)])])
        }
        do {
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
            var data=try encoder.encode(output);data.append(0x0a)
            try FileHandle.standardOutput.write(contentsOf:data)
        } catch {exit(2)}
        exit(success ? 0:1)
    }
}
