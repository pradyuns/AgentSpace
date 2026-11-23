import AppKit
import ApplicationServices
import Darwin
import AgentSpaceCore
import AgentSpaceEvalSupport

final class Instrumentation: @unchecked Sendable {
    static let humanMarker: Int64 = 0x48554d414e
    let trace: TraceWriter
    let trial: String
    let humanPID: Int32
    private let lock = NSLock()
    private var running = true
    private var active = false
    private var tapReady = false
    private var tapDisabled = false
    private var paths: [PointSample] = []
    private var samples: [PointSample] = []
    private var focusViolations: [JSONValue] = []
    private var tapCounts: [String: Int] = [:]
    private var untaggedPointerEvents = 0
    private var restChecks = 0
    private var pointerDelivery: PointSample?
    private var restFailures = 0
    private var pidPointerProbeEvents = 0
    private var targets: [Int32: String] = [:]
    private var resourcePrevious: [Int32: (Double, Double)] = [:]
    private var costKnown: Set<Int32> = []
    private var costFirst: [Int32: Double] = [:]
    private var costLast: [Int32: Double] = [:]
    private var costPeakRSS = 0.0
    private let costStart = Date().timeIntervalSince1970
    private var thread: Thread?
    private var done = DispatchSemaphore(value: 0)
    private var observer: NSObjectProtocol?
    private let samplerDone = DispatchSemaphore(value: 0)
    private let resourcesDone = DispatchSemaphore(value: 0)
    private var stageMaxMs: [String: Double] = [:]
    private var tapCallbackMaxMs = 0.0
    private var tapRunLoopMaxMs = 0.0
    private var resourceMaxMs = 0.0
    private let heartbeat = SamplingHeartbeat()
    var costMonitor: Instrumentation?

