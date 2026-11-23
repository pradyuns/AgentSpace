import AppKit

@MainActor
enum FocusRestoration {
    static func restore(previous: Frontmost?, enabled: Bool) -> Bool {
        guard enabled, let previous, let app=NSRunningApplication(processIdentifier:previous.pid),
              app.bundleIdentifier==previous.bundleIdentifier, !app.isTerminated else {return false}
        // Explicit --restore-focus mitigation only: the sole activation exception restores the previous human app, never an agent target.
        return app.activate(options: [])
    }
}
