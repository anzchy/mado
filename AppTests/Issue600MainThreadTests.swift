import AppKit
import Testing
import Darwin

@MainActor private func runMain600Loop(_ seconds: Double) {
    CFRunLoopRunInMode(.defaultMode, seconds, false)
}

@Suite(.serialized) @MainActor
struct Issue600MainThreadTests {
    @Test func issue600MainThreadThresholdAndPulseConservation() {
        #expect(Main600Policy.captureAgeMilliseconds(nowNS: 10_000_000_000, queuedNS: nil) == 0)
        #expect(Main600Policy.captureAgeMilliseconds(nowNS: 10_000_000_000, queuedNS: 10_000_000_000) == 0)
        #expect(Main600Policy.captureAgeMilliseconds(nowNS: 10_499_000_000, queuedNS: 10_000_000_000) == 499)
        #expect(Main600Policy.captureAgeMilliseconds(nowNS: 10_500_000_000, queuedNS: 10_000_000_000) == 500)
        #expect(!Main600Policy.shouldCapture(lagMilliseconds: 499, attempts: 0, ownsSignal: true))
        #expect(Main600Policy.shouldCapture(lagMilliseconds: 500, attempts: 0, ownsSignal: true))
        #expect(Main600Policy.shouldCapture(lagMilliseconds: 501, attempts: 0, ownsSignal: true))
        #expect(!Main600Policy.shouldCapture(lagMilliseconds: 800, attempts: 1, ownsSignal: true))
        #expect(!Main600Policy.shouldCapture(lagMilliseconds: 800, attempts: 0, ownsSignal: false))
        let pulse = i600_pulse_create(0)!
        defer { i600_pulse_destroy(pulse) }
        #expect(i600_pulse_lag(pulse, 499_000_000) == 499_000_000)
        #expect(i600_pulse_queue(pulse) == 1)
        #expect(i600_pulse_queue(pulse) == 0)
        #expect(i600_pulse_ack(pulse, 500_000_000) == 1)
        #expect(i600_pulse_lag(pulse, 501_000_000) == 1_000_000)
        #expect(i600_pulse_queue(pulse) == 1)
        i600_pulse_close(pulse)
        let counts = i600_pulse_counts(pulse)
        #expect(counts.queued == 2 && counts.acknowledged == 1 && counts.cancelled == 1 && counts.pending == 0)
        #expect(i600_pulse_queue(pulse) == 0 && i600_pulse_ack(pulse, 900_000_000) == 0)
        let next = i600_pulse_create(800_000_000)!
        defer { i600_pulse_destroy(next) }
        #expect(i600_pulse_queue(next) == 1)
        #expect(i600_pulse_ack(pulse, 900_000_000) == 0)
        #expect(i600_pulse_counts(next).pending == 1 && i600_pulse_counts(next).acknowledged == 0)
        #expect(i600_pulse_lag(next, 900_000_000) == 100_000_000)
        i600_pulse_close(next)
    }

    @Test func issue600MainThreadHeldMainActor() async throws {
        let origin = ContinuousClock.now
        let monitor = MainThread600Monitor(origin: origin)
        defer { _ = monitor.finish() }
        try await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        let beganWall = Date().timeIntervalSince1970 * 1000
        i600_main_thread_controlled_hold(900)
        let ended = ContinuousClock.now
        let endedWall = Date().timeIntervalSince1970 * 1000
        try await Task.sleep(for: .milliseconds(100))
        let report = monitor.finish()
        print("[i600.controlled-hold] pid=\(getpid()) beganWallUnixMs=\(beganWall) endedWallUnixMs=\(endedWall)")
        report.printLines(relativeTo: origin)
        #expect(report.status == "captured")
        #expect(report.attempts == 1 && report.signalReturn == 0 && report.workerStopped)
        #expect(report.capturedInstant.map { began < $0 && $0 < ended } == true)
        #expect(!report.frames.isEmpty && report.copiedBytes > 0)
        #expect(report.symbols.contains { $0.contains("i600_main_thread_controlled_hold") })
        #expect(report.events.filter { $0.kind == "heartbeat" && began < $0.instant && $0.instant < ended }.count >= 8)
        #expect(!report.events.contains { $0.kind == "main.acknowledged" && began < $0.instant && $0.instant < ended })
        #expect(report.events.contains { $0.kind == "main.acknowledged" && $0.instant > ended })
        #expect(report.events.filter { $0.kind == "signal.requested" }.allSatisfy { $0.lagMilliseconds >= 500 })
        let request = try #require(report.events.first { $0.kind == "signal.requested" })
        let queued = try #require(report.events.last { $0.kind == "main.queued" && $0.instant < request.instant })
        #expect(queued.instant.duration(to: request.instant) >= .milliseconds(500))
        #expect(report.events.allSatisfy { $0.pending <= 1 })
        #expect(report.queued == report.acknowledged + report.cancelled + UInt64(report.pending))
        #expect(monitor.finish() == report)
    }

