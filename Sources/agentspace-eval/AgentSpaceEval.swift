import AppKit
import ApplicationServices
import AgentSpaceCore
import AgentSpaceEvalSupport

struct Configuration {
    var trials = 5
    var duration = 30.0
    var stress = 200
    var scenarios = ["S1", "S2", "S3", "S4", "S5", "S6"]
    var output = "Evals/results"
    var chromeStrategy = "standard"
    var comparisonTool: String?
    var startingState = StartingState.inherited
    var backends = ["auto", "cdp", "ax", "virtual-display"]
    init(_ arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            guard i+1 < arguments.count else { throw AgentSpaceError("invalid_argument", "Expected --trials N --duration seconds --stress-ops N --scenarios S1,S2 --output directory") }
            let value = arguments[i+1]
            switch arguments[i] {
            case "--trials": guard let n = Int(value), (1...100).contains(n) else { throw AgentSpaceError("invalid_trials", "trials must be 1...100") }; trials=n
            case "--duration": guard let n = Double(value), n.isFinite, n > 0, n <= 3600 else { throw AgentSpaceError("invalid_duration", "duration must be 0...3600 seconds, exclusive of zero") }; duration=n
            case "--stress-ops": guard let n = Int(value), (1...10000).contains(n) else { throw AgentSpaceError("invalid_stress", "stress-ops must be 1...10000") }; stress=n
            case "--scenarios": scenarios = value.split(separator: ",").map(String.init); guard !scenarios.isEmpty, scenarios.allSatisfy({ ["S1","S2","S3","S4","S5","S6","S7","S8","S9","S10"].contains($0) }), Set(scenarios).count == scenarios.count else { throw AgentSpaceError("invalid_scenarios", "Choose unique S1...S10") }
            case "--output": output=value
            case "--starting-state":
                guard let mode = StartingState(rawValue: value), mode != .inherited else { throw AgentSpaceError("invalid_starting_state", "Choose cold or warm") }
                startingState=mode
            case "--backends":
                backends = value.split(separator: ",").map(String.init)
                guard !backends.isEmpty, Set(backends).count == backends.count,
                      backends.allSatisfy({ ["auto", "cdp", "ax", "virtual-display"].contains($0) }) else {
                    throw AgentSpaceError("invalid_backends", "Choose unique auto,cdp,ax,virtual-display")
                }
            case "--chrome-strategy": chromeStrategy=value
            case "--comparison-tool":
                guard ["agentspace", "spaceo", "munim", "opencomputer"].contains(value) else { throw AgentSpaceError("invalid_tool", value) }
                comparisonTool=value
            default: throw AgentSpaceError("unknown_option", arguments[i])
            }
            i += 2
        }
        guard startingState == .inherited || scenarios.allSatisfy({ ["S1", "S2", "S3", "S4", "S5"].contains($0) }) else {
            throw AgentSpaceError("invalid_starting_state", "Matched starting states apply only to S1–S5")
        }
    }
}

@MainActor
final class EvaluationRunner {
    let configuration: Configuration
    let root: URL
    let trace: TraceWriter
    let binaries: URL
    let humanBundle: URL
    let windowlessBundle: URL