    init(trace: TraceWriter, trial: String, humanPID: Int32) {
        self.trace=trace; self.trial=trial; self.humanPID=humanPID
        targets[ProcessInfo.processInfo.processIdentifier] = "eval"
        targets[humanPID] = "human"
    }
    func setTarget(_ pid: Int32, role: String) {
        lock.withLock { targets[pid] = role }
        costMonitor?.setTarget(pid, role: role)
    }
    func startCosts(roots: String?) {
        guard let roots else { return }
        thread = Thread { [self] in
            while lock.withLock({ running }) {
                processCostSample(ProcessInfo.processInfo.systemUptime, roots: roots)
                Thread.sleep(forTimeInterval: 0.1)
            }
            processCostSample(ProcessInfo.processInfo.systemUptime, roots: roots)
            done.signal()
        }
        thread?.name = "Benchmark process costs"; thread?.start()
    }
    func finishCosts() {
        guard thread != nil else { return }
        lock.withLock { running = false }; done.wait()
    }
    func removeTarget(_ pid: Int32) { _ = lock.withLock { targets.removeValue(forKey: pid) } }
    func recordPath(_ point: CGPoint, time: Double) {
        lock.withLock { paths.append(PointSample(time: time, x: point.x, y: point.y)) }
        trace.emit("human.mouse_request", trial: trial, .object(["x": .number(point.x), "y": .number(point.y)]), at: time)
    }
    func recordOrigin(_ point: CGPoint, time: Double) {
        lock.withLock { paths.append(PointSample(time: time, x: point.x, y: point.y)) }
        trace.emit("human.path_origin", trial: trial, .object(["x": .number(point.x), "y": .number(point.y)]), at: time)
    }
    func pointerDelivered(_ expected: CGPoint, since requested: Double) -> Double? {
        lock.withLock {
            guard let sample = pointerDelivery, sample.time >= requested,
                  sample.x == expected.x, sample.y == expected.y else { return nil }
            return sample.time
        }
    }
    func checkRest(_ expected: CGPoint, deliveryConfirmed: Bool = true) {
        let actual = CGEvent(source: nil)?.location
        let exact = deliveryConfirmed && actual == expected
        lock.withLock { restChecks += 1; if !exact { restFailures += 1 } }
        trace.emit("human.cursor_rest", trial: trial, .object([
            "expectedX": .number(expected.x), "expectedY": .number(expected.y), "deliveryConfirmed": .bool(deliveryConfirmed),
            "actualX": actual.map { .number($0.x) } ?? .null,
            "actualY": actual.map { .number($0.y) } ?? .null, "exact": .bool(exact)
        ]))
    }
    func start() {
        heartbeat.start()
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: nil) { [self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                recordFocus(app.processIdentifier, source: "notification")
            }
        thread = Thread { [self] in run() }; thread?.name = "AgentSpace event tap"
        thread?.qualityOfService = .userInteractive; thread?.start()
    }
    func waitUntilReady() async {
        for _ in 0..<200 {
            if lock.withLock({ active }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func recordFocus(_ pid: Int32, source: String) {
        let value: JSONValue = .object(["pid": .number(Double(pid)), "source": .string(source),
                                      "expectedPID": .number(Double(humanPID))])
        lock.withLock { if active && pid != humanPID { focusViolations.append(value) } }
        trace.emit(pid == humanPID ? "monitor.focus" : "monitor.focus_theft", trial: trial, value)
    }
    func recordTap(_ type: CGEventType, _ event: CGEvent) {
        let start = ProcessInfo.processInfo.systemUptime
        defer { tapCallbackMaxMs = max(tapCallbackMaxMs, (ProcessInfo.processInfo.systemUptime-start)*1000) }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock { tapDisabled = true }
            trace.emit("monitor.tap_disabled", trial: trial, .object(["type": .number(Double(type.rawValue))])); return
        }
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        let key = "\(type.rawValue):\(pid):\(marker)"
        lock.withLock {
            tapCounts[key, default: 0] += 1
            if marker == Self.humanMarker, type == .mouseMoved {
                pointerDelivery = PointSample(time: ProcessInfo.processInfo.systemUptime, x: event.location.x, y: event.location.y)
            }
            if marker == 0x504944 {pidPointerProbeEvents += 1}
            if Evaluation.untaggedPointer(type: type.rawValue, marker: marker, humanMarker: Self.humanMarker) { untaggedPointerEvents += 1 }
        }
        trace.emit("monitor.event", trial: trial, .object([
            "type": .number(Double(type.rawValue)), "sourcePID": .number(Double(pid)),
            "sourceState": .number(Double(event.getIntegerValueField(.eventSourceStateID))),
            "userData": .number(Double(marker)), "humanTagged": .bool(marker == Self.humanMarker),
            "keyCode": .number(Double(event.getIntegerValueField(.keyboardEventKeycode))),
            "flags": .number(Double(event.flags.rawValue)), "x": .number(event.location.x), "y": .number(event.location.y)
        ]))
    }
    private func run() {
        let mask: CGEventMask = [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: { _, type, event, context in
                if let context { Unmanaged<Instrumentation>.fromOpaque(context).takeUnretainedValue().recordTap(type, event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        var source: CFRunLoopSource?
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        lock.withLock { tapReady = tap != nil; active = true }
        trace.emit("monitor.ready", trial: trial, .object(["tap": .bool(tap != nil), "nominalHz": .number(200)]))
        let sampler = Thread { [self] in sample(); samplerDone.signal() }
        sampler.name = "AgentSpace cursor and foreground sampler"
        sampler.qualityOfService = .userInteractive
        sampler.start()
        let resources = Thread { [self] in
            while lock.withLock({ running }) {
                let start = ProcessInfo.processInfo.systemUptime
                resourceSample(start)
                resourceMaxMs = max(resourceMaxMs, (ProcessInfo.processInfo.systemUptime-start)*1000)
                Thread.sleep(forTimeInterval: 0.1)
            }
            resourcesDone.signal()
        }
        resources.name = "AgentSpace resource sampler"
        resources.qualityOfService = .utility
        resources.start()
        while lock.withLock({ running }) {
            autoreleasepool {
                let start = ProcessInfo.processInfo.systemUptime
                CFRunLoopRunInMode(.defaultMode, 0.005, false)
                tapRunLoopMaxMs = max(tapRunLoopMaxMs, (ProcessInfo.processInfo.systemUptime-start)*1000)
            }
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes) }
        done.signal()
    }
    private func sample() {
        var lastPID: Int32 = -1
        while lock.withLock({ running }) {
            autoreleasepool {
                let now = ProcessInfo.processInfo.systemUptime
                let point = CGEvent(source: nil)?.location ?? CGPoint(x: -1, y: -1)
                let cursorEnd = ProcessInfo.processInfo.systemUptime
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
                let focusEnd = ProcessInfo.processInfo.systemUptime
                if pid != lastPID { recordFocus(pid, source: "poll"); lastPID = pid }
                lock.withLock { samples.append(PointSample(time: now, x: point.x, y: point.y)) }
                trace.emit("monitor.sample", trial: trial, .object([
                    "x": .number(point.x), "y": .number(point.y), "frontmostPID": .number(Double(pid))
                ]), at: now)
                let traceEnd = ProcessInfo.processInfo.systemUptime
                Thread.sleep(forTimeInterval: 0.005)
                let end = ProcessInfo.processInfo.systemUptime
                let stages = ["cursor": (cursorEnd-now)*1000, "focus": (focusEnd-cursorEnd)*1000,
                              "sampleTrace": (traceEnd-focusEnd)*1000, "sleep": (end-traceEnd)*1000]
                for (stage, ms) in stages { stageMaxMs[stage] = max(stageMaxMs[stage] ?? 0, ms) }
                if end-now > 0.05 {
                    trace.emit("monitor.slow_cycle", trial: trial, .object(stages.mapValues(JSONValue.number)), at: now)
                }
            }
        }
    }
    private func resourceSample(_ now: Double) {
        for (pid, role) in lock.withLock({ targets }) {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            let bytes = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size)
            guard bytes == size else {
                trace.emit("resource.unavailable", trial: trial, .object(["pid": .number(Double(pid)), "role": .string(role)])); continue
            }
            let cpu = Double(info.pti_total_user) + Double(info.pti_total_system)
            let previous = resourcePrevious[pid]
            let percent = previous.map { max(0, (cpu-$0.1)/1e9 / (now-$0.0)*100) }
            resourcePrevious[pid] = (now, cpu)
            trace.emit("resource.sample", trial: trial, .object([
                "pid": .number(Double(pid)), "role": .string(role), "rssBytes": .number(Double(info.pti_resident_size)),
                "cpuPercent": percent.map(JSONValue.number) ?? .null
            ]), at: now)
        }
    }
    private func processCostSample(_ now: Double, roots: String) {
        let registered = lock.withLock { targets }.filter { !["eval", "human"].contains($0.value) }
        var selected = costKnown.union(registered.keys).union(roots.split(separator: ",").compactMap { Int32($0) })
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return }
        var pids = [Int32](repeating: 0, count: Int(count)+256)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let found = proc_listallpids(&pids, capacity)
        var parents: [Int32: Int32] = [:]
        var started: [Int32: Double] = [:]
        var excluded: Set<Int32> = []
        for pid in pids.prefix(max(0, Int(found))) where pid > 0 {
            var info = proc_bsdinfo()
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0 {
                parents[pid] = Int32(info.pbi_ppid)
                started[pid] = Double(info.pbi_start_tvsec)+Double(info.pbi_start_tvusec)/1e6
                let name = withUnsafeBytes(of: info.pbi_comm) { bytes in
                    String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                }
                if name == "HumanPad" { excluded.insert(pid) }
            }
        }
        selected.formUnion(parents.filter { $0.value == ProcessInfo.processInfo.processIdentifier && !excluded.contains($0.key) }.keys)
        var changed = true
        while changed {
            let next = Set(parents.filter { selected.contains($0.value) }.keys)
            let old = selected.count; selected.formUnion(next); changed = selected.count != old
        }
        selected.subtract(excluded)
        var rss = 0.0
        for pid in selected {
            var info = proc_taskinfo()
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else { continue }
            let cpu = Double(info.pti_total_user)+Double(info.pti_total_system)
            if costFirst[pid] == nil { costFirst[pid] = (started[pid] ?? 0) >= costStart ? 0 : cpu }
            costLast[pid] = cpu
            rss += Double(info.pti_resident_size)
            trace.emit("benchmark.process", trial: trial, .object(["pid": .number(Double(pid)),
                "parentPID": .number(Double(parents[pid] ?? 0)), "cpuTotalNs": .number(cpu),
                "rssBytes": .number(Double(info.pti_resident_size))]), at: now)
        }
        costKnown.formUnion(selected)
        costPeakRSS = max(costPeakRSS, rss)
        let cpuSeconds = costLast.reduce(0.0) { $0 + max(0, $1.value-(costFirst[$1.key] ?? $1.value))/1e9 }
        trace.emit("benchmark.cost", trial: trial, .object(["sampledCPUSeconds": .number(cpuSeconds),
            "sampledPeakRSSBytes": .number(costPeakRSS), "processesSeen": .number(Double(costLast.count)),
            "coverage": .string("sampled lower bound; sub-100ms processes and post-last-sample CPU may be missed")]), at: now)
    }
    func finish() async -> JSONValue {
        lock.withLock { running = false }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                done.wait(); samplerDone.wait(); resourcesDone.wait(); continuation.resume()
            }
        }
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        let heartbeatGap = heartbeat.finish()
        return lock.withLock {
            let deviation = Evaluation.deviation(samples: samples, path: paths, tolerance: 0.04)
            let gaps = zip(samples, samples.dropFirst()).map { $1.time-$0.time }
            return .object([
                "tapReady": .bool(tapReady), "tapDisabled": .bool(tapDisabled),
                "untaggedPointerEvents": .number(Double(untaggedPointerEvents)),
                "cursorRestChecks": .number(Double(restChecks)), "cursorRestFailures": .number(Double(restFailures)),
                "pidPointerProbeGlobalEvents": .number(Double(pidPointerProbeEvents)),
                "samples": .number(Double(samples.count)), "pathRequests": .number(Double(paths.count)),
                "maxCursorDeviationRawPx": deviation.map { .number($0.raw) } ?? .null,
                "maxCursorDeviationTimingAdjustedPx": deviation.map { .number($0.adjusted) } ?? .null,
                "cursorTimingToleranceSeconds": .number(0.04),
                "focusTheftEvents": .array(focusViolations),
                "sampleGapP95Ms": Evaluation.percentile(gaps, 0.95).map { .number($0*1000) } ?? .null,
                "sampleGapMaxMs": gaps.max().map { .number($0*1000) } ?? .null,
                "stageMaxMs": .object(stageMaxMs.mapValues(JSONValue.number)),
                "tapCallbackMaxMs": .number(tapCallbackMaxMs),
                "tapRunLoopMaxMs": .number(tapRunLoopMaxMs),
                "resourceMaxMs": .number(resourceMaxMs),
                "heartbeatGapMaxMs": .number(heartbeatGap),
                "eventCounts": .object(tapCounts.mapValues { .number(Double($0)) })
            ])
        }
    }
}

private final class SamplingHeartbeat: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var maximum = 0.0
    private let done = DispatchSemaphore(value: 0)

