import Foundation
import AgentSpaceCore

public enum StartingState: String, Sendable {
    case inherited, cold, warm

    public static func kinds(scenario: String, variant: String) -> [String] {
        switch scenario {
        case "S1", "S5": return ["textedit"]
        case "S3": return ["textedit", "chrome"]
        case "S2": return [variant == "safari-range-insertion" ? "safari" : "chrome"]
        case "S4": return ["chrome"]
        default: return []
        }
    }

    public func validate(kinds: [String], processes: [String: Int], documents: Set<String>) throws {
        for kind in kinds {
            if self == .cold, processes[kind, default: 0] != 0 {
                throw AgentSpaceError("starting_state_unavailable", "Cold starting state requires every \(kind) application process to quit")
            }
            if self == .warm, processes[kind, default: 0] == 0 || !documents.contains(kind) {
                throw AgentSpaceError("starting_state_unavailable", "Warm starting state requires \(kind) running with its fixture document window")
            }
        }
    }

    public static func behavior(reported: String?, before: Set<String>, after: Set<String>) -> String {
        guard let reported, after.contains(reported) else { return "unverified" }
        return before.contains(reported) ? "reused" : "launched"
    }
}