    @Test func issue600MainThreadRunLoopBoundsAndTeardown() async throws {
        _ = NSApplication.shared
        let monitor = MainThread600Monitor(recordLimit: 12)
        defer { _ = monitor.finish() }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.02, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        runMain600Loop(0.07)
        CFRunLoopTimerInvalidate(timer)
        i600_main_thread_controlled_hold(650)
        try await Task.sleep(for: .milliseconds(80))
        i600_main_thread_controlled_hold(650)
        let report = monitor.finish()
        #expect(report.workerStopped && report.attempts == 1)
        #expect(report.events.count <= 12 && report.dropped > 0)
        #expect(report.queued == report.acknowledged + report.cancelled + UInt64(report.pending))
        #expect(report.events.allSatisfy { $0.pending <= 1 })
        try await Task.sleep(for: .milliseconds(120))
        runMain600Loop(0.02)
        #expect(monitor.finish() == report)
        let fresh = MainThread600Monitor()
        defer { _ = fresh.finish() }
        try await Task.sleep(for: .milliseconds(80))
        let next = fresh.finish()
        #expect(next.attempts == 0 && next.frames.isEmpty)
        #expect(next.owner != 0 && next.owner != report.owner)
    }

    @Test func issue600MainThreadRunLoopTransitions() {
        _ = NSApplication.shared
        let monitor = MainThread600Monitor()
        defer { _ = monitor.finish() }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.025, 0, 0, 0) { _ in }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
        runMain600Loop(0.08)
        CFRunLoopTimerInvalidate(timer)
        let report = monitor.finish()
        #expect(report.events.contains { $0.kind == "runloop.beforeWaiting" })
        #expect(report.events.contains { $0.kind == "runloop.afterWaiting" })
        #expect(report.events.contains { $0.kind == "runloop.running" })
        #expect(report.events.map(\.instant) == report.events.map(\.instant).sorted())
        runMain600Loop(0.02)
        #expect(monitor.finish() == report)
    }

    @Test func issue600MainThreadLatePulseCannotCrossSessions() async throws {
        let previous = MainThread600Monitor()
        defer { _ = previous.finish() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while previous.pulseCountsForTest.pending == 0 && ContinuousClock.now < deadline {
            i600_main_thread_controlled_hold(5)
        }
        #expect(previous.pulseCountsForTest.pending == 1)
        let closed = previous.finish()
        #expect(closed.queued == 1 && closed.acknowledged == 0 && closed.cancelled == 1)
        let next = MainThread600Monitor()
        defer { _ = next.finish() }
        try await Task.sleep(for: .milliseconds(120))
        let report = next.finish()
        #expect(previous.finish() == closed)
        #expect(report.owner != 0 && report.owner != closed.owner)
        #expect(report.acknowledged > 0)
        #expect(report.queued == report.acknowledged + report.cancelled + UInt64(report.pending))
        #expect(report.events.filter { $0.kind == "main.acknowledged" }.count == Int(report.acknowledged))
    }

    @Test func issue600MainThreadCopiedFrameGuards() {
        for architecture in [1, 2] {
            var meta = I600CaptureMeta(pc: 0x777, fp: 0x1010, sp: 0x1000, lr: 0, captured_ns: 0,
                                      byte_count: 64, architecture: Int32(architecture), truncated: 0)
            var bytes = [UInt8](repeating: 0, count: 64)
            func store(_ word: UInt64, at offset: Int) { for i in 0..<8 { bytes[offset+i] = UInt8(truncatingIfNeeded: word >> (8*i)) } }
            store(0x1020, at: 16); store(0xaaa, at: 24); store(0, at: 32); store(0xbbb, at: 40)
            func decode(count: Int = 64, cap: Int = 64) -> ([UInt], Int32) {
                var frames = [UInt](repeating: 0, count: cap), reason: Int32 = -1
                let found = bytes.withUnsafeBufferPointer { buffer in
                    i600_decode_frames(&meta, buffer.baseAddress, count, &frames, cap, &reason)
                }
                return (Array(frames.prefix(found)), reason)
            }
            #expect(decode().0 == [0x777, 0xaaa, 0xbbb] && decode().1 == 0)
            #expect(decode(cap: 2).0 == [0x777, 0xaaa] && decode(cap: 2).1 == 4)
            #expect(decode(cap: 0).0.isEmpty && decode(cap: 0).1 == 4)
            #expect(decode(count: 24).0 == [0x777] && decode(count: 24).1 == 5)
            meta.fp = 0xff0; #expect(decode().0 == [0x777] && decode().1 == 1)
            meta.fp = 0x1100; #expect(decode().1 == 1)
            meta.fp = 0x1011; #expect(decode().1 == 2)
            meta.fp = 0x1010; store(0x1010, at: 16); #expect(decode().1 == 3)
            store(0x1000, at: 16); #expect(decode().1 == 3)
            #expect(decode(count: 0).0 == [0x777] && decode(count: 0).1 == 6)
        }
    }
}
