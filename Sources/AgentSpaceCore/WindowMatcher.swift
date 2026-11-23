import Foundation

struct CaptureCandidate: Sendable {
    var id: UInt32
    var title: String?
    var frame: WindowFrame
}

enum WindowMatcher {
    static func resolve(_ candidates:[CaptureCandidate], title:String, frame:WindowFrame?, previousID:UInt32?) throws -> UInt32 {
        if let previousID,candidates.contains(where:{$0.id==previousID}) {return previousID}
        let positioned=candidates.filter { candidate in
            guard let frame else {return candidate.title==title}
            return abs(candidate.frame.x-frame.x)<2 && abs(candidate.frame.y-frame.y)<2
                && abs(candidate.frame.width-frame.width)<2 && abs(candidate.frame.height-frame.height)<2
        }
        if positioned.count==1 {return positioned[0].id}
        let titled=positioned.filter{$0.title==title}
        if titled.count==1 {return titled[0].id}
        throw AgentSpaceError("capture_window_not_found","Cannot uniquely identify the targeted document window")
    }
}
