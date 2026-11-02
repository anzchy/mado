import Foundation
import Testing

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

/// The tasks a test starts, so its teardown can cancel them and then wait for every one to end after it releases
/// their gates (#392). A test that exits early leaves no work running into the next test.
final class StartedTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var running = 0
    private var cancels: [@Sendable () -> Void] = []
    @discardableResult func track<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) -> Task<Success, Failure> {
        lock.withLock { running += 1; cancels.append { task.cancel() } }
        Task.detached { _ = await task.result; self.lock.withLock { self.running -= 1 } }
        return task
    }
    var allEnded: Bool { lock.withLock { running == 0 } }
    func cancelAll() { for cancel in lock.withLock({ cancels }) { cancel() } }
    /// Waits until every tracked task has ended, running `releasing` before each look so a task that reaches its gate
    /// after teardown began is still let through. The test's own cancellation does not cut this short; a task still
    /// running after `limit` is recorded as an issue at the call site instead of being left behind silently.
    func awaitAll(
        limit: Duration = conditionWaitDefaultTimeout, fileID: String = #fileID, line: Int = #line,
        isolation: isolated (any Actor)? = #isolation, releasing: () async -> Void = {}
    ) async {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: limit)
        while true {
            await releasing()
            guard !allEnded, clock.now < deadline else { break }
            await withCheckedContinuation { resumed in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { resumed.resume() }
            }
        }
        if !allEnded { Issue.record("a started task was still running \(limit) after teardown at \(fileID):\(line)") }
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
