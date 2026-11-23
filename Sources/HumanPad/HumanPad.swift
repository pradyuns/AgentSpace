import AppKit
import AgentSpaceCore
import AgentSpaceEvalSupport

@MainActor
final class HumanTextView: NSTextView {
    var writer: TraceWriter?
    var stateURL: URL?
    override func keyDown(with event: NSEvent) {
        let before = string
        super.keyDown(with: event)
        writer?.emit("human.keyDown", trial: "human", .object([
            "characters": .string(event.characters ?? ""), "keyCode": .number(Double(event.keyCode)),
            "sourcePID": .number(Double(event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1)),
            "sourceState": .number(Double(event.cgEvent?.getIntegerValueField(.eventSourceStateID) ?? -1)),
            "userData": .number(Double(event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0)),
            "flags": .number(Double(event.modifierFlags.rawValue)), "repeat": .bool(event.isARepeat),
            "before": .string(before), "text": .string(string)
        ]))
        persist()
    }
    func persist() {
        guard let stateURL else { return }
        do {
            try string.write(to: stateURL, atomically: true, encoding: .utf8)
        } catch {
            writer?.emit("human.write_error", trial: "human", .string(String(describing: error)))
        }
    }
}

@MainActor
final class HumanPadDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var view: HumanTextView?
    var writer: TraceWriter?
    var alternateWindow: NSWindow?
    var focusTimer: Timer?
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = CommandLine.arguments
            func option(_ name: String) throws -> String {
                guard let i = args.firstIndex(of: name), i+1 < args.count else {
                    throw AgentSpaceError("missing_argument", "HumanPad needs --log, --text, --ready")
                }
                return args[i+1]
            }
            writer = try TraceWriter(url: URL(fileURLWithPath: option("--log")))
            if args.contains("--no-window") {
                let ready: JSONValue = .object(["pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "windowless": .bool(true)])
                try JSONEncoder().encode(ready).write(to: URL(fileURLWithPath: option("--ready")), options: .atomic)
                writer?.emit("fixture.windowless_ready", trial: "fixture", ready)
                return
            }
            let window = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 640, height: 440),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "HumanPad — instrumented human simulation"
            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = HumanTextView(frame: scroll.bounds)
            text.isRichText = false; text.isAutomaticQuoteSubstitutionEnabled = false
            text.isAutomaticDashSubstitutionEnabled = false; text.isAutomaticTextReplacementEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false; text.isContinuousSpellCheckingEnabled = false
            text.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
            text.autoresizingMask = [.width, .height]
            text.writer = writer; text.stateURL = URL(fileURLWithPath: try option("--text"))
            scroll.documentView = text; window.contentView?.addSubview(scroll)
            self.window = window; view = text
            window.makeKeyAndOrderFront(nil); window.makeFirstResponder(text)
            NSApplication.shared.activate(ignoringOtherApps: true)
            if args.contains("--switch-focus") {
                let alternate = NSWindow(contentRect: NSRect(x: 100, y: 140, width: 640, height: 440),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                alternate.title = "HumanPad — second human window"
                alternateWindow = alternate
                focusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let first = self.window, let second = self.alternateWindow,
                              let view = self.view, let scroll = view.enclosingScrollView else { return }
                        let target = first.isKeyWindow ? second : first
                        scroll.removeFromSuperview()
                        scroll.frame = target.contentView!.bounds
                        target.contentView?.addSubview(scroll)
                        target.makeKeyAndOrderFront(nil); target.makeFirstResponder(view)
                        self.writer?.emit("human.focus_request", trial: "human", .object([
                            "window": .string(target.title), "keyWindowVerified": .bool(target.isKeyWindow)]))
                    }
                }
            }
            text.persist()
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            let rect = window.convertToScreen(window.contentView!.bounds)
            let ready: JSONValue = .object(["pid": .number(Double(ProcessInfo.processInfo.processIdentifier)),
                "x": .number(rect.minX), "y": .number(screenHeight-rect.maxY),
                "width": .number(rect.width), "height": .number(rect.height)])
            try JSONEncoder().encode(ready).write(to: URL(fileURLWithPath: option("--ready")), options: .atomic)
            writer?.emit("human.ready", trial: "human", ready)
        } catch {
            FileHandle.standardError.write(Data("HumanPad: \(error)\n".utf8)); NSApplication.shared.terminate(nil)
        }
    }
    func applicationWillTerminate(_ notification: Notification) { view?.persist(); try? writer?.synchronize() }
}

@main
struct HumanPad {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = HumanPadDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
