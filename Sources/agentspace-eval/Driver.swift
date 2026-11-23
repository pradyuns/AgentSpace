import AppKit
import ApplicationServices
import AgentSpaceCore
import AgentSpaceEvalSupport

struct CommandResult: Sendable {
    let output: JSONValue
    let exitCode: Int32
    let milliseconds: Double
}

@MainActor
final class AgentDriver {
    let binary: URL
    let state: URL
    let trace: TraceWriter
    let monitor: Instrumentation
    let trial: String
    var workspaces: [String] = []
    var cleanupResults: [Bool] = []
    var observedAgentValues: [String] = []
    var expectedAgentValues: [String] = []
    var editableContaminationChecks: [Bool] = []
    var taskChecks: [String: Bool] = [:]
    var chromeStrategy = "standard"
    var preparedLaunch: CommandResult?
    var adapter: MCPAdapter?
    var unsupportedSteps: [String] = []
    var unavailableChecks: Set<String> = []
    var probePIDs: [String: Int32] = [:]
    var probeOffsets: [String: (Double, Double)] = [:]
    var probeNativeWindows: Set<String> = []
    var probeNumber = 0
    /// App pids the virtual-display session reported as launched - checked at OS level after
    /// stop-workspace instead of trusting a reply alone.
    var sessionPIDs: [Int32] = []
    /// The display-host identity - pid + start time - recorded at get-status:
    /// after stop-workspace the audited process must be gone, and a recycled
    /// pid can never be mistaken for it.
    var vdHostPID: Int32?
    var vdHostStart: TimeInterval?

