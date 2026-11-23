import Foundation
import ApplicationServices
import AgentSpaceCore
import AgentSpaceEvalSupport

extension AgentDriver {
    func benchmarkCheck(_ key: String, _ passed: Bool) {
        taskChecks[key] = (taskChecks[key] ?? true) && passed
    }
    func probeSupported(_ result: CommandResult, check: String) -> Bool {
        let code = result.output["error"]["code"].string ?? ""
        if ["unsupported", "interaction_required", "addressed_web_typing_unsupported"].contains(code) {
            unavailableChecks.insert(check)
            unsupportedSteps.append(check+": "+(result.output["error"]["message"].string ?? code))
            return false
        }
        return true
    }

    func probeLaunch(_ suffix: String, backend: String, visual: Bool) async -> String {
        let name = "\(trial)-\(suffix)-\(probeNumber)"
        probeNumber += 1
        workspaces.append(name)
        let start = ProcessInfo.processInfo.systemUptime
        let hybrid = adapter == nil || adapter?.tool == "agentspace"
        let visualRoute = visual && ["auto", "virtual-display"].contains(backend)
        let route = hybrid ? ["--backend", backend, "--interaction", visualRoute ? "visual" : "semantic"] : []
        let created = await action("create-workspace", name, route)
        let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/interactions.html").path
        let launched = await action("launch-app", name, ["--app", "chrome", "--file", path])
        if hybrid, ["ax", "virtual-display"].contains(launched.output["result"]["routing"]["resolvedBackend"].string ?? "") {
            probeNativeWindows.insert(name)
        }
        if let pid = launched.output["result"]["app"]["pid"].number { probePIDs[name] = Int32(pid) }
        benchmarkCheck(suffix+"_launch", created.output["ok"].bool == true && launched.output["ok"].bool == true)
        if !probeSupported(launched, check: suffix+"_launch") { unavailableChecks.insert(suffix+"_launch") }
        let ready = await action("observe", name, ["--max-nodes", "5000"])
        if hybrid, let web = nodes(ready).first(where: { $0["role"].string == "AXWebArea" }),
           let x = web["frame"]["x"].number, let y = web["frame"]["y"].number,
           let rootX = ready.output["result"]["tree"]["frame"]["x"].number,
           let rootY = ready.output["result"]["tree"]["frame"]["y"].number {
            probeOffsets[name] = (x-rootX, y-rootY)
        }
        let supported = probeSupported(ready, check: suffix+"_ready")
        benchmarkCheck(suffix+"_ready", ready.output["ok"].bool == true)
        trace.emit("benchmark.startup", trial: trial, .object([
            "workspace": .string(name), "ready": .bool(supported && ready.output["ok"].bool == true),
            "latencyMs": .number((ProcessInfo.processInfo.systemUptime-start)*1000)]))
        if hybrid {
            let expected = backend == "auto" ? (visual ? "virtual-display" : "cdp") : backend
            benchmarkCheck(suffix+"_route", launched.output["result"]["routing"]["resolvedBackend"].string == expected)
        } else { unavailableChecks.insert(suffix+"_route") }
        return name
    }

    func probeReading(_ name: String) async -> String {
        if probeNativeWindows.contains(name), let pid = probePIDs[name] {
            _ = await action("target-window", name, ["--pid", String(pid)])
        }
        let observation = await action("observe", name, ["--max-nodes", "5000"])
        var result = observation.output["result"]
        var titles: [JSONValue] = []
        if let pid = probePIDs[name] {
            let app = AXUIElementCreateApplication(pid)
            var windows: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
               let windows = windows as? [AXUIElement] {
                for window in windows {
                    var title: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                       let title = title as? String { titles.append(.string(title)) }
                }
            }
        }
        if case .object(var fields) = result {
            fields["windowTitles"] = .array(titles)
            result = .object(fields)
        }
        let reading = String(decoding: (try? JSONEncoder().encode(result)) ?? Data(), as: UTF8.self)
        trace.emit("benchmark.readback", trial: trial, .object(["workspace": .string(name), "reading": .string(reading)]))
        return reading
    }

    func routingProbe(backend: String) async {
        let name = await probeLaunch("semantic", backend: backend, visual: false)
        let typed = await action("type-text", name, ["--role", "AXTextField", "--title", "Probe input", "--text", "SEMANTIC"])
        if probeSupported(typed, check: "semantic_text_exact") {
            let reading = await probeReading(name)
            let exact = reading.contains("typed=SEMANTIC;") || nodesFromReading(reading, value: "SEMANTIC")
            benchmarkCheck("semantic_text_exact", typed.output["ok"].bool == true && exact)
            if let actual = BenchmarkReading.typedValue(reading) { observedAgentValues.append(actual) }
            expectedAgentValues.append("SEMANTIC")
        }
    }

    private func nodesFromReading(_ reading: String, value: String) -> Bool {
        guard let data = reading.data(using: .utf8), let result = try? JSONDecoder().decode(JSONValue.self, from: data) else { return false }
        func matches(_ node: JSONValue) -> Bool {
            (node["role"].string == "AXTextField" && node["value"].string == value)
                || node["children"].array.contains(where: matches)
        }
        return matches(result["tree"])
    }

    func visualProbe(backend: String) async {
        let name = await probeLaunch("visual", backend: backend, visual: true)
        let offset = probeOffsets[name] ?? (0, 0)
        func point(_ x: Double, _ y: Double) -> [String] {
            ["--x", String(x+offset.0), "--y", String(y+offset.1)]
        }
        let click = await action("click", name, point(198, 104))
        let typed: CommandResult
        if click.output["ok"].bool == true { typed = await action("type-text", name, ["--text", "VISUAL"]) }
        else { typed = click }
        if probeSupported(typed, check: "visual_text_exact") {
            let reading = await probeReading(name)
            let exact = reading.contains("typed=VISUAL;") || nodesFromReading(reading, value: "VISUAL")
            benchmarkCheck("visual_text_exact", typed.output["ok"].bool == true && exact)
            if let actual = BenchmarkReading.typedValue(reading) { observedAgentValues.append(actual) }
            expectedAgentValues.append("VISUAL")
        }
        for (command, arguments, check, pattern) in [
            ("drag", point(126, 173)+["--to-x", String(400+offset.0), "--to-y", String(173+offset.1)], "slider_changed", "slider=(?:[1-9][0-9]|100)"),
            ("move", point(100, 255), "hover_true", "hovered=true"),
            ("scroll", point(100, 390)+["--dy", "-400", "--ticks", "1"], "scroll_changed", "scrollTop=[1-9][0-9]*")
        ] {
            let result = await action(command, name, arguments)
            if probeSupported(result, check: check) {
                try? await Task.sleep(for: .milliseconds(150))
                let reading = await probeReading(name)
                benchmarkCheck(check, result.output["ok"].bool == true && reading.range(of: pattern, options: .regularExpression) != nil)
            }
        }
    }
}
