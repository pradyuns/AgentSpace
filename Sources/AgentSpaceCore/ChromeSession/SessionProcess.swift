import Foundation

public enum SessionProcess {
    public static func isDead(_ identity: ProcessIdentity, probe: DisplayHost.Probe = .system) -> Bool {
        guard identity.pid > 1, identity.start.isFinite, identity.start > 0 else { return false }
        if let current = probe.startTime(identity.pid) { return abs(current - identity.start) >= 0.001 }
        return probe.signal(identity.pid, 0) != 0 && errno == ESRCH
    }

    public static func stop(_ identity: ProcessIdentity, probe: DisplayHost.Probe = .system) async -> Bool {
        if isDead(identity, probe: probe) { return true }
        _ = DisplayHost.terminate(identity.pid, start: identity.start, signal: SIGTERM, probe: probe)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !isDead(identity, probe: probe), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if DisplayHost.alive(identity.pid, start: identity.start, probe: probe) {
            _ = DisplayHost.terminate(identity.pid, start: identity.start, signal: SIGKILL, probe: probe)
            try? await Task.sleep(for: .milliseconds(200))
        }
        return isDead(identity, probe: probe)
    }
}

extension JSONValue {
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}
