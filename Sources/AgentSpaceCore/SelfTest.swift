import AppKit
import ApplicationServices
import ASDisplayShim
import Foundation

/// `agentspace self-test`: verifies routing decisions, option validation and
/// backend prerequisites without creating workspaces, displays or processes.
/// The virtual-display section is a strictly read-only probe: it reports
/// whether AgentSpace's own display host binary is built next to `agentspace`
/// and whether the runtime-discovered CGVirtualDisplay APIs are usable on this
/// macOS - it never spawns the host and never creates a display.
@MainActor
public enum SelfTest {
    public struct Check: Codable, Sendable {
        public var name: String
        public var ok: Bool
        public var required: Bool
        public var detail: String
    }

    /// Read-only availability of the private CGVirtualDisplay class cluster on
    /// this OS, described precisely - a missing class, descriptor or settings
    /// selector each produce a different string.
    public nonisolated static func virtualDisplayAPIStatus() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let detail = { String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        guard ASVDProbe(&buffer, buffer.count) != 0 else {
            return "unavailable: \(detail())"
        }
        return "available: \(detail())"
    }

    public nonisolated static func virtualDisplayAPIAvailable() -> Bool {
        ASVDProbe(nil, 0) != 0
    }

    public static func run() async throws -> JSONValue {
        var checks: [Check] = []
        var routing: [JSONValue] = []
        // Each case asserts the expected resolved backend AND interaction, not just "no error":
        // a silently wrong route is the failure this check exists to catch.
        func probe(_ label: String, expect backend: String, _ mode: String,
                   _ make: () throws -> RoutingDecision) {
            do {
                let decision = try make()
                let ok = decision.resolvedBackend == backend && decision.resolvedInteraction == mode
                routing.append(.object(["case": .string(label),
                    "expected": .string("\(backend)/\(mode)"),
                    "resolved": .string("\(decision.resolvedBackend)/\(decision.resolvedInteraction)"),
                    "ok": .bool(ok),
                    "error": ok ? .null : .string("resolved \(decision.resolvedBackend)/\(decision.resolvedInteraction)")]))
            } catch {
                routing.append(.object(["case": .string(label), "expected": .string("\(backend)/\(mode)"),
                                        "ok": .bool(false), "error": .string(String(describing: error))]))
            }
        }
        probe("auto+chrome+semantic", expect: "cdp", "semantic") { try BackendRouter.resolve(request: .init(), app: "chrome") }
        probe("auto+textedit+semantic", expect: "ax", "semantic") { try BackendRouter.resolve(request: .init(), app: "textedit") }
        probe("auto+chrome+visual", expect: "virtual-display", "visual") { try BackendRouter.resolve(request: .init(interaction: "visual"), app: "chrome") }
        probe("ax+textedit", expect: "ax", "semantic") { try BackendRouter.resolve(request: .init(backend: "ax"), app: "com.apple.TextEdit") }
        probe("cdp+chrome", expect: "cdp", "semantic") { try BackendRouter.resolve(request: .init(backend: "cdp"), app: "chrome") }
        probe("virtual-display+textedit", expect: "virtual-display", "visual") { try BackendRouter.resolve(request: .init(backend: "virtual-display"), app: "com.apple.TextEdit") }
        // Invalid combinations must be rejected, not silently downgraded.
        func probeRejects(_ label: String, _ make: () throws -> RoutingDecision) {
            do {
                _ = try make()
                routing.append(.object(["case": .string(label), "ok": .bool(false),
                                        "error": .string("expected rejection but a decision was returned")]))
            } catch {
                routing.append(.object(["case": .string(label), "ok": .bool(true),
                                        "rejected": .string(String(describing: error))]))
            }
        }
        probeRejects("cdp+textedit") { try BackendRouter.resolve(request: .init(backend: "cdp"), app: "textedit") }
        probeRejects("ax+visual") { try BackendRouter.resolve(request: .init(backend: "ax", interaction: "visual"), app: "textedit") }
        probeRejects("cdp+visual") { try BackendRouter.resolve(request: .init(backend: "cdp", interaction: "visual"), app: "chrome") }
        let routingOK = routing.allSatisfy { value in
            if case .object(let object) = value { return object["ok"] == .bool(true) }
            return false
        }
        checks.append(Check(name: "routing", ok: routingOK, required: true,
                            detail: "auto resolves chrome→cdp, native→ax, visual→virtual-display; invalid combinations are rejected"))
        func optionsOK(_ label: String, _ options: CommandOptions, _ exercise: (CommandOptions) throws -> Bool) -> Check {
            do { return Check(name: label, ok: try exercise(options), required: true, detail: "accepted") }
            catch { return Check(name: label, ok: false, required: true, detail: String(describing: error)) }
        }
        checks.append(optionsOK("options.point", CommandOptions(values: ["x": "10.5", "y": "4"])) {
            (try $0.point()).map { $0.x == 10.5 && $0.y == 4 } ?? false
        })
        do {
            _ = try CommandOptions(values: ["x": "-5", "y": "4"]).point()
            checks.append(Check(name: "options.pointReject", ok: false, required: true, detail: "out-of-range coordinate was accepted"))
        } catch {
            checks.append(Check(name: "options.pointReject", ok: true, required: true, detail: "rejected before any effect"))
        }
        checks.append(optionsOK("options.modifiers", CommandOptions(values: ["modifiers": "cmd,shift"])) {
            (try $0.modifierList()) == ["cmd", "shift"]
        })
        // AgentSpace's own virtual-display prerequisites: the display-host
        // binary built by `swift build`, and the runtime-discovered
        // CGVirtualDisplay classes on this OS. Both are reported, never probed
        // with side effects - no host is spawned and no display created.
        let executable = DisplayHost.locate()
        let apiStatus = virtualDisplayAPIStatus()
        var virtual: [String: JSONValue] = [
            "executable": executable.map { .string($0.path) } ?? .null,
            "api": .string(apiStatus),
        ]
        checks.append(Check(name: "virtualDisplayHost", ok: executable != nil, required: false,
                            detail: executable != nil
                                ? "agentspace-display-host found at \(executable!.path)"
                                : "agentspace-display-host not found next to agentspace; run `swift build`"))
        checks.append(Check(name: "virtualDisplayAPI", ok: virtualDisplayAPIAvailable(), required: false,
                            detail: apiStatus))
        virtual["note"] = .string("read-only; no host was spawned and no display was created")
        checks.append(Check(name: "accessibility", ok: AXIsProcessTrusted(), required: false,
                            detail: AXIsProcessTrusted() ? "granted" : "not granted to the host process; needed for --backend ax and virtual-display"))
        let chromeInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
        checks.append(Check(name: "cdp", ok: chromeInstalled, required: false,
                            detail: chromeInstalled
                                ? "Google Chrome installed; the cdp backend can launch its headless instance"
                                : "Google Chrome not installed; --backend cdp cannot launch"))
        let requiredFailures = checks.filter { $0.required && !$0.ok }
        return .object([
            "ok": .bool(requiredFailures.isEmpty),
            "checks": try .encoded(checks),
            "routing": .array(routing),
            "virtualDisplay": .object(virtual),
            "note": .string("read-only; no workspace, session or display was created"),
        ])
    }
}