    func start() {
        let thread = Thread { [self] in
            var previous = ProcessInfo.processInfo.systemUptime
            while lock.withLock({ running }) {
                Thread.sleep(forTimeInterval: 0.005)
                let now = ProcessInfo.processInfo.systemUptime
                maximum = max(maximum, (now-previous)*1000)
                previous = now
            }
            done.signal()
        }
        thread.name = "Sampling scheduler heartbeat"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func finish() -> Double {
        lock.withLock { running = false }
        done.wait()
        return maximum
    }
}

final class HumanSimulator: @unchecked Sendable {
    let monitor: Instrumentation
    let rect: CGRect
    private let lock = NSLock()
    private var running = true
    private var text = ""
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?
    init(monitor: Instrumentation, rect: CGRect) { self.monitor=monitor; self.rect=rect }
    func start() {
        thread = Thread { [self] in run() }; thread?.name = "Instrumented human simulator"; thread?.start()
    }
    private func run() {
        var i = 0, move = 0, state: UInt64 = 7331
        let alphabet = Array("human")
        if let point = CGEvent(source: nil)?.location {
            monitor.recordOrigin(point, time: ProcessInfo.processInfo.systemUptime)
        }
        var nextKey = ProcessInfo.processInfo.systemUptime, nextMove = nextKey
        var resting: (point: CGPoint, requested: Double)?
        while lock.withLock({ running }) {
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextMove {
                var canMove = true
                if let rest = resting {
                    switch CursorRest.phase(requested: rest.requested, delivered: monitor.pointerDelivered(rest.point, since: rest.requested), now: now) {
                    case .wait: canMove = false; nextMove = now+0.005
                    case .check: monitor.checkRest(rest.point); resting = nil
                    case .undelivered: monitor.checkRest(rest.point, deliveryConfirmed: false); resting = nil
                    }
                }
                if canMove {
                    let point = CGPoint(x: round(rect.minX+70+Double(move%80)*3), y: round(rect.minY+90+Double((move/80)%8)*5))
                    monitor.recordPath(point, time: now)
                    if let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
                        event.setIntegerValueField(.eventSourceUserData, value: Instrumentation.humanMarker)
                        event.post(tap: .cghidEventTap)
                    }
                    move += 1
                    if move % 10 == 0 { resting = (point, now); nextMove = now+0.15 }
                    else { nextMove = now+0.02 }
                }
            }
            if now >= nextKey {
                let character = String(alphabet[i%alphabet.count]), units = Array(character.utf16)
                for down in [true, false] {
                    if let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) {
                        units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                        event.setIntegerValueField(.eventSourceUserData, value: Instrumentation.humanMarker)
                        event.post(tap: .cghidEventTap)
                    }
                }
                lock.withLock { text += character }
                monitor.trace.emit("human.key_request", trial: monitor.trial, .object(["text": .string(character), "index": .number(Double(i))]), at: now)
                i += 1
                state = state &* 6364136223846793005 &+ 1
                nextKey = now + 0.085 + Double((state >> 32)%31)/1000
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        done.signal()
    }
    func finish() async -> String {
        lock.withLock { running = false }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [done] in done.wait(); continuation.resume() }
        }
        return lock.withLock { text }
    }
}
