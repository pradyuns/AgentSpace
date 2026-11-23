import Foundation
import CoreGraphics
import AgentSpaceCore

public extension JSONValue {
    subscript(_ key: String) -> JSONValue {
        if case .object(let fields) = self { return fields[key] ?? .null }
        return .null
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
}

public struct Interval: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double
}

public enum Evaluation {
    public static func untaggedPointer(type: UInt32, marker: Int64, humanMarker: Int64) -> Bool {
        let pointer: Set<CGEventType> = [.mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        return CGEventType(rawValue: type).map { pointer.contains($0) && marker != humanMarker } ?? false
    }
    public static func wilson(passed: Int, total: Int) -> Interval? {
        guard total > 0, passed >= 0, passed <= total else { return nil }
        let z = 1.959963984540054, n = Double(total), p = Double(passed) / n
        let denominator = 1 + z*z/n
        let center = (p + z*z/(2*n)) / denominator
        let radius = z * sqrt(p*(1-p)/n + z*z/(4*n*n)) / denominator
        return Interval(lower: max(0, center-radius), upper: min(1, center+radius))
    }

    public static func status(_ checks: [Bool?]) -> String {
        let observed = checks.compactMap { $0 }
        guard !observed.isEmpty else { return "UNTESTED" }
        if observed.allSatisfy({ $0 }) && observed.count == checks.count { return "PASS" }
        if observed.allSatisfy({ !$0 }) { return "FAIL" }
        return "PARTIAL"
    }

    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty, (0...1).contains(p), values.allSatisfy(\.isFinite) else { return nil }
        let sorted = values.sorted()
        return sorted[max(0, Int(ceil(p * Double(sorted.count))) - 1)]
    }

    public static func deviation(samples: [PointSample], path: [PointSample], tolerance: Double) -> (raw: Double, adjusted: Double)? {
        guard tolerance >= 0, !path.isEmpty else { return nil }
        let path = path.sorted { $0.time < $1.time }
        var raw = 0.0, adjusted = 0.0, index = 0, count = 0
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            guard sample.time >= path[0].time else { continue }
            while index+1 < path.count && path[index+1].time <= sample.time { index += 1 }
            func distance(_ point: PointSample) -> Double { hypot(sample.x-point.x, sample.y-point.y) }
            raw = max(raw, distance(path[index]))
            var best = distance(path[index]), j = index
            while j > 0 && path[j].time >= sample.time-tolerance {
                j -= 1; best = min(best, distance(path[j]))
            }
            j = index+1
            while j < path.count && path[j].time <= sample.time+tolerance {
                best = min(best, distance(path[j])); j += 1
            }
            adjusted = max(adjusted, best); count += 1
        }
        return count > 0 ? (raw, adjusted) : nil
    }
}

public struct PointSample: Codable, Equatable, Sendable {
    public let time: Double
    public let x: Double
    public let y: Double
    public init(time: Double, x: Double, y: Double) { self.time=time; self.x=x; self.y=y }
}

public struct TraceEvent: Codable, Sendable {
    public let sequence: Int
    public let time: Double
    public let trial: String
    public let kind: String
    public let payload: JSONValue
    public init(sequence: Int, time: Double, trial: String, kind: String, payload: JSONValue) {
        self.sequence=sequence; self.time=time; self.trial=trial; self.kind=kind; self.payload=payload
    }
}

public enum TraceParser {
    public static func parse(_ data: Data) throws -> [TraceEvent] {
        try data.split(separator: 10).enumerated().map { index, line in
            do { return try JSONDecoder().decode(TraceEvent.self, from: Data(line)) }
            catch { throw AgentSpaceError("invalid_trace", "Invalid JSONL line \(index+1): \(error)") }
        }
    }
}

public final class TraceWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let writer = DispatchQueue(label: "AgentSpace trace writer", qos: .utility)
    private let bufferLimit: Int
    private var pending = 0
    private var sequence = 0
    private var failure: String?
    public convenience init(url: URL) throws {
        try self.init(url: url, bufferLimit: 16_384)
    }
    init(url: URL, bufferLimit: Int) throws {
        self.bufferLimit = bufferLimit
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw AgentSpaceError("trace_create_failed", "Cannot create trace file")
        }
        handle = try FileHandle(forWritingTo: url)
    }
    public func emit(_ kind: String, trial: String, _ payload: JSONValue, at time: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard pending < bufferLimit else {
            failure = failure ?? "Trace writer backlog limit exceeded"
            return
        }
        sequence += 1
        pending += 1
        let event = TraceEvent(sequence: sequence, time: time, trial: trial, kind: kind, payload: payload)
        writer.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            do {
                var data = try JSONEncoder().encode(event)
                data.append(10); try handle.write(contentsOf: data)
            } catch { lock.withLock { failure = failure ?? String(describing: error) } }
        }
    }
    public func synchronize() throws {
        try writer.sync {
            if let failure = lock.withLock({ failure }) { throw AgentSpaceError("trace_write_failed", failure) }
            try handle.synchronize()
        }
    }
    deinit { try? handle.close() }
}

public struct TrialResult: Codable, Sendable {
    public var id: String
    public var scenario: String
    public var variant: String
    public var checks: [String: Bool?]
    public var details: JSONValue
    public var failures: [String]
    public init(id: String, scenario: String, variant: String, checks: [String: Bool?], details: JSONValue, failures: [String]) {
        self.id=id; self.scenario=scenario; self.variant=variant; self.checks=checks; self.details=details; self.failures=failures
    }
}
