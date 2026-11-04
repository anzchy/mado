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
    func advance(by duration: Duration) { state.lock.withLock { state.now = state.now.advanced(by: duration) } }
    var minimumResolution: Duration { .zero }
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        state.lock.withLock { state.sleeps += 1; state.now = max(state.now, deadline) }
        await Task.yield()
    }
}

/// #400: fake time passes the former deadline while the condition is still false.
@Test(.timeLimit(.minutes(2))) func i392WaitThrowsAtTheDefaultBoundOnTheInjectedClock() async throws {
    #expect(Test.current?.traits.contains(where: { $0 is TimeLimitTrait }) == true)
    let clock = StepClock()
    var looks = 0
    try await waitUntil("late success", clock: clock) {
        looks += 1
        clock.advance(by: .seconds(10))
        return looks == 12
    }
    #expect(looks == 12)
    #expect(clock.now.offset > .seconds(100))
}

@Test(.timeLimit(.minutes(2))) func i400TimedExplicitWaitHasNoCutoff() async throws {
    let clock = StepClock()
    var looks = 0
    try await waitUntil(timeout: .seconds(1), clock: clock) {
        looks += 1
        clock.advance(by: .seconds(10))
        return looks == 12
    }
    #expect(looks == 12)
    #expect(clock.now.offset > .seconds(100))
}

@Test func i400UntimedWaitKeepsItsBounds() async throws {
    #expect(Test.current?.traits.contains(where: { $0 is TimeLimitTrait }) != true)
    for timeout in [conditionWaitDefaultTimeout, .seconds(1)] {
        let clock = StepClock()
        var errors = 0, returned = false
        do {
            if timeout == conditionWaitDefaultTimeout {
                try await waitUntil("never", clock: clock, fileID: "Site", line: 7) { false }
            } else {
                try await waitUntil("never", timeout: timeout, clock: clock, fileID: "Site", line: 7) { false }
            }
            returned = true
        } catch let error as ConditionWaitError {
            errors += 1
            #expect(error.description == "wait timed out after \(timeout) at Site:7 (never)")
        }
        #expect(errors == 1 && !returned)
        #expect(clock.now.offset == timeout)
        #expect(clock.sleeps == (timeout == .seconds(1) ? 200 : 20_000))
    }
}

@Test(.timeLimit(.minutes(2))) func i400TimedWaitCancellationAfterFormerDeadlineThrowsOnce() async throws {
    let clock = StepClock()
    let result = try await Task {
        var looks = 0, errors = 0, returned = false
        do {
            try await waitUntil("held condition", clock: clock, fileID: "Site", line: 9) {
                looks += 1
                clock.advance(by: .seconds(10))
                if looks == 12 { withUnsafeCurrentTask { $0?.cancel() } }
                return false
            }
            returned = true
        } catch let error as ConditionWaitError {
            errors += 1
            #expect(error.description == "wait cancelled at Site:9 (held condition)")
        }
        return (looks, errors, returned)
    }.value
    #expect(result.0 == 12 && result.1 == 1 && !result.2)
    #expect(clock.now.offset > .seconds(100))
    let sleeps = clock.sleeps
    await Task.yield()
    #expect(clock.sleeps == sleeps)
}

@MainActor @Test(.timeLimit(.minutes(2))) func i400TimedRunLoopHasNoCutoff() throws {
    #expect(Test.current?.traits.contains(where: { $0 is TimeLimitTrait }) == true)
    for explicit in [false, true] {
        let clock = StepClock()
        var looks = 0
        func condition() -> Bool {
            looks += 1
            clock.advance(by: .seconds(10))
            return looks == 12
        }
        if explicit { try runLoopUntil(timeout: .seconds(1), clock: clock, condition) }
        else { try runLoopUntil(clock: clock, condition) }
        #expect(looks == 12 && clock.now.offset > .seconds(100))
    }
    let delivered = OSAllocatedUnfairLock(initialState: false)
    let timer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: false) { _ in delivered.withLock { $0 = true } }
    defer { timer.invalidate() }
    try runLoopUntil { delivered.withLock { $0 } }
    #expect(delivered.withLock { $0 })
}