    init(binary: URL, state: URL, trace: TraceWriter, monitor: Instrumentation, trial: String) {
        self.binary=binary; self.state=state; self.trace=trace; self.monitor=monitor; self.trial=trial
    }
    func action(_ command: String, _ workspace: String, _ args: [String] = []) async -> CommandResult {
        let kind = command == "prepare" ? "chrome" : args.firstIndex(of: "--app").flatMap { args.indices.contains($0+1) ? args[$0+1] : nil }
        let before = kind.map { StartingStatePreparation.identities($0) } ?? []
        if let adapter {
            let start = ProcessInfo.processInfo.systemUptime
            let output = await Task.detached { adapter.action(command, workspace: workspace, arguments: args) }.value
            let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
            if output["error"]["code"].string == "unsupported" {
                unsupportedSteps.append(command+": "+(output["error"]["message"].string ?? ""))
            }
            if let pid = output["serverPID"].number { monitor.setTarget(Int32(pid), role: "mcp-server") }
            if let pid = output["result"]["app"]["pid"].number {
                monitor.setTarget(Int32(pid), role: "target-"+(output["result"]["app"]["kind"].string ?? "app"))
            }
            let code: Int32 = output["ok"].bool == true ? 0 : 1
            recordBehavior(command, kind: kind, before: before, output: output)
            trace.emit("agent.action", trial: trial, .object(["command": .string(command), "workspace": .string(workspace),
                "arguments": .array(args.map(JSONValue.string)), "latencyMs": .number(elapsed), "exitCode": .number(Double(code)), "output": output]))
            return CommandResult(output: output, exitCode: code, milliseconds: elapsed)
        }
        let binary = binary, state = state, trace = trace, monitor = monitor, trial = trial
        let result = await Task.detached { () -> CommandResult in
            let start = ProcessInfo.processInfo.systemUptime
            let arguments = [command, "--workspace", workspace] + args
            trace.emit("agent.start", trial: trial, .object(["command": .string(command), "workspace": .string(workspace),
                "arguments": .array(args.map(JSONValue.string))]), at: start)
            let process = Process(), output = Pipe(), errors = Pipe()
            process.executableURL = binary; process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment; environment["AGENTSPACE_HOME"] = state.path
            process.environment = environment; process.standardOutput = output; process.standardError = errors
            var json: JSONValue, code: Int32 = -1
            do {
                try process.run()
                let pid = process.processIdentifier
                monitor.setTarget(pid, role: "agent")
                let timeout = DispatchWorkItem { if pid > 1, process.isRunning { kill(pid, SIGKILL) } }
                DispatchQueue.global().asyncAfter(deadline: .now()+60, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let stderr = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit(); timeout.cancel(); monitor.removeTarget(pid)
                code = process.terminationStatus
                json = (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .object([
                    "ok": .bool(false), "error": .object(["code": .string("invalid_worker_output"),
                    "message": .string(String(data: data, encoding: .utf8) ?? "non-UTF8")])
                ])
                if !stderr.isEmpty { trace.emit("agent.stderr", trial: trial, .string(String(decoding: stderr, as: UTF8.self))) }
            } catch {
                json = .object(["ok": .bool(false), "error": .object(["code": .string("worker_failed"), "message": .string(String(describing: error))])])
            }
            let elapsed = (ProcessInfo.processInfo.systemUptime-start)*1000
            trace.emit("agent.action", trial: trial, .object(["command": .string(command), "workspace": .string(workspace),
                "arguments": .array(args.map(JSONValue.string)), "latencyMs": .number(elapsed),
                "exitCode": .number(Double(code)), "output": json]))
            return CommandResult(output: json, exitCode: code, milliseconds: elapsed)
        }.value
        if let pid = result.output["result"]["app"]["pid"].number {
            monitor.setTarget(Int32(pid), role: "target-\(result.output["result"]["app"]["kind"].string ?? "app")")
        }
        if let pid = result.output["result"]["hostPID"].number {
            monitor.setTarget(Int32(pid), role: "display-host")
        }
        recordBehavior(command, kind: kind, before: before, output: result.output)
        return result
    }

    func recordBehavior(_ command: String, kind: String?, before: Set<String>, output: JSONValue) {
        guard ["launch-app", "prepare"].contains(command), let kind else { return }
        let after = StartingStatePreparation.identities(kind)
        let reported = output["result"]["app"]["pid"].number.map(Int32.init)
        let token = reported.flatMap { StartingStatePreparation.identity($0) }
        trace.emit("benchmark.app_behavior", trial: trial, .object(["kind": .string(kind),
            "before": .array(before.sorted().map(JSONValue.string)), "after": .array(after.sorted().map(JSONValue.string)),
            "reportedPID": reported.map { .number(Double($0)) } ?? .null,
            "classification": .string(StartingState.behavior(reported: output["ok"].bool == true ? token : nil, before: before, after: after))]))
    }

    func create(_ name: String) async -> Bool {
        workspaces.append(name)
        return await action("create-workspace", name).output["ok"].bool == true
    }
    func nodes(_ result: CommandResult) -> [JSONValue] {
        func flatten(_ node: JSONValue) -> [JSONValue] { [node] + node["children"].array.flatMap(flatten) }
        let root = result.output["result"]["tree"]
        return root == .null ? [] : flatten(root)
    }
    func screenshot(_ result: CommandResult) -> Bool {
        guard let path = result.output["result"]["screenshot"]["path"].string else { return false }
        return NSImage(contentsOfFile: path) != nil
    }
    func textEdit(_ suffix: String = "text") async {
        let name = "\(trial)-\(suffix)"
        taskChecks["text_workspace_created"] = await create(name)
        let launch = await action("launch-app", name, ["--app", "textedit"])
        taskChecks["text_launch"] = launch.output["ok"].bool == true
        for (i, chunk) in ["AGENT-A", "AGENT-B", "AGENT-C"].enumerated() {
            if i > 0 { _ = await action("key", name, ["--key", "return"]) }
            _ = await action("type-text", name, ["--role", "AXTextArea", "--text", chunk])
        }
        let observation = await action("observe", name, ["--screenshot"])
        let text = nodes(observation).first { $0["role"].string == "AXTextArea" }?["value"].string
        let expected = "AGENT-A\nAGENT-B\nAGENT-C"
        taskChecks["text_exact"] = text == expected
        taskChecks["text_screenshot"] = screenshot(observation)
        expectedAgentValues.append(expected)
        if let text { observedAgentValues.append(text) }
        trace.emit("assert.text", trial: trial, .object(["expected": .string(expected), "actual": text.map(JSONValue.string) ?? .null]))
    }

    func browser(_ variant: String, stress: Int = 0) async {
        let name = "\(trial)-web"
        if preparedLaunch == nil {taskChecks["browser_workspace_created"] = await create(name)}
        else {taskChecks["browser_workspace_created"] = true}
        let app = variant.hasPrefix("safari") ? "safari" : "chrome"
        var args = ["--app", app, "--file", URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/test-page.html").path]
        if variant.contains("restore-on") { args.append("--restore-focus") }
        if app == "chrome" { args += ["--chrome-launch-strategy", chromeStrategy] }
        let launch: CommandResult
        if let preparedLaunch {launch=preparedLaunch}
        else {launch=await action("launch-app", name, args)}
        taskChecks["browser_launch"] = launch.output["ok"].bool == true
        _ = await action("type-text", name, ["--role", "AXTextField", "--title", "Probe input", "--text", "AGENTFORM"])
        _ = await action("click", name, ["--role", "AXButton", "--title", "Probe button"])
        _ = await action("click", name, ["--role", "AXCheckBox", "--index", "0"])
        var extra = ""
        var stressDispatched = true
        for i in 0..<stress {
            let operation: CommandResult
            switch i % 3 {
            case 0:
                operation = await action("type-text", name, ["--role", "AXTextField", "--title", "Probe input", "--text", "Z"]); extra += "Z"
            case 1: operation = await action("click", name, ["--role", "AXButton", "--title", "Clicked"])
            default: operation = await action("scroll", name, ["--direction", i%2 == 0 ? "up" : "down", "--amount", "1"])
            }
            stressDispatched = stressDispatched && operation.exitCode == 0 && operation.output["ok"].bool == true
        }
        _ = await action("scroll", name, ["--direction", "down", "--amount", "1"])
        try? await Task.sleep(for: .milliseconds(400))
        let observation = await action("observe", name, ["--screenshot"])
        let tree = nodes(observation)
        let input = tree.first { $0["role"].string == "AXTextField" && $0["title"].string == "Probe input" }?["value"].string
        let checkbox = tree.first { $0["role"].string == "AXCheckBox" && ($0["title"].string == "Probe checkbox" || $0["label"].string == "Probe checkbox") }
        let expected = "AGENTFORM"+extra
        taskChecks["browser_input_exact"] = input == expected
        taskChecks["browser_button"] = tree.contains { $0["title"].string == "Clicked" } && tree.contains { $0["value"].string == "Button clicked" }
        taskChecks["browser_checkbox"] = ["1", "true"].contains(checkbox?["value"].string ?? "")
        taskChecks["browser_bottom_marker"] = tree.contains { $0["title"].string == "Bottom marker: reached" }
        taskChecks["browser_screenshot"] = screenshot(observation)
        if stress > 0 {
            taskChecks["stress_operation_count"] = stress >= 200
            taskChecks["stress_all_operations_dispatched"] = stressDispatched
        }
        let editable = tree.filter { ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains($0["role"].string ?? "") }
        let opened = launch.output["result"]["openedURL"].string.flatMap(URL.init(string:))?.resolvingSymlinksInPath().path
        for node in editable {
            guard let value = node["value"].string else { continue }
            if node["title"].string == "Probe input" {
                editableContaminationChecks.append(!value.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) })
            } else if node["title"].string == "Probe textarea" {
                editableContaminationChecks.append(value.isEmpty)
            } else if node["title"].string == "Address and search bar" || node["label"].string == "smart search field" {
                let decoded = value.removingPercentEncoding ?? value
                let url = decoded.hasPrefix("file:") ? URL(string: decoded) : URL(fileURLWithPath: decoded)
                editableContaminationChecks.append(url?.resolvingSymlinksInPath().path == opened && opened != nil)
            } else {
                editableContaminationChecks.append(value.isEmpty)
            }
        }
        expectedAgentValues.append(expected)
        if let input { observedAgentValues.append(input) }
        trace.emit("assert.browser", trial: trial, .object([
            "expectedInput": .string(expected), "actualInput": input.map(JSONValue.string) ?? .null,
            "checkbox": checkbox ?? .null, "checks": .object(taskChecks.mapValues(JSONValue.bool)),
            "editableControls": .array(editable),
            "stressOperations": .number(Double(stress))
        ]))
    }

    func stop(_ name: String) async {
        if let adapter, adapter.tool != "agentspace" {
            let response = await action("stop-workspace", name)
            let pids = response.output["result"]["ownedPIDs"].array.compactMap { $0.number.map(Int32.init) }
            let leftovers = pids.filter { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
            let passed = response.output["ok"].bool == true && leftovers.isEmpty
            cleanupResults.append(passed)
            trace.emit("assert.cleanup", trial: trial, .object(["workspace": .string(name), "passed": .bool(passed),
                "ownedPIDs": .array(pids.map { .number(Double($0)) }), "leftoverPIDs": .array(leftovers.map { .number(Double($0)) })]))
            for pid in pids { monitor.removeTarget(pid) }
            return
        }
        let saved: Workspace? = try? JSONDecoder().decode(Workspace.self, from: Data(contentsOf: state.appendingPathComponent(name).appendingPathComponent("workspace.json")))
        let response = await action("stop-workspace", name)
        let noPIDs = saved?.apps.filter(\.owned).allSatisfy { record in
            guard let app = NSRunningApplication(processIdentifier: record.pid) else { return true }
            return app.isTerminated || app.launchDate != record.launchDate || app.bundleIdentifier != record.bundleIdentifier
        } ?? false
        let noDirectory = saved.map { !FileManager.default.fileExists(atPath: $0.temporaryDirectory) } ?? false
        if let destroyed = response.output["result"]["session"]["sessionDestroyed"].bool {
            taskChecks["vd_session_destroyed"] = destroyed && response.output["ok"].bool == true
            // Do not trust the reply alone: the session's own app pids AND the
            // display host must be gone from the OS process list.
            let leftovers = sessionPIDs.filter { NSRunningApplication(processIdentifier: $0)?.isTerminated == false }
            taskChecks["vd_session_pids_gone"] = leftovers.isEmpty
            if !leftovers.isEmpty {
                trace.emit("assert.vd_session_pids", trial: trial,
                    .object(["leftovers": .array(leftovers.map { .number(Double($0)) })]))
            }
            if let hostPID = vdHostPID {
                // Identity audit, not a bare kill(0): a pid that was recycled
                // into another process must still report "gone" - and a pid
                // the record can't prove (<=1, missing start) is never
                // probed at all.
                let gone = !DisplayHost.alive(hostPID, start: vdHostStart)
                taskChecks["vd_host_gone"] = gone
                monitor.removeTarget(hostPID)
                trace.emit("assert.vd_host", trial: trial,
                    .object(["hostPID": .number(Double(hostPID)),
                             "hostStart": vdHostStart.map(JSONValue.number) ?? .null,
                             "gone": .bool(gone)]))
            }
        }
        let passed = response.output["ok"].bool == true && noPIDs && noDirectory
        cleanupResults.append(passed)
        trace.emit("assert.cleanup", trial: trial, .object(["workspace": .string(name), "noOwnedPIDs": .bool(noPIDs),
            "noTemporaryDirectory": .bool(noDirectory), "passed": .bool(passed)]))
        if let saved { for record in saved.apps where record.owned { monitor.removeTarget(record.pid) } }
    }

    /// S7: AgentSpace's own virtual-display session - visual-mode workspace, a
    /// display host + CGVirtualDisplay, coordinate click/move, typed text on a
    /// placed window, observe + window screenshot, routing status, then an
    /// independent audit: after stop-workspace the OS must show no display-host
    /// process and no session app pids - not just a trusting reply.
    /// When the read-only prerequisites are missing (host binary, runtime
    /// CGVirtualDisplay API, AX grant) the scenario skips honestly: the trial
    /// still records interference observations while the simulated human runs,
    /// and the no-session create/stop path still exercises cleanup.
    func virtualDisplay() async {
        let name = "\(trial)-vd"
        let probe = await action("self-test", name)
        let vd = probe.output["result"]["virtualDisplay"]
        let hostFound = vd["executable"].string != nil
        let apiOK = vd["api"].string?.hasPrefix("available") == true
        let axOK = probe.output["result"]["checks"].array.first { $0["name"].string == "accessibility" }?["ok"].bool == true
        guard hostFound, apiOK, axOK else {
            let detail = probe.output["result"]["checks"].array
                .filter { ["virtualDisplayHost", "virtualDisplayAPI", "accessibility"].contains($0["name"].string ?? "") && $0["ok"].bool == false }
                .compactMap { $0["detail"].string }.joined(separator: "; ")
            unsupportedSteps.append("virtual-display: \(detail.isEmpty ? "native display prerequisites unavailable" : detail)")
            taskChecks["vd_skipped"] = true
            _ = await create(name)
            await stop(name)
            trace.emit("assert.vd_skip", trial: trial, .object(["detail": .string(detail)]))
            return
        }
        taskChecks["vd_workspace_created"] = await create(name)
        let launch = await action("launch-app", name, ["--app", "textedit", "--backend", "virtual-display", "--interaction", "visual"])
        taskChecks["vd_launch"] = launch.output["ok"].bool == true
        taskChecks["vd_routing_recorded"] = launch.output["result"]["routing"]["resolvedBackend"].string == "virtual-display"
            && launch.output["result"]["routing"]["requestedBackend"].string == "virtual-display"
        taskChecks["vd_display_created"] = launch.output["result"]["displayID"].number != nil
        sessionPIDs = launch.output["result"]["launchedApps"].array.compactMap { $0["pid"].number }.map { Int32($0) }
        // The helper is part of the workspace footprint: sample its resources
        // alongside the target apps so the report can aggregate helper+target.
        if let hostPID = launch.output["result"]["hostPID"].number { monitor.setTarget(Int32(hostPID), role: "display-host") }
        let click = await action("click", name, ["--x", "80", "--y", "80"])
        taskChecks["vd_click_dispatched"] = click.output["ok"].bool == true
        let move = await action("move", name, ["--x", "160", "--y", "160"])
        taskChecks["vd_move_dispatched"] = move.output["ok"].bool == true
        _ = await action("type-text", name, ["--text", "VD-AGENT", "--role", "AXTextArea"])
        let observation = await action("observe", name, ["--screenshot"])
        let text = nodes(observation).first { $0["role"].string == "AXTextArea" }?["value"].string
        taskChecks["vd_text_typed"] = text?.contains("VD-AGENT") == true
        taskChecks["vd_screenshot"] = screenshot(observation)
        let status = await action("get-status", name)
        taskChecks["vd_status_reports_backend"] = status.output["result"]["backend"].string == "virtual-display"
            && status.output["result"]["capabilities"]["coordinate"].bool == true
        // Independent audit recorded for stop(): the display host's identity -
        // pid + start time - so a recycled pid can never be misreported.
        let hostPID = status.output["result"]["virtualDisplay"]["record"]["hostPID"].number.map { Int32($0) }
        vdHostStart = status.output["result"]["virtualDisplay"]["record"]["hostStart"].number
        if let hostPID { monitor.setTarget(hostPID, role: "display-host") }
        vdHostPID = hostPID
        if let text { observedAgentValues.append(text) }
        trace.emit("assert.vd", trial: trial, .object(["expected": .string("VD-AGENT"),
            "actual": text.map(JSONValue.string) ?? .null,
            "checks": .object(taskChecks.mapValues(JSONValue.bool))]))
    }

    func lifecycle() async {
        var launches = 0, crashObservedDead = false
        for i in 0..<10 {
            let name = "\(trial)-cycle-\(i)"
            _ = await create(name)
            let launch = await action("launch-app", name, ["--app", "textedit"])
            if launch.output["ok"].bool == true { launches += 1 }
            if adapter == nil, i == 5, let pid = launch.output["result"]["app"]["pid"].number,
               launch.output["result"]["app"]["owned"].bool == true, Int32(pid) > 1 {
                kill(Int32(pid), SIGKILL)
                trace.emit("agent.crash_injected", trial: trial, .object(["pid": .number(pid)]))
                try? await Task.sleep(for: .milliseconds(300))
                let status = await action("get-status", name)
                crashObservedDead = status.output["result"]["apps"].array.contains {
                    $0["record"]["pid"].number == pid && $0["alive"].bool == false
                }
            }
            await stop(name)
        }
        taskChecks["lifecycle_ten_launches"] = launches == 10
        if adapter == nil { taskChecks["crash_reported_dead"] = crashObservedDead }
    }

    func failureModes(windowlessBundle: URL, directory: URL) async throws {
        let name = "\(trial)-failure"
        _ = await create(name)
        _ = await action("launch-app", name, ["--app", "textedit"])
        _ = await action("type-text", name, ["--role", "AXTextArea", "--text", "AGENT-ORIGINAL"])
        let coordinate = await action("click", name, ["--x", "100", "--y", "100"])
        taskChecks["coordinate_explicit_error"] = coordinate.exitCode != 0 && coordinate.output["error"]["code"].string != nil
        let stale = await action("click", name, ["--ref", "0.999999"])
        taskChecks["nonexistent_ref_explicit_error"] = stale.exitCode != 0 && stale.output["error"]["code"].string == "element_not_found"
        let combo = await action("key", name, ["--key", "cmd+a", "--role", "AXTextArea"])
        _ = await action("type-text", name, ["--role", "AXTextArea", "--text", "AGENT-REPLACED"])
        let observed = await action("observe", name)
        let value = nodes(observed).first { $0["role"].string == "AXTextArea" }?["value"].string
        taskChecks["cmd_a_effective_or_explicit_error"] = combo.exitCode != 0 || combo.output["result"]["warning"].string == "unverified_modifier_combo" || value == "AGENT-REPLACED"
        if let value { observedAgentValues.append(value) }
        trace.emit("assert.cmd_a", trial: trial, .object(["expected": .string("AGENT-REPLACED"), "actual": value.map(JSONValue.string) ?? .null,
            "command": combo.output, "passed": .bool(taskChecks["cmd_a_effective_or_explicit_error"] == true)]))
        let modifier = await action("key", name, ["--key", "ctrl+right"])
        taskChecks["modifier_explicit_warning"] = modifier.output["result"]["verified"].bool == false && modifier.output["result"]["warning"].string == "unverified_modifier_combo"
        let replacement = await action("type-text", name, ["--role", "AXTextArea", "--replace", "--text", "AGENT-REPLACED"])
        let emptyReplacement = await action("type-text", name, ["--role", "AXTextArea", "--replace", "--text", ""])
        let missing = await action("type-text", name, ["--replace", "--text", "AGENT"])
        taskChecks["replace_verified"] = replacement.output["result"]["verified"].bool == true
        taskChecks["replace_empty_verified"] = emptyReplacement.output["result"]["verified"].bool == true
        taskChecks["replace_requires_element"] = missing.output["error"]["code"].string == "element_required"
        if let pid = try? StateStore(root: state).load(name).target?.pid {
            let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 200,y: 200), mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: 0x504944)
            event?.postToPid(pid)
            trace.emit("agent.pid_pointer_probe", trial: trial, .object(["pid": .number(Double(pid)), "marker": .number(Double(0x504944))]))
        }

        let process = Process(); process.executableURL = windowlessBundle.appendingPathComponent("Contents/MacOS/HumanPad")
        let readyURL = directory.appendingPathComponent("windowless-ready.json")
        process.arguments = ["--no-window", "--log", directory.appendingPathComponent("windowless.jsonl").path,
                             "--ready", readyURL.path, "--text", directory.appendingPathComponent("unused.txt").path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: readyURL.path) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        guard FileManager.default.fileExists(atPath: readyURL.path),
              let app = NSRunningApplication(processIdentifier: process.processIdentifier), let bundle = app.bundleIdentifier else {
            throw AgentSpaceError("windowless_fixture_failed", "Windowless app did not register")
        }
        do {
            let store = try StateStore(root: state)
            var workspace = try store.load(name)
            var record = workspace.apps[0]
            record.pid = app.processIdentifier; record.bundleIdentifier = bundle; record.launchDate = app.launchDate; record.kind = "windowless-fixture"; record.owned = true
            workspace.apps.append(record); try store.save(workspace)
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windows: CFTypeRef?
        let axResult = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
        let empty = (windows as? [AXUIElement])?.isEmpty == true || axResult == .noValue
        trace.emit("fixture.windowless", trial: trial, .object(["pid": .number(Double(app.processIdentifier)), "emptyAXWindows": .bool(empty), "axError": .number(Double(axResult.rawValue))]))
        taskChecks["windowless_fixture_has_no_ax_window"] = empty
        let response = await action("target-window", name, ["--pid", String(app.processIdentifier)])
        taskChecks["windowless_explicit_error"] = empty && response.exitCode != 0 && response.output["error"]["code"].string == "window_not_found"
    }
}
