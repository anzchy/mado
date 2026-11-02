import Foundation
import os
import Testing

/// A clock whose sleeps pass at once and move `now` to their deadline, so a 100 s bound runs out in microseconds.
private struct StepClock: Clock {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var now = Instant(offset: .zero)
        var sleeps = 0
    }
    private let state = State()
    var now: Instant { state.lock.withLock { state.now } }
    var sleeps: Int { state.lock.withLock { state.sleeps } }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.lock.withLock { state.sleeps += 1; state.now = max(state.now, deadline) }
        await Task.yield()
    }
}

/// #392: a wait that never holds throws at its bound, naming the call site, and the default bound is 100 s.
@Test(.timeLimit(.minutes(2))) func i392WaitThrowsAtTheDefaultBoundOnTheInjectedClock() async throws {
    let clock = StepClock()
    var looks = 0
    do {
        try await waitUntil("never", clock: clock, fileID: "Picsee/Site.swift", line: 7) { looks += 1; return false }
        Issue.record("a wait that never holds returned")
    } catch let error as ConditionWaitError {
        #expect(error.description == "wait timed out after 100.0 seconds at Picsee/Site.swift:7 (never)")
    }
    // 5 ms looks across 100 s: the bound is reached on the clock, not by a loop count.
    #expect(clock.sleeps == 20_000)
    #expect(looks == 20_001)
    #expect(clock.now.offset == .seconds(100))
}

@Test(.timeLimit(.minutes(2))) func i392WaitReturnsOnceTheConditionHoldsAndRunsBetweenBeforeEachSleep() async throws {
    let clock = StepClock()
    var looks = 0, betweens = 0
    try await waitUntil(timeout: .seconds(1), clock: clock, between: { betweens += 1 }) { looks += 1; return looks == 4 }
    #expect(looks == 4)
    #expect(betweens == 3)
    #expect(clock.sleeps == 3)
    // A condition that already holds neither sleeps nor runs `between`.
    try await waitUntil(clock: clock, between: { betweens += 1 }) { true }
    #expect(betweens == 3 && clock.sleeps == 3)
}

/// A wait the test cancels throws at once with its site, even with the default bound still far away.
@Test(.timeLimit(.minutes(2))) func i392CancelledWaitThrowsPromptly() async throws {
    let (started, signal) = AsyncStream<Void>.makeStream()
    let waiter = Task {
        var first = true
        try await waitUntil(fileID: "Picsee/Cancel.swift", line: 3) {
            if first { first = false; signal.yield() }
            return false
        }
    }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    let clock = ContinuousClock(), begin = clock.now
    waiter.cancel()
    do {
        try await waiter.value
        Issue.record("a cancelled wait returned")
    } catch let error as ConditionWaitError {
        #expect(error.description == "wait cancelled at Picsee/Cancel.swift:3")
    }
    #expect(clock.now - begin < .seconds(30), "far below the 100 s default bound")
}

/// A wait in an already cancelled task looks once, then throws without sleeping.
@Test(.timeLimit(.minutes(2))) func i392PreCancelledWaitLooksOnceAndThrows() async throws {
    let clock = StepClock()
    let waiter = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        var looks = 0
        do { try await waitUntil(clock: clock) { looks += 1; return false } } catch is ConditionWaitError {}
        return looks
    }
    #expect(try await waiter.value == 1)
    #expect(clock.sleeps == 0)
}

private struct TeardownProbe: Error {}

@Test func i392AsyncTeardownRunsAfterTheBodyReturnsOrThrows() async throws {
    var log: [String] = []
    let value = try await withAsyncTeardown { log.append("body"); return 7 } teardown: { await Task.yield(); log.append("teardown") }
    #expect(value == 7)
    #expect(log == ["body", "teardown"])
    do {
        try await withAsyncTeardown { log.append("body"); throw TeardownProbe() } teardown: { log.append("teardown") }
        Issue.record("the body's error was swallowed")
    } catch is TeardownProbe {}
    #expect(log == ["body", "teardown", "body", "teardown"])
}

/// `signal()` lets exactly one blocked worker through; `open()` frees every current and later waiter.
@Test(.timeLimit(.minutes(2))) func i392TestGateSignalsOneWaiterAndOpenFreesAll() async throws {
    let gate = TestGate()
    defer { gate.open() }
    let passed = OSAllocatedUnfairLock(initialState: 0)
    for _ in 0..<3 { Thread { gate.wait(); passed.withLock { $0 += 1 } }.start() }
    gate.signal()
    try await waitUntil { passed.withLock { $0 } == 1 }
    try await Task.sleep(for: .milliseconds(50))
    #expect(passed.withLock { $0 } == 1, "one signal, one waiter")
    gate.open()
    try await waitUntil { passed.withLock { $0 } == 3 }
    gate.wait() // open: a later waiter does not block
    gate.wait()
    #expect(passed.withLock { $0 } == 3)
}

/// The four test targets each carry a copy of the wait helpers; they must not drift apart (#392).
@Test func i392ConditionWaitCopiesStayIdentical() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let paths = ["AppTests", "Packages/PicseeKit/Tests/PicseeApplicationTests",
                 "Packages/PicseeKit/Tests/PicseeInfrastructureTests", "Packages/PicseeKit/Tests/PicseeMacUITests"]
    func core(_ source: String) throws -> Substring {
        let start = try #require(source.range(of: "/// A condition wait that ended"))
        let end = try #require(source.range(of: "    return value\n}\n"))
        return source[start.lowerBound..<end.upperBound]
    }
    let cores = try paths.map {
        try core(String(contentsOf: repo.appendingPathComponent("\($0)/ConditionWait.swift"), encoding: .utf8))
    }
    #expect(cores.allSatisfy { $0 == cores[0] }, "ConditionWait.swift copies differ")
    #expect(cores[0].contains("Duration.seconds(100)"))
}
