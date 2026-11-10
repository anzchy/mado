import AppKit
import Darwin

fileprivate enum Main600Kind: Int, Sendable {
    case heartbeat, queued, submitted, acknowledged, requested, signalResult, stopped
    case beforeWaiting, afterWaiting, running, exit
    var label: String {
        switch self {
        case .heartbeat: "heartbeat"
        case .queued: "main.queued"
        case .submitted: "main.submission.returned"
        case .acknowledged: "main.acknowledged"
        case .requested: "signal.requested"
        case .signalResult: "signal.returned"
        case .stopped: "worker.stopped"
        case .beforeWaiting: "runloop.beforeWaiting"
        case .afterWaiting: "runloop.afterWaiting"
        case .running: "runloop.running"
        case .exit: "runloop.exit"
        }
    }
}
struct Main600Event: Equatable, Sendable {
    let instant: ContinuousClock.Instant
    fileprivate let code: Main600Kind
    var lagMilliseconds: Double = 0
    var pending: Int = 0
    var kind: String { code.label }
}
struct Main600Report: Equatable, Sendable {
    var status = "not-started"
    var owner: UInt64 = 0
    var attempts = 0
    var events: [Main600Event] = []
    var workerStopped = true
    var queued: UInt64 = 0
    var acknowledged: UInt64 = 0
    var cancelled: UInt64 = 0
    var pending = 0
    var dropped = 0
    var frames: [UInt] = []
    var symbols: [String] = []
    var capturedInstant: ContinuousClock.Instant?
    var signalReturn: Int32?
    var copiedBytes = 0
    var drained = 0
    var originWallUnixMs: Double = 0
    var captureClockOriginNS: UInt64 = 0
    var captureClockOrigin: ContinuousClock.Instant = .now
    var decodeReason = "none"
    var stackTruncated = false
    var workerError: Int32 = 0
    func printLines(relativeTo origin: ContinuousClock.Instant) {
        print("[i507.inprocess] status=\(status) pid=\(getpid()) owner=\(owner) attempts=\(attempts < 0 ? "unknown" : String(attempts)) workerStopped=\(workerStopped) queued=\(queued) acknowledged=\(acknowledged) cancelled=\(cancelled) pending=\(pending) dropped=\(dropped < 0 ? "unknown" : String(dropped)) copiedBytes=\(copiedBytes) stackTruncated=\(stackTruncated) drained=\(drained) decode=\(decodeReason) signalReturn=\(signalReturn.map(String.init) ?? "none") workerError=\(workerError)")
        print("[i507.inprocess-origin] shared=+\(origin.duration(to: captureClockOrigin)) wallUnixMs=\(originWallUnixMs) captureClockNs=\(captureClockOriginNS)")
        for event in events { print("[i507.inprocess-timeline] shared=+\(origin.duration(to: event.instant)) event=\(event.kind) lagMs=\(event.lagMilliseconds) pending=\(event.pending)") }
        if let capturedInstant { print("[i507.inprocess-stack] shared=+\(origin.duration(to: capturedInstant)) event=handler.captured signalReturn=\(signalReturn ?? -1) frames=\(frames.count)") }
        for (index, frame) in frames.enumerated() {
            print("[i507.inprocess-frame] index=\(index) address=0x\(String(frame, radix: 16)) symbol=\(index < symbols.count ? symbols[index] : "unknown")")
        }
    }
}
enum Main600Policy {
    static func captureAgeMilliseconds(nowNS: UInt64, queuedNS: UInt64?) -> Double {
        guard let queuedNS, nowNS >= queuedNS else { return 0 }
        return Double(nowNS - queuedNS) / 1_000_000
    }
    static func shouldCapture(lagMilliseconds: Double, attempts: Int, ownsSignal: Bool) -> Bool {
        ownsSignal && attempts == 0 && lagMilliseconds.isFinite && lagMilliseconds >= 500
    }
}

/// Single-writer storage, reserved before the worker starts. Never shared while mutable.
private final class Main600Records {
    private(set) var events: [Main600Event] = []
    private(set) var dropped = 0
    let limit: Int
    init(_ limit: Int) { self.limit = limit; events.reserveCapacity(limit) }
    func append(_ event: Main600Event) {
        if events.count == limit { events.removeFirst(); dropped += 1 }
        events.append(event)
    }
}