    init(configuration: Configuration) throws {
        self.configuration=configuration
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let id = formatter.string(from: Date())+"-"+UUID().uuidString.prefix(8)
        root = URL(fileURLWithPath: configuration.output).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        trace = try TraceWriter(url: root.appendingPathComponent("traces.jsonl"))
        binaries = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.deletingLastPathComponent()
        humanBundle = root.appendingPathComponent("HumanPad.app")
        windowlessBundle = root.appendingPathComponent("Windowless.app")
        try Self.bundle(humanBundle, binary: binaries.appendingPathComponent("HumanPad"), identifier: "org.agentspace.eval.humanpad")
        try Self.bundle(windowlessBundle, binary: binaries.appendingPathComponent("HumanPad"), identifier: "org.agentspace.eval.windowless")
    }
    static func bundle(_ url: URL, binary: URL, identifier: String) throws {
        let directory = url.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: binary, to: directory.appendingPathComponent("HumanPad"))
        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": url.deletingPathExtension().lastPathComponent,
            "CFBundleExecutable": "HumanPad", "CFBundlePackageType": "APPL", "NSHighResolutionCapable": true,
            "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    func run() async throws {
        print("RESULTS \(root.path)"); fflush(stdout)
        let config: JSONValue = .object(["trialsPerVariant": .number(Double(configuration.trials)),
            "minimumHumanDurationSeconds": .number(configuration.duration), "S3MinimumSeconds": .number(max(30, configuration.duration)),
            "stressOperations": .number(Double(configuration.stress)), "scenarios": .array(configuration.scenarios.map(JSONValue.string)),
            "comparisonTool": configuration.comparisonTool.map(JSONValue.string) ?? .null,
            "startingState": .string(configuration.startingState.rawValue),
            "benchmarkBackends": .array(configuration.backends.map(JSONValue.string)),
            "costRootPIDs": ProcessInfo.processInfo.environment["AGENTSPACE_COST_PIDS"].map(JSONValue.string) ?? .null,
            "platform": .string(ProcessInfo.processInfo.operatingSystemVersionString), "simulator": .string("deterministic Unicode HID keys, seeded 85–115ms jitter; 50Hz HID mouse path"),
            "permissions": .object(["accessibility": .bool(AXIsProcessTrusted()), "screenCapture": .bool(CGPreflightScreenCaptureAccess()),
                "listenEvent": .bool(CGPreflightListenEventAccess())])])
        trace.emit("run.configuration", trial: "run", config)
        var results: [TrialResult] = []
        for scenario in configuration.scenarios {
            let variants: [String]
            if ["S8", "S9", "S10"].contains(scenario) {
                variants = configuration.comparisonTool == nil || configuration.comparisonTool == "agentspace"
                    ? configuration.backends : ["default"]
            } else if configuration.startingState != .inherited {
                variants = scenario == "S2" ? ["chrome-restore-off", "safari-range-insertion"] : [scenario == "S3" ? "chrome-restore-off" : "default"]
            } else if configuration.comparisonTool != nil {
                variants = scenario == "S2" ? ["chrome-restore-off", "chrome-prewarmed", "safari-range-insertion"] : [scenario == "S3" ? "chrome-restore-off" : "default"]
            } else {
                variants = ["S2", "S3"].contains(scenario) ? ["chrome-restore-off", "chrome-restore-on", "chrome-prewarmed", "safari-range-insertion"] : [scenario == "S4" ? "chrome-restore-on" : "default"]
            }
            for variant in variants {
                for number in 1...configuration.trials {
                    let id = "\(scenario.lowercased())-\(variant)-\(number)"
                    print("START \(id)"); fflush(stdout)
                    do { results.append(try await trial(scenario, variant: variant, id: id)) }
                    catch {
                        trace.emit("trial.error", trial: id, .string(String(describing: error)))
                        results.append(TrialResult(id: id, scenario: scenario, variant: variant,
                            checks: ["agent_task_completed": false, "human_text_exact": nil, "no_agent_chars_in_human": nil,
                                     "no_human_chars_in_agent": nil, "frontmost_never_changed_by_agent": nil,
                                     "no_untagged_pointer_events": nil, "cursor_exact_at_rest": nil, "cleanup_ok": false, "monitor_coverage": nil],
                            details: .object(["error": .string(String(describing: error))]), failures: ["trial_setup_or_teardown_error"]))
                    }
                    try trace.synchronize()
                    let events = try TraceParser.parse(Data(contentsOf: root.appendingPathComponent("traces.jsonl")))
                    _ = try Report.write(results: results, events: events, configuration: config, root: root)
                    print("END \(id) failures=\(results.last!.failures.joined(separator: ","))"); fflush(stdout)
                }
            }
        }
        trace.emit("run.complete", trial: "run", .object(["trials": .number(Double(results.count))]))
        try trace.synchronize()
        print("SUMMARY \(root.appendingPathComponent("summary.md").path)")
    }

    func trial(_ scenario: String, variant: String, id: String) async throws -> TrialResult {
        let directory = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let textURL = directory.appendingPathComponent("human-final.txt"), readyURL = directory.appendingPathComponent("human-ready.json")
        let humanLog = directory.appendingPathComponent("human.jsonl")
        try await StartingStatePreparation.prepare(configuration.startingState,
            kinds: StartingState.kinds(scenario: scenario, variant: variant), directory: directory, trace: trace, trial: id)
        let costs = Instrumentation(trace: trace, trial: id, humanPID: -1)
        costs.startCosts(roots: ProcessInfo.processInfo.environment["AGENTSPACE_COST_PIDS"] ?? "")
        defer { costs.finishCosts() }
        let adapter = try configuration.comparisonTool.map { try MCPAdapter(tool: $0, directory: directory.appendingPathComponent("mcp"), binary: binaries.appendingPathComponent("agentspace")) }
        defer { try? adapter?.finish(trace: trace, trial: id) }
        var prepared: CommandResult?
        if variant == "chrome-prewarmed" {
            let preparationMonitor=Instrumentation(trace: trace, trial: id+"-preparation", humanPID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
            preparationMonitor.costMonitor = costs
            preparationMonitor.start();await preparationMonitor.waitUntilReady()
            let preparation=AgentDriver(binary: binaries.appendingPathComponent("agentspace"), state: directory.appendingPathComponent("state"), trace: trace, monitor: preparationMonitor, trial: id+"-preparation")
            preparation.adapter = adapter
            prepared=await preparation.action("prepare", id+"-web", ["--file", URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Fixtures/test-page.html").path])
            let observation=await preparation.action("observe", id+"-web", ["--screenshot"])
            let instrumentation=await preparationMonitor.finish()
            trace.emit("browser.preparation", trial: id, .object(["monitor":instrumentation,"launch":prepared!.output,"capturable":.bool(preparation.screenshot(observation)),"beforeHumanSession":.bool(true)]))
        }
        let human = Process(); human.executableURL = humanBundle.appendingPathComponent("Contents/MacOS/HumanPad")
        human.arguments = ["--log", humanLog.path, "--text", textURL.path, "--ready", readyURL.path]
        if scenario == "S10" { human.arguments?.append("--switch-focus") }
        let errorFile = directory.appendingPathComponent("human-stderr.log")
        _ = FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        let errors = try FileHandle(forWritingTo: errorFile); defer { try? errors.close() }
        human.standardError = errors; human.standardOutput = FileHandle.nullDevice
        let humanLaunchStart = ProcessInfo.processInfo.systemUptime
        try human.run()
        defer { if human.isRunning { human.terminate() } }
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: readyURL.path), NSWorkspace.shared.frontmostApplication?.processIdentifier == human.processIdentifier { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard human.isRunning, let data = try? Data(contentsOf: readyURL),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == human.processIdentifier else {
            throw AgentSpaceError("human_not_ready", "HumanPad did not become foreground; inspect human-stderr.log")
        }
        let ready = try JSONDecoder().decode(JSONValue.self, from: data)
        trace.emit("human.lifecycle", trial: id, .object(["phase": .string("startup"),
            "latencyMs": .number((ProcessInfo.processInfo.systemUptime-humanLaunchStart)*1000)]))
        let monitor = Instrumentation(trace: trace, trial: id, humanPID: human.processIdentifier)
        monitor.costMonitor = costs
        monitor.start()
        await monitor.waitUntilReady()
        let simulator = HumanSimulator(monitor: monitor, rect: CGRect(x: ready["x"].number ?? 0, y: ready["y"].number ?? 0,
            width: ready["width"].number ?? 0, height: ready["height"].number ?? 0))
        let start = ProcessInfo.processInfo.systemUptime
        simulator.start()
        trace.emit("trial.start", trial: id, .object(["scenario": .string(scenario), "variant": .string(variant), "humanPID": .number(Double(human.processIdentifier))]))
        let driver = AgentDriver(binary: binaries.appendingPathComponent("agentspace"), state: directory.appendingPathComponent("state"), trace: trace, monitor: monitor, trial: id)
        driver.adapter = adapter
        if prepared?.output["error"]["code"].string == "unsupported" {
            driver.unsupportedSteps.append("launch-app: "+(prepared?.output["error"]["message"].string ?? ""))
        }
        driver.chromeStrategy = configuration.chromeStrategy
        driver.preparedLaunch = prepared
        if prepared != nil {driver.workspaces.append(id+"-web")}
        var driverError: String?
        do {
            switch scenario {
            case "S1": await driver.textEdit()
            case "S2": await driver.browser(variant)
            case "S3":
                await driver.textEdit(); await driver.browser(variant)
                var iteration = 0
                while ProcessInfo.processInfo.systemUptime-start < max(30, configuration.duration) {
                    if !driver.workspaces.isEmpty {
                        let workspace = driver.workspaces[iteration % driver.workspaces.count]
                        _ = await driver.action("observe", workspace, iteration%5 == 0 ? ["--screenshot"] : [])
                    }
                    iteration += 1
                    try await Task.sleep(for: .milliseconds(500))
                }
            case "S4": await driver.browser(variant, stress: configuration.stress)
            case "S5": await driver.lifecycle()
            case "S6": try await driver.failureModes(windowlessBundle: windowlessBundle, directory: directory)
            case "S7": await driver.virtualDisplay()
            case "S8": await driver.routingProbe(backend: variant)
            case "S9": await driver.visualProbe(backend: variant)
            case "S10":
                for _ in 0..<3 {
                    await driver.routingProbe(backend: variant)
                    await driver.visualProbe(backend: variant)
                    for name in driver.workspaces { await driver.stop(name) }
                    driver.workspaces.removeAll()
                }
            default: break
            }
        } catch { driverError = String(describing: error); trace.emit("agent.driver_error", trial: id, .string(driverError!)) }
        let agentDuration = ProcessInfo.processInfo.systemUptime-start
        if scenario != "S5" { for name in driver.workspaces { await driver.stop(name) } }
        let minimumDuration = scenario == "S3" ? max(30, configuration.duration) : configuration.duration
        let remaining = minimumDuration-(ProcessInfo.processInfo.systemUptime-start)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        let expected = await simulator.finish()
        try await Task.sleep(for: .milliseconds(500))
        let instrumentation = await monitor.finish()
        let actual = (try? String(contentsOf: textURL, encoding: .utf8)) ?? ""
        try expected.write(to: directory.appendingPathComponent("human-expected.txt"), atomically: true, encoding: .utf8)
        let humanStopStart = ProcessInfo.processInfo.systemUptime
        human.terminate()
        for _ in 0..<50 { if !human.isRunning { break }; try await Task.sleep(for: .milliseconds(20)) }
        if human.isRunning, human.processIdentifier > 1 { kill(human.processIdentifier, SIGKILL) }
        trace.emit("human.lifecycle", trial: id, .object(["phase": .string("shutdown"),
            "latencyMs": .number((ProcessInfo.processInfo.systemUptime-humanStopStart)*1000)]))
        let humanEvents = try TraceParser.parse(Data(contentsOf: humanLog))
        for event in humanEvents { trace.emit(event.kind, trial: id, event.payload, at: event.time) }
        let allowed = Set("human".unicodeScalars)
        let noAgentLeak = actual.unicodeScalars.allSatisfy { allowed.contains($0) }
        let noHumanLeak: Bool? = driver.observedAgentValues.isEmpty ? nil : driver.editableContaminationChecks.allSatisfy { $0 } && driver.observedAgentValues.allSatisfy { value in
            !value.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
        }
        let taskComplete = !driver.taskChecks.isEmpty && driver.taskChecks.values.allSatisfy { $0 } && driverError == nil
        let cleanup = !driver.cleanupResults.isEmpty && driver.cleanupResults.allSatisfy { $0 } && !human.isRunning
        let counts = instrumentation["eventCounts"]
        let hasEvents: Bool
        if case .object(let fields) = counts {
            let marker = ":\(Instrumentation.humanMarker)"
            hasEvents = fields.keys.contains { $0.hasPrefix("10:") && $0.hasSuffix(marker) }
                && fields.keys.contains { $0.hasPrefix("5:") && $0.hasSuffix(marker) }
        } else { hasEvents = false }
        var checks: [String: Bool?] = [
            "agent_task_completed": taskComplete, "human_text_exact": !expected.isEmpty && actual == expected,
            "no_agent_chars_in_human": noAgentLeak, "no_human_chars_in_agent": noHumanLeak,
            "frontmost_never_changed_by_agent": instrumentation["focusTheftEvents"].array.isEmpty,
            "no_untagged_pointer_events": instrumentation["tapReady"].bool == true && instrumentation["tapDisabled"].bool == false ? instrumentation["untaggedPointerEvents"].number.map { $0 == 0 } : nil,
            "cursor_exact_at_rest": (instrumentation["cursorRestChecks"].number ?? 0) > 0 ? instrumentation["cursorRestFailures"].number.map { $0 == 0 } : nil,
            "cleanup_ok": cleanup, "monitor_coverage": instrumentation["tapReady"].bool == true && instrumentation["tapDisabled"].bool == false && (instrumentation["sampleGapMaxMs"].number ?? .infinity) <= 100 && hasEvents,
            "real_human_concurrency": nil
        ]
        for (key, passed) in driver.taskChecks { checks[key] = passed }
        if scenario == "S10" {
            let switches = humanEvents.filter { $0.kind == "human.focus_request" }
            checks["human_window_focus_switched"] = switches.count >= 2 && switches.allSatisfy { $0.payload["keyWindowVerified"].bool == true }
        }
        if driver.unsupportedSteps.contains(where: { !$0.hasPrefix("stop-workspace:") }) {
            if ["S8", "S9", "S10"].contains(scenario) {
                let failedSupported = driverError != nil || driver.taskChecks.contains {
                    !driver.unavailableChecks.contains($0.key) && !$0.value
                }
                checks["agent_task_completed"] = failedSupported ? false : .some(nil)
            } else {
                checks["agent_task_completed"] = .some(nil)
                for key in driver.taskChecks.keys { checks[key] = .some(nil) }
            }
        }
        for key in driver.unavailableChecks { checks[key] = .some(nil) }
        if driver.unsupportedSteps.contains(where: { $0.hasPrefix("stop-workspace:") }) { checks["cleanup_ok"] = .some(nil) }
        if scenario == "S6" {checks["pid_pointer_not_in_global_stream"] = instrumentation["tapReady"].bool == true && instrumentation["pidPointerProbeGlobalEvents"].number == 0}
        let failures = checks.filter { $0.value == false }.map(\.key).sorted()
        let details: JSONValue = .object(["monitor": instrumentation,
            "expectedHumanCharacters": .number(Double(expected.count)), "actualHumanCharacters": .number(Double(actual.count)),
            "durationSeconds": .number(ProcessInfo.processInfo.systemUptime-start), "minimumHumanDurationSeconds": .number(minimumDuration),
            "concurrentAgentDurationSeconds": .number(agentDuration),
            "driverError": driverError.map(JSONValue.string) ?? .null, "agentValues": .array(driver.observedAgentValues.map(JSONValue.string)),
            "unsupportedSteps": .array(driver.unsupportedSteps.map(JSONValue.string))])
        let result = TrialResult(id: id, scenario: scenario, variant: variant, checks: checks, details: details, failures: failures)
        trace.emit("trial.result", trial: id, try .encoded(result))
        if let adapter { try await Task.detached { try adapter.finish(trace: self.trace, trial: id) }.value }
        return result
    }
}

@main
struct AgentSpaceEval {
    @MainActor static func main() async {
        do {
            if CommandLine.arguments.contains("--help") {
                print("agentspace-eval [--trials 5] [--duration 30] [--stress-ops 200] [--scenarios S1,S2,S3,S4,S5,S6,S7] [--output Evals/results]\nInstrumented HID simulation; steals focus once for HumanPad and moves/types in the GUI. S3 always runs at least 30 seconds. S7 exercises AgentSpace's own virtual-display backend (display host + CGVirtualDisplay + targeted input) and skips clearly when its prerequisites are missing. Do not use alongside a real human."); return
            }
            let configuration = try Configuration(Array(CommandLine.arguments.dropFirst()))
            try await EvaluationRunner(configuration: configuration).run()
        } catch {
            FileHandle.standardError.write(Data("agentspace-eval: \(error)\n".utf8)); exit(1)
        }
    }
}
