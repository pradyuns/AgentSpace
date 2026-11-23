import AppKit
import ApplicationServices
import Darwin
import AgentSpaceCore
import AgentSpaceEvalSupport

@MainActor
enum StartingStatePreparation {
    static let bundles = ["textedit": "com.apple.TextEdit", "chrome": "com.google.Chrome", "safari": "com.apple.Safari"]

    static func identity(_ pid: Int32) -> String? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 else { return nil }
        return "\(pid):\(info.pbi_start_tvsec):\(info.pbi_start_tvusec)"
    }

    static func live(_ pid: Int32, token: String) -> Bool {
        var info = proc_bsdinfo()
        return identity(pid) == token && proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            && info.pbi_status != SZOMB
    }

    static func apps(_ kind: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundles[kind] ?? "").filter { !$0.isTerminated }
    }

    static func identities(_ kind: String) -> Set<String> {
        Set(apps(kind).compactMap { identity($0.processIdentifier) })
    }

    static func snapshot(_ kinds: [String]) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: kinds.map { kind in
            (kind, .array(apps(kind).map { app in .object([
                "pid": .number(Double(app.processIdentifier)),
                "identity": identity(app.processIdentifier).map(JSONValue.string) ?? .null
            ]) }))
        }))
    }

    static func documentReady(_ kind: String, title: String) -> Bool {
        apps(kind).contains { app in
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXWindowsAttribute as CFString, &raw) == .success,
                  let windows = raw as? [AXUIElement] else { return false }
            return windows.contains { window in
                var value: CFTypeRef?
                return AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success
                    && (value as? String)?.contains(title) == true
            }
        }
    }

    static func prepare(_ mode: StartingState, kinds: [String], directory: URL, trace: TraceWriter, trial: String) async throws {
        guard mode != .inherited else { return }
        let resetKinds = bundles.keys.sorted()
        trace.emit("starting_state.begin", trial: trial, .object(["mode": .string(mode.rawValue), "apps": snapshot(resetKinds),
            "targetKinds": .array(kinds.map(JSONValue.string))]))
        let initial = resetKinds.flatMap { apps($0) }.compactMap { app -> (NSRunningApplication, String)? in
            guard let token = identity(app.processIdentifier) else { return nil }
            return (app, token)
        }
        guard initial.count == resetKinds.flatMap({ apps($0) }).count else {
            throw AgentSpaceError("starting_state_unavailable", "Cannot safely identify an existing target application")
        }
        for (app, _) in initial { app.terminate() }
        for attempt in 0..<100 {
            if resetKinds.allSatisfy({ apps($0).isEmpty }) && initial.allSatisfy({ !live($0.0.processIdentifier, token: $0.1) }) { break }
            if attempt == 30 {
                for (app, token) in initial where live(app.processIdentifier, token: token) {
                    app.forceTerminate()
                    if live(app.processIdentifier, token: token) { kill(app.processIdentifier, SIGKILL) }
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard initial.allSatisfy({ !live($0.0.processIdentifier, token: $0.1) }) else {
            throw AgentSpaceError("starting_state_unavailable", "Target application main process remains kernel-live")
        }
        try StartingState.cold.validate(kinds: resetKinds, processes: Dictionary(uniqueKeysWithValues: resetKinds.map { ($0, apps($0).count) }), documents: [])
        let title = "AgentSpace starting state"
        if mode == .warm {
            let text = directory.appendingPathComponent(title+".txt")
            let html = directory.appendingPathComponent("starting-state.html")
            try "Warm fixture document\n".write(to: text, atomically: true, encoding: .utf8)
            try "<!doctype html><title>\(title)</title><p>Warm fixture document</p>".write(to: html, atomically: true, encoding: .utf8)
            for kind in kinds {
                guard let bundle = bundles[kind], let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                    throw AgentSpaceError("starting_state_unavailable", "Missing target application \(kind)")
                }
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
                _ = try await NSWorkspace.shared.open([kind == "textedit" ? text : html], withApplicationAt: url, configuration: configuration)
            }
            for _ in 0..<100 {
                if kinds.allSatisfy({ documentReady($0, title: title) }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let documents = Set(kinds.filter { documentReady($0, title: title) })
        try mode.validate(kinds: kinds, processes: Dictionary(uniqueKeysWithValues: kinds.map { ($0, apps($0).count) }), documents: documents)
        trace.emit("starting_state.ready", trial: trial, .object(["mode": .string(mode.rawValue), "apps": snapshot(kinds),
            "documentKinds": .array(documents.sorted().map(JSONValue.string)), "verified": .bool(true)]))
    }
}
