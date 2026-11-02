/// A condition wait that ended without its condition holding: the bound ran out or the test was cancelled. Throwing
/// it ends the test at the wait, so the expectations after it never run against a state that did not arrive (#392).
struct ConditionWaitError: Error, CustomStringConvertible {
    let description: String
}

/// Cancellation by the test's time limit is what normally ends a wait that never holds. The wall-clock default only
/// bounds waits in untimed tests: it sits near the two-minute limits, far above CI's main-actor queueing (#277, most
/// of a minute; #390 saw 35 s), so a loaded runner cannot fail a condition that does hold.
let conditionWaitDefaultTimeout = Duration.seconds(100)

/// Waits until `condition` holds, sleeping 5 ms between looks so a busy main actor still runs the work being waited
/// for. `between` runs before each sleep. Throws `ConditionWaitError` when `timeout` passes on `clock` or the task is
/// cancelled, naming the call site.
func waitUntil(
    _ comment: @autoclosure () -> String = "", timeout: Duration = conditionWaitDefaultTimeout,
    clock: some Clock<Duration> = ContinuousClock(), fileID: String = #fileID, line: Int = #line,
    isolation: isolated (any Actor)? = #isolation, between: () -> Void = {}, _ condition: () async throws -> Bool
) async throws {
    let deadline = clock.now.advanced(by: timeout)
    while try await !condition() {
        let site = comment().isEmpty ? "\(fileID):\(line)" : "\(fileID):\(line) (\(comment()))"
        if Task.isCancelled { throw ConditionWaitError(description: "wait cancelled at \(site)") }
        if clock.now >= deadline { throw ConditionWaitError(description: "wait timed out after \(timeout) at \(site)") }
        between()
        try? await clock.sleep(until: clock.now.advanced(by: .milliseconds(5)), tolerance: nil)
    }
}

/// Runs `body`, then awaits `teardown` whether `body` returned or threw (#392). Cleanup that has to await, such as
/// releasing a held actor gate, is awaited here instead of being left to a fire-and-forget task in `defer`.
func withAsyncTeardown<T>(
    isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T, teardown: () async -> Void
) async throws -> T {
    let value: T
    do { value = try await body() } catch { await teardown(); throw error }
    await teardown()
    return value
}
