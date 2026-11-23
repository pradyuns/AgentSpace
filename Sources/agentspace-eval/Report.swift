import Foundation
import AgentSpaceCore
import AgentSpaceEvalSupport

enum Report {
    static func write(results: [TrialResult], events: [TraceEvent], configuration: JSONValue, root: URL) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let groups = Dictionary(grouping: results) { "\($0.scenario)|\($0.variant)" }
        var aggregates: [JSONValue] = []
        var markdown = "# AgentSpace isolation evaluation\n\n"
        markdown += "Instrumented simulation only. **Real-human concurrency: UNTESTED.**\n\n"
        markdown += "Each cell is a binary assertion, not a quality score. Missing observations are UNTESTED. Wilson intervals use observed trials only; incomplete groups cannot PASS. Trial unit is the entire workflow, not individual actions.\n\n"
        markdown += "Configuration: `\(String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self))`\n\n"
        markdown += "| Scenario | Variant | Trials | Check | Pass rate | Wilson 95% CI | Status |\n|---|---|---:|---|---:|---|---|\n"
        for key in groups.keys.sorted() {
            let trials = groups[key]!
            let checks = Set(trials.flatMap { $0.checks.keys }).sorted()
            for check in checks {
                let values: [Bool?] = trials.map { $0.checks[check] ?? nil }
                let tested = values.compactMap { $0 }, passed = tested.filter { $0 }.count
                let interval = Evaluation.wilson(passed: passed, total: tested.count)
                let rate = tested.isEmpty ? "—" : String(format: "%.1f%% (%d/%d)", Double(passed)/Double(tested.count)*100, passed, tested.count)
                let ci = interval.map { String(format: "[%.1f%%, %.1f%%]", $0.lower*100, $0.upper*100) } ?? "—"
                let status = Evaluation.status(values)
                markdown += "| \(trials[0].scenario) | \(trials[0].variant) | \(trials.count) | \(check) | \(rate) | \(ci) | \(status) |\n"
                aggregates.append(.object(["scenario": .string(trials[0].scenario), "variant": .string(trials[0].variant),
                    "check": .string(check), "trials": .number(Double(trials.count)), "tested": .number(Double(tested.count)),
                    "passed": .number(Double(passed)), "status": .string(status), "wilson95": try interval.map(JSONValue.encoded) ?? .null]))
            }
        }
        let completed = results.filter { $0.checks["agent_task_completed"] == true }.count
        let attempted = results.filter { $0.checks["agent_task_completed"] != nil }.count
        markdown += "**Completed tasks:** \(completed)/\(results.count) trials (\(attempted) attempted; the rest were UNTESTED)\n\n"
        markdown += "\n## Action latency\n\nWall time includes worker startup/JSON transfer. Screenshot capture latency excludes PNG encoding. Failed actions are included and separated by outcome. *Cold start* is the first agent action of each trial (process spawn plus any backend startup); *warm* is every later action.\n\n| Action / method / outcome | Samples | p50 ms | p95 ms |\n|---|---:|---:|---:|\n"
        let actions = events.filter { $0.kind == "agent.action" }
        let firstPerTrial = Set(Dictionary(grouping: actions) { $0.trial }
            .compactMap { $0.value.min(by: { $0.time < $1.time })?.sequence })
        let cold = actions.filter { firstPerTrial.contains($0.sequence) }.compactMap { $0.payload["latencyMs"].number }
        let warm = actions.filter { !firstPerTrial.contains($0.sequence) }.compactMap { $0.payload["latencyMs"].number }
        markdown += row("Cold start — first action per trial", cold, unit: 1)
        markdown += row("Warm — all later actions", warm, unit: 1)
        let actionGroups = Dictionary(grouping: actions) { event in
            "\(event.payload["command"].string ?? "?") / \(event.payload["output"]["method"].string ?? "none") / \(event.payload["output"]["ok"].bool == true ? "ok" : "error")"
        }
        var latency: [JSONValue] = []
        latency.append(.object(["actionMethodOutcome": .string("cold-start/first-action-per-trial"), "samples": .number(Double(cold.count)),
            "p50Ms": Evaluation.percentile(cold, 0.5).map(JSONValue.number) ?? .null,
            "p95Ms": Evaluation.percentile(cold, 0.95).map(JSONValue.number) ?? .null]))
        latency.append(.object(["actionMethodOutcome": .string("warm/later-actions"), "samples": .number(Double(warm.count)),
            "p50Ms": Evaluation.percentile(warm, 0.5).map(JSONValue.number) ?? .null,
            "p95Ms": Evaluation.percentile(warm, 0.95).map(JSONValue.number) ?? .null]))
        for key in actionGroups.keys.sorted() {
            let values = actionGroups[key]!.compactMap { $0.payload["latencyMs"].number }
            markdown += row(key, values, unit: 1)
            latency.append(.object(["actionMethodOutcome": .string(key), "samples": .number(Double(values.count)),
                "p50Ms": Evaluation.percentile(values, 0.5).map(JSONValue.number) ?? .null,
                "p95Ms": Evaluation.percentile(values, 0.95).map(JSONValue.number) ?? .null]))
        }
        let captures = actions.compactMap { $0.payload["output"]["result"]["screenshot"]["latencyMs"].number }
        markdown += row("ScreenCaptureKit capture only", captures, unit: 1)
        let startups = events.filter { $0.kind == "benchmark.startup" }.compactMap { $0.payload["latencyMs"].number }
        if !startups.isEmpty { markdown += row("Benchmark create/launch/observe-ready attempt", startups, unit: 1) }
        for phase in ["startup", "shutdown"] {
            let values = events.filter { $0.kind == "human.lifecycle" && $0.payload["phase"].string == phase }.compactMap { $0.payload["latencyMs"].number }
            markdown += row("HumanPad \(phase)", values, unit: 1)
        }
        markdown += "\n## Resources\n\nCPU is sampled process task CPU / elapsed wall time, where 100% is one core. RSS is sampled resident bytes. Short-lived workers may have RSS but no CPU delta; missing deltas are not zero. Target-app samples include browser main processes, not aggregate renderer/helper trees.\n\n| Role | RSS samples | RSS p50 MiB | RSS p95 MiB | CPU samples | CPU p50 % | CPU p95 % |\n|---|---:|---:|---:|---:|---:|---:|\n"
        let resources = Dictionary(grouping: events.filter { $0.kind == "resource.sample" }) { $0.payload["role"].string ?? "?" }
        var resourceSummary: [JSONValue] = []
        for role in resources.keys.sorted() {
            let rss = resources[role]!.compactMap { $0.payload["rssBytes"].number }
            let cpu = resources[role]!.compactMap { $0.payload["cpuPercent"].number }
            markdown += "| \(role) | \(rss.count) | \(format(Evaluation.percentile(rss, 0.5), scale: 1/1048576)) | \(format(Evaluation.percentile(rss, 0.95), scale: 1/1048576)) | \(cpu.count) | \(format(Evaluation.percentile(cpu, 0.5))) | \(format(Evaluation.percentile(cpu, 0.95))) |\n"
            resourceSummary.append(.object(["role": .string(role), "rssSamples": .number(Double(rss.count)), "cpuSamples": .number(Double(cpu.count)),
                "rssP95Bytes": Evaluation.percentile(rss, 0.95).map(JSONValue.number) ?? .null,
                "cpuP95Percent": Evaluation.percentile(cpu, 0.95).map(JSONValue.number) ?? .null]))
        }
        // True aggregate: helper + target + agent processes summed per sample
        // instant (events share an `at` timestamp per monitor tick) - the
        // workspace's total footprint, not a sum of independent percentiles.
        let agentRoles: Set<String> = ["agent", "display-host", "mcp-server"]
        let byInstant = Dictionary(grouping: events.filter {
            $0.kind == "resource.sample" && (agentRoles.contains($0.payload["role"].string ?? "") || ($0.payload["role"].string ?? "").hasPrefix("target-"))
        }) { "\($0.trial)|\($0.time)" }
        let instants = byInstant.values.filter { $0.contains { agentRoles.contains($0.payload["role"].string ?? "") } }
        let totalRSS = instants.map { $0.compactMap { $0.payload["rssBytes"].number }.reduce(0, +) }
        let totalCPU = instants.map { $0.compactMap { $0.payload["cpuPercent"].number }.reduce(0, +) }
        markdown += "| **aggregate agent-side (helpers+targets+workers)** | \(totalRSS.count) | \(format(Evaluation.percentile(totalRSS, 0.5), scale: 1/1048576)) | \(format(Evaluation.percentile(totalRSS, 0.95), scale: 1/1048576)) | \(totalCPU.count) | \(format(Evaluation.percentile(totalCPU, 0.5))) | \(format(Evaluation.percentile(totalCPU, 0.95))) |\n"
        resourceSummary.append(.object(["role": .string("aggregate-agent-side"), "rssSamples": .number(Double(totalRSS.count)), "cpuSamples": .number(Double(totalCPU.count)),
            "rssP95Bytes": Evaluation.percentile(totalRSS, 0.95).map(JSONValue.number) ?? .null,
            "cpuP95Percent": Evaluation.percentile(totalCPU, 0.95).map(JSONValue.number) ?? .null]))
        markdown += "\n## Trial diagnostics\n\nPrimary pointer checks require no untagged global pointer events and exact cursor position after each 150 ms segment pause. The old raw/±40 ms timing-adjusted deviations below are diagnostics only, never pass/fail assertions. The monitor runs at userInteractive QoS. Focus restoration does not erase theft. Listen-only tap coverage must be available and uninterrupted.\n\n| Trial | Human chars expected / observed | Raw / adjusted max cursor px (diagnostic) | Monitor p95 / max gap ms | Failed assertions |\n|---|---|---|---|---|\n"
        for result in results {
            let detail = result.details, monitor = detail["monitor"]
            let failed = result.failures.joined(separator: ", ")
            markdown += "| \(result.id) | \(Int(detail["expectedHumanCharacters"].number ?? 0)) / \(Int(detail["actualHumanCharacters"].number ?? 0)) | \(format(monitor["maxCursorDeviationRawPx"].number)) / \(format(monitor["maxCursorDeviationTimingAdjustedPx"].number)) | \(format(monitor["sampleGapP95Ms"].number)) / \(format(monitor["sampleGapMaxMs"].number)) | \(failed.isEmpty ? "none" : failed) |\n"
        }
        markdown += "\n## Failure analysis\n\n`failure-analysis.md` contains the taxonomy written after reading this run's traces. This report deliberately does not infer causes from assertion names. Full agent responses, monitor samples, tagged HID requests, listen-only tap metadata, and HumanPad keyDown/text records are retained in `traces.jsonl`; per-trial state/action logs, final text, and screenshots are retained in trial directories.\n"
        let costs = Dictionary(grouping: events.filter { $0.kind == "benchmark.cost" }) { $0.trial }
        var processCosts: [JSONValue] = []
        markdown += "\n## Sampled process-tree costs\n\nLower bounds at 100 ms sampling, not exact total CPU or true peak RSS. Includes discovered descendants and registered targets/helpers; excludes HumanPad. Supply pre-existing daemon PIDs with `AGENTSPACE_COST_PIDS`. Short-lived children and CPU after a process's last sample may be missed. Startup-ready attempts and their readiness outcomes are in `benchmark.startup` traces.\n\n| Trial | Sampled CPU seconds | Sampled peak RSS MiB | Processes seen |\n|---|---:|---:|---:|\n"
        for trial in costs.keys.sorted() {
            guard let last = costs[trial]?.max(by: { $0.time < $1.time }) else { continue }
            let payload = last.payload
            markdown += "| \(trial) | \(format(payload["sampledCPUSeconds"].number)) | \(format(payload["sampledPeakRSSBytes"].number, scale: 1/1048576)) | \(Int(payload["processesSeen"].number ?? 0)) |\n"
            processCosts.append(.object(["trial": .string(trial), "cost": payload]))
        }
        let summary: JSONValue = .object(["configuration": configuration, "realHumanConcurrency": .string("UNTESTED"),
            "trials": try .encoded(results), "checks": .array(aggregates), "latency": .array(latency),
            "resources": .array(resourceSummary), "processCosts": .array(processCosts)])
        try encoder.encode(summary).write(to: root.appendingPathComponent("summary.json"), options: .atomic)
        try markdown.write(to: root.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        return markdown
    }
    private static func format(_ value: Double?, scale: Double = 1) -> String {
        value.map { String(format: "%.2f", $0*scale) } ?? "—"
    }
    private static func row(_ key: String, _ values: [Double], unit: Double) -> String {
        "| \(key) | \(values.count) | \(format(Evaluation.percentile(values, 0.5), scale: unit)) | \(format(Evaluation.percentile(values, 0.95), scale: unit)) |\n"
    }
}