// A C callback declared outside the MainActor initializer cannot inherit its executor check.
private nonisolated func main600HeartbeatEntry(_ context: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? {
    let monitor = Unmanaged<MainThread600Monitor>.fromOpaque(context).takeRetainedValue()
    monitor.runWorker()
    return nil
}

final class MainThread600Monitor: @unchecked Sendable {
    private let pulse: OpaquePointer
    private let source: any DispatchSourceUserDataAdd
    private let stop = DispatchSemaphore(value: 0)
    private let workerRecords: Main600Records
    private let mainRecords: Main600Records
    private let recordLimit: Int
    private let tickMilliseconds: Int
    private let clockOrigin: ContinuousClock.Instant
    private let clockOriginNS: UInt64
    private let wallOrigin: Double
    private let owner: UInt64
    private let beginStatus: Int32
    private var thread: pthread_t?
    private var workerError: Int32 = 0
    private var attempts = 0 // worker only; read after pthread_join
    private var signalResult: Int32? // worker only; read after pthread_join
    private var observer: CFRunLoopObserver?
    private var terminal: Main600Report?

    @MainActor init(origin: ContinuousClock.Instant = .now, tickMilliseconds: Int = 50, recordLimit: Int = 2048) {
        _ = origin // Events are absolute instants; caller renders against its existing shared origin.
        self.recordLimit = min(4096, max(1, recordLimit))
        self.tickMilliseconds = min(1000, max(1, tickMilliseconds))
        workerRecords = Main600Records(self.recordLimit)
        mainRecords = Main600Records(self.recordLimit)
        clockOrigin = .now
        clockOriginNS = i600_clock_ns()
        wallOrigin = Date().timeIntervalSince1970 * 1000
        pulse = i600_pulse_create(clockOriginNS)!
        source = DispatchSource.makeUserDataAddSource(queue: .main)
        var status: Int32 = 3
        owner = i600_capture_begin(&status)
        beginStatus = status
        // Initialize any slow-wait semaphore backing before observing a held main thread.
        _ = stop.wait(timeout: .now() + .microseconds(50))
        source.setEventHandler { [weak self] in self?.acknowledge() }
        source.resume()
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { [weak self] _, activity in
            self?.recordRunLoop(activity)
        }
        if let observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
        let retained = Unmanaged.passRetained(self)
        var identifier: pthread_t?
        let created = pthread_create(&identifier, nil, main600HeartbeatEntry, retained.toOpaque())
        if created == 0 { thread = identifier }
        else { retained.release(); workerError = created; i600_pulse_close(pulse) }
    }
    deinit { i600_pulse_destroy(pulse) }

    private func instant(_ rawNS: UInt64) -> ContinuousClock.Instant {
        guard rawNS >= clockOriginNS, rawNS - clockOriginNS <= UInt64(Int64.max) else { return clockOrigin }
        return clockOrigin.advanced(by: .nanoseconds(Int64(rawNS - clockOriginNS)))
    }
    private func acknowledge() {
        guard i600_pulse_ack(pulse, i600_clock_ns()) == 1 else { return }
        mainRecords.append(.init(instant: .now, code: .acknowledged, pending: 0))
    }
    private func recordRunLoop(_ activity: CFRunLoopActivity) {
        guard i600_pulse_counts(pulse).active != 0 else { return }
        let code: Main600Kind
        switch activity {
        case .beforeWaiting: code = .beforeWaiting
        case .afterWaiting: code = .afterWaiting
        case .exit: code = .exit
        default: code = .running
        }
        mainRecords.append(.init(instant: .now, code: code, pending: Int(i600_pulse_counts(pulse).pending)))
    }
    fileprivate nonisolated func runWorker() {
        var queuedSince: UInt64?
        while i600_pulse_counts(pulse).active != 0 {
            let now = i600_clock_ns()
            if i600_pulse_counts(pulse).pending == 0 { queuedSince = nil }
            let age = Main600Policy.captureAgeMilliseconds(nowNS: now, queuedNS: queuedSince)
            workerRecords.append(.init(instant: instant(now), code: .heartbeat,
                lagMilliseconds: age, pending: Int(i600_pulse_counts(pulse).pending)))
            if i600_pulse_queue(pulse) == 1 {
                workerRecords.append(.init(instant: instant(now), code: .queued, pending: 1))
                source.add(data: 1)
                // Age starts after submission returns: a delayed startup/enqueue cannot trigger a false stack.
                queuedSince = i600_clock_ns()
                workerRecords.append(.init(instant: instant(queuedSince!), code: .submitted, pending: Int(i600_pulse_counts(pulse).pending)))
            }
            let current = i600_clock_ns()
            let pending = i600_pulse_counts(pulse).pending != 0
            let lag = Main600Policy.captureAgeMilliseconds(nowNS: current, queuedNS: pending ? queuedSince : nil)
            if Main600Policy.shouldCapture(lagMilliseconds: lag, attempts: attempts, ownsSignal: owner != 0) {
                attempts += 1
                workerRecords.append(.init(instant: instant(current), code: .requested, lagMilliseconds: lag, pending: 1))
                signalResult = i600_capture_request(owner)
                workerRecords.append(.init(instant: instant(i600_clock_ns()), code: .signalResult, lagMilliseconds: lag,
                    pending: Int(i600_pulse_counts(pulse).pending)))
            }
            if stop.wait(timeout: .now() + .milliseconds(tickMilliseconds)) == .success { break }
        }
        workerRecords.append(.init(instant: instant(i600_clock_ns()), code: .stopped))
    }
    @MainActor var pulseCountsForTest: I600PulseCounts { i600_pulse_counts(pulse) }

    @MainActor func finish() -> Main600Report {
        if let terminal { return terminal }
        i600_pulse_close(pulse)
        stop.signal()
        var joined = true
        if let thread {
            workerError = pthread_join(thread, nil)
            joined = workerError == 0
            if workerError == 0 { self.thread = nil }
        }
        source.cancel()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes); CFRunLoopObserverInvalidate(observer) }
        observer = nil
        var report = Main600Report()
        report.owner = owner; report.workerError = workerError; report.workerStopped = joined
        report.originWallUnixMs = wallOrigin; report.captureClockOriginNS = clockOriginNS; report.captureClockOrigin = clockOrigin
        let counts = i600_pulse_counts(pulse)
        report.queued = counts.queued; report.acknowledged = counts.acknowledged; report.cancelled = counts.cancelled; report.pending = Int(counts.pending)
        report.status = beginStatus == 1 ? "busy" : beginStatus == 2 ? "foreign-handler" : owner == 0 ? "setup-error" : "not-triggered"
        if !joined {
            // No safe join proof: do not restore a disposition while a request could still be in flight.
            report.status = "worker-incomplete"
            report.attempts = -1; report.dropped = -1
            report.events = mainRecords.events
            terminal = report
            return report
        }
        report.attempts = attempts; report.signalReturn = signalResult
        let merged = (mainRecords.events + workerRecords.events).sorted { $0.instant < $1.instant }
        report.events = Array(merged.suffix(recordLimit))
        report.dropped = mainRecords.dropped + workerRecords.dropped + max(0, merged.count - recordLimit)
        if owner != 0 {
            var set = sigset_t(), oldMask = sigset_t()
            sigemptyset(&set); sigaddset(&set, SIGUSR2)
            let blocked = pthread_sigmask(SIG_BLOCK, &set, &oldMask) == 0
            var meta = I600CaptureMeta()
            var copied = [UInt8](repeating: 0, count: 65536)
            let captured = blocked && copied.withUnsafeMutableBufferPointer {
                i600_capture_copy(owner, &meta, $0.baseAddress, $0.count) == 1
            }
            report.drained = Int(i600_capture_end(owner))
            if blocked { pthread_sigmask(SIG_SETMASK, &oldMask, nil) }
            if captured {
                var frames = [UInt](repeating: 0, count: 64), reason: Int32 = 0
                let found = copied.withUnsafeBufferPointer {
                    i600_decode_frames(&meta, $0.baseAddress, Int(meta.byte_count), &frames, 64, &reason)
                }
                report.frames = Array(frames.prefix(found))
                report.copiedBytes = Int(meta.byte_count); report.stackTruncated = meta.truncated != 0
                if meta.captured_ns >= clockOriginNS && clockOriginNS != 0 { report.capturedInstant = instant(meta.captured_ns) }
                let names = ["end", "outside-copy", "unaligned-frame", "nonmonotonic-frame", "frame-cap", "truncated-frame", "register-only", "unsupported-architecture"]
                report.decodeReason = names.indices.contains(Int(reason)) ? names[Int(reason)] : "unknown"
                report.symbols = report.frames.map { frame in
                    var info = Dl_info()
                    guard let address = UnsafeRawPointer(bitPattern: frame), dladdr(address, &info) != 0,
                          let symbol = info.dli_sname else { return "unknown" }
                    return String(String(cString: symbol).prefix(512).map { character in
                        if character.isNewline { return Character("?") }
                        if let ascii = character.asciiValue, ascii < 32 { return Character("?") }
                        return character
                    })
                }
                report.status = report.capturedInstant == nil ? "captured-unstamped" : "captured"
            } else if attempts > 0 { report.status = report.drained > 0 ? "pending-drained" : "requested-no-capture" }
            if report.drained < 0 || !blocked { report.status = "signal-teardown-error" }
        }
        if workerError != 0 { report.status = "worker-create-error" }
        terminal = report
        return report
    }
}
