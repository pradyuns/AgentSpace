import ApplicationServices
import Foundation

@MainActor
enum TargetedKeyboard {
    static func text(_ text: String, pid: pid_t) async throws {
        guard text.utf16.count <= 100_000 else {throw AgentSpaceError("text_too_large","Text is limited to 100000 UTF-16 units")}
        // One extended grapheme per pair keeps surrogate pairs intact and avoids large event payloads.
        for character in text {
            let units=Array(String(character).utf16)
            guard units.count <= 20 else {throw AgentSpaceError("text_chunk_too_large","A grapheme exceeds the 20 UTF-16 unit event limit")}
            for down in [true,false] {
                guard let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down) else {throw AgentSpaceError("event_creation","Cannot create keyboard event")}
                units.withUnsafeBufferPointer {event.keyboardSetUnicodeString(stringLength:units.count,unicodeString:$0.baseAddress!)}
                event.postToPid(pid)
            }
            try await Task.sleep(for:.milliseconds(8))
        }
    }
    static func key(_ key: String, pid: pid_t) throws {
        let parts=key.lowercased().split(separator:"+").map(String.init)
        guard let last=parts.last else {throw AgentSpaceError("invalid_key","Empty key")}
        let codes:[String:CGKeyCode] = ["return":36,"enter":36,"tab":48,"backspace":51,"delete":51,"escape":53,
            "left":123,"right":124,"down":125,"up":126,"space":49,
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
            "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46]
        guard let code=codes[last] else {throw AgentSpaceError("invalid_key","Unsupported key '\(last)'")}
        var flags=CGEventFlags()
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd","command":flags.insert(.maskCommand)
            case "shift":flags.insert(.maskShift)
            case "alt","option":flags.insert(.maskAlternate)
            case "ctrl","control":flags.insert(.maskControl)
            default:throw AgentSpaceError("invalid_key","Unsupported modifier '\(modifier)'")
            }
        }
        for down in [true,false] {
            guard let event=CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:down) else {throw AgentSpaceError("event_creation","Cannot create keyboard event")}
            event.flags=flags;event.postToPid(pid)
        }
    }
}
