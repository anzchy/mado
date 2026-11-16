import AppKit
import Testing

// #685 fix r5 F1: two Captures that overlap. A second Capture that starts while the first waits for the collapsed
// bar's icon to leave the screen must wait for the same hide and settle, and must wait its turn instead of overtaking
// the first and leaving it to fail as busy. The icon comes back once, after the last Capture ends.

/// A clock whose sleeps suspend until the test lets them end, so two Captures really overlap.
@MainActor private final class HeldClock {
    var now: Duration = .zero
    private var held: [(Duration, CheckedContinuation<Void, Never>)] = []
    var isHolding: Bool { !held.isEmpty }
    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { held.append((duration, $0)) }
    }
    /// Ends the oldest held sleep and moves the clock on by its length.
    func endOne() {
        guard !held.isEmpty else { return }
        let (duration, continuation) = held.removeFirst()
        now += duration
        continuation.resume()
    }
}

@MainActor private final class OverlapStatusItem: CaptureStatusItemHandle {
    var log: (String) -> Void = { _ in }
    private var hidden = false
    func remove() { log("remove") }
    func setHidden(_ hidden: Bool) { self.hidden = hidden; log(hidden ? "hide" : "show") }
    var isOnScreen: Bool { !hidden }
}

/// Stands in for the Capture session: a second screen read while one runs fails as busy.
@MainActor private final class OneReadAtATime {
    var reading = false
    var busy = 0
    func read(_ name: String, log: (String) -> Void, hold: () async -> Void = {}) async {
        guard !reading else { busy += 1; log("busy-\(name)"); return }
        reading = true
        log("capture-\(name)")
        await hold()
        reading = false
    }
}

@MainActor private func controller(clock: HeldClock, log: @escaping (String) -> Void) -> CaptureBarCollapseController {
    let bar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
    return CaptureBarCollapseController(bar: bar, localize: { $0 }, makeStatusItem: { _, _, _ in
        let item = OverlapStatusItem()
        item.log = log
        return item
    }, iconPoll: .milliseconds(16), sleep: { await clock.sleep($0) }, iconNeverLeft: {})
}

/// Lets other main-actor tasks run until `done` holds, at most a bounded number of turns.
@MainActor private func turns(until done: () -> Bool) async {
    var left = 1_000
    while left > 0, !done() {
        left -= 1
        await Task.yield()
    }
}

/// Ends held sleeps one at a time, letting the Captures run between them, until `done` holds.
@MainActor private func drain(_ clock: HeldClock, until done: () -> Bool) async {
    var left = 1_000
    while left > 0, !done() {
        left -= 1
        clock.endOne()
        await Task.yield()
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685OverlappingCollapsedCapturesShareTheSettleAndTakeTurns() async throws {
    var log: [String] = []
    let clock = HeldClock()
    let session = OneReadAtATime()
    let bar = controller(clock: clock, log: { log.append($0) })
    bar.collapse()
    var readAt: [String: Duration] = [:]

    let first = Task { @MainActor in
        await bar.whileCapturing { readAt["A"] = clock.now; await session.read("A", log: { log.append($0) }) }
    }
    await turns(until: { clock.isHolding })
    #expect(clock.isHolding)  // the first Capture waits for the 300 ms settle
    let second = Task { @MainActor in
        await bar.whileCapturing { readAt["B"] = clock.now; await session.read("B", log: { log.append($0) }) }
    }
    await turns(until: { readAt["B"] != nil })
    #expect(readAt.isEmpty, "no screen read before the settle ends")

    await drain(clock, until: { log.contains("show") })
    await first.value
    await second.value

    #expect(session.busy == 0)
    #expect(try #require(readAt["A"]) >= .milliseconds(300))
    #expect(try #require(readAt["B"]) >= .milliseconds(300))
    #expect(log == ["hide", "capture-A", "capture-B", "show"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685ACaptureThatArrivesDuringAnotherWaitsItsTurn() async throws {
    var log: [String] = []
    let clock = HeldClock()
    let session = OneReadAtATime()
    let bar = controller(clock: clock, log: { log.append($0) })
    var release: CheckedContinuation<Void, Never>?

    let first = Task { @MainActor in
        await bar.whileCapturing {
            await session.read("A", log: { log.append($0) }, hold: { await withCheckedContinuation { release = $0 } })
        }
    }
    await turns(until: { release != nil })
    let second = Task { @MainActor in
        await bar.whileCapturing { await session.read("B", log: { log.append($0) }) }
    }
    await turns(until: { log.count > 1 })
    #expect(log == ["capture-A"], "the second Capture waits while the first reads")
    release?.resume()
    await first.value
    await second.value
    #expect(session.busy == 0)
    #expect(log == ["capture-A", "capture-B"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue685OverlappingCapturesRestoreTheIconOnceWhenOneFails() async throws {
    var log: [String] = []
    let clock = HeldClock()
    let bar = controller(clock: clock, log: { log.append($0) })
    bar.collapse()
    struct Failed: Error {}

    let first = Task { @MainActor in
        try await bar.whileCapturing { log.append("capture-A"); throw Failed() }
    }
    await turns(until: { clock.isHolding })
    let second = Task { @MainActor in
        await bar.whileCapturing { log.append("capture-B") }
    }
    await drain(clock, until: { log.contains("show") })
    await #expect(throws: Failed.self) { try await first.value }
    await second.value
    #expect(log == ["hide", "capture-A", "capture-B", "show"])
}