@MainActor @Test func i400UntimedRunLoopKeepsItsBounds() throws {
    #expect(Test.current?.traits.contains(where: { $0 is TimeLimitTrait }) != true)
    for timeout in [conditionWaitDefaultTimeout, .seconds(1)] {
        let clock = StepClock()
        var errors = 0, returned = false
        func condition() -> Bool { clock.advance(by: .seconds(1)); return false }
        do {
            if timeout == conditionWaitDefaultTimeout {
                try runLoopUntil("never", clock: clock, fileID: "Site", line: 8, condition)
            } else {
                try runLoopUntil("never", timeout: timeout, clock: clock, fileID: "Site", line: 8, condition)
            }
            returned = true
        } catch let error as ConditionWaitError {
            errors += 1
            #expect(error.description == "run loop wait timed out after \(timeout) at Site:8 (never)")
        }
        #expect(errors == 1 && !returned)
        #expect(clock.now.offset == timeout)
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func i400TimedRunLoopCancellationThrowsOnce() async throws {
    let clock = StepClock()
    let result = try await Task { @MainActor in
        var looks = 0, errors = 0, returned = false
        do {
            try runLoopUntil("held condition", clock: clock, fileID: "Site", line: 10) {
                looks += 1
                clock.advance(by: .seconds(10))
                if looks == 12 { withUnsafeCurrentTask { $0?.cancel() } }
                return false
            }
            returned = true
        } catch let error as ConditionWaitError {
            errors += 1
            #expect(error.description == "run loop wait cancelled at Site:10 (held condition)")
        }
        return (looks, errors, returned)
    }.value
    #expect(result.0 == 12 && result.1 == 1 && !result.2)
    #expect(clock.now.offset > .seconds(100))
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
    // Teardown has no wall-clock bound below the test's time limit: only cancellation ends it early (#398).
    let startedTasks = try #require(cores[0].range(of: "final class StartedTasks")).lowerBound
    let teardownHelper = try #require(cores[0].range(of: "func withAsyncTeardown")).lowerBound
    let section = cores[0][startedTasks..<teardownHelper]
    for banned in ["Clock", "deadline", "limit:", "timeout", "waitUntil(", "runLoopUntil(", "0..<", "DispatchTime", "Date("] {
        #expect(!section.contains(banned), "StartedTasks keeps a bound: \(banned)")
    }
}

private actor I392Hold {
    private var waiter: CheckedContinuation<Void, Never>?, opened = false
    func hold() async { if !opened { await withCheckedContinuation { waiter = $0 } } }
    func open() { opened = true; waiter?.resume(); waiter = nil }
}

/// Not cancelled, teardown waits for every tracked task to end, however many looks that takes, running its release
/// action before each look; there is no wall-clock bound to cut it short (#398). Cancelled with nothing left
/// running, it records nothing.
@Test(.timeLimit(.minutes(2))) func i398StartedTasksAwaitAllWaitsUntilEveryTaskEnds() async throws {
    let started = StartedTasks(), first = I392Hold(), second = I392Hold()
    let a = started.track(Task { await first.hold(); return 1 })
    let b = started.track(Task { await second.hold(); return 2 })
    var looks = 0
    await started.awaitAll {
        looks += 1
        if looks == 10 { await first.open() }
        if looks == 40 { await second.open() }
    }
    #expect(started.allEnded)
    #expect(looks >= 40)
    let values = (await a.value, await b.value)
    #expect(values == (1, 2))
    await Task { withUnsafeCurrentTask { $0?.cancel() }; await started.awaitAll() }.value
}

/// A teardown that starts already cancelled (the time limit fired in the body) still runs its release action before
/// it stops, so gated tasks are let through; a task not yet ended is named as still running (#398).
@Test(.timeLimit(.minutes(2))) func i398CancelledTeardownStillReleasesBeforeItStops() async throws {
    let started = StartedTasks(), hold = I392Hold()
    let held = started.track(Task { await hold.hold(); return 1 })
    var releases = 0
    await withKnownIssue("the released task may not have ended by the single look", isIntermittent: true) {
        releases = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var releases = 0
            await started.awaitAll { releases += 1; await hold.open() }
            return releases
        }.value
    }
    #expect(releases >= 1)
    let value = await held.value
    #expect(value == 1)
    await started.awaitAll()
    #expect(started.allEnded)
}

/// Only the cancellation of the awaiting task (the test's time limit) ends the wait early; it then names, in one
/// issue, the site that started each task still running, and not the sites of tasks that ended (#398).
@Test(.timeLimit(.minutes(2))) func i392StartedTasksAwaitAllRecordsATaskStillRunning() async throws {
    let started = StartedTasks(), holdB = I392Hold(), holdC = I392Hold()
    let lineB = #line + 1
    started.track(Task { await holdB.hold() })
    let lineA = #line + 1
    let a = started.track(Task {})
    let lineC = #line + 1
    started.track(Task { await holdC.hold() })
    await a.value
    try await waitUntil { started.runningCount == 2 }
    let site = "PicseeApplicationTests/ConditionWaitTests.swift"
    try await withKnownIssue("the teardown was cancelled with B and C still running") {
        let looks = OSAllocatedUnfairLock(initialState: 0)
        let teardown = Task { await started.awaitAll { looks.withLock { $0 += 1 } } }
        try await waitUntil { looks.withLock { $0 } >= 3 }
        teardown.cancel()
        await teardown.value
    } matching: { issue in
        issue.comments.contains {
            $0.rawValue.contains("\(site):\(lineB)") && $0.rawValue.contains("\(site):\(lineC)")
                && !$0.rawValue.contains("\(site):\(lineA)")
        }
    }
    #expect(started.runningCount == 2, "the wait ended by cancellation, not because the held tasks ended")
    await holdB.open()
    await holdC.open()
    await started.awaitAll()
    #expect(started.allEnded)
}

/// The same-class waits found by the #398 sweep stay on the shared cancellation-driven wait: no polling-count or
/// short wall-clock bound, and a failed wait throws instead of returning silently.
@Test func i398SweptWaitHelpersUseTheSharedWait() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helpers = [
        ("Packages/PicseeKit/Tests/PicseeMacUITests/FirstLaunchWallTestSupport.swift", "func waitForSamples"),
        ("Packages/PicseeKit/Tests/PicseeInfrastructureTests/InspectorThumbnailBudgetTests.swift", "func inspectorWait"),
        ("Packages/PicseeKit/Tests/PicseeApplicationTests/FolderScanReadFailedTests.swift", "func waitForCall"),
        ("Packages/PicseeKit/Tests/PicseeApplicationTests/Issue233InspectorFailureCallbackTests.swift", "func r2CallbackWait"),
        ("AppTests/Issue233ReplacementProbeTests.swift", "func replacementWait"),
        ("AppTests/SidebarTreeControllerTests.swift", "func waitForSidebar"),
        ("AppTests/Issue233FileGrantReaderFailureTests.swift", "func r2Wait"),
        ("AppTests/Issue233FileGrantLossTests.swift", "func lossWait"),
        ("Packages/PicseeKit/Tests/PicseeMacUITests/Page22EmptyFolderTests.swift", "func waitForScanEnd"),
    ]
    for (path, name) in helpers {
        let lines = try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
            .components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains(name) }, "\(path): \(name)")
        let indent = String(lines[start].prefix { $0 == " " })
        let end = try #require(lines[start...].firstIndex { $0 == indent + "}" }, "\(path): end of \(name)")
        let body = lines[start...end].joined(separator: "\n")
        #expect(body.contains("waitUntil("), "\(path): \(name) does not use waitUntil")
        for banned in ["0..<", "Clock", "deadline", "timeout", "seconds(", "spins"] {
            #expect(!body.contains(banned), "\(path): \(name) keeps \(banned)")
        }
    }
    let sidebar = try String(contentsOf: repo.appendingPathComponent("AppTests/SidebarTreeControllerTests.swift"),
                             encoding: .utf8)
    #expect(!sidebar.contains("sidebarCondition(for: 2)"), "the delivered-change wait is a positive wait")
}
