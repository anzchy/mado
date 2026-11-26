import Foundation

/// Whether a stub's cancelled load reached `stopLoading` (#904). URLSession delivers `stopLoading` asynchronously after
/// a cancel, so a test checks the count with this instead of sampling it once right after the cancelled result.
/// Polls with `waitUntil` until `stopCount()` is at least 1 or `bound` passes, then answers. The bound is checked here
/// because `waitUntil` has no deadline of its own inside a timed test: a stop that never comes ends as `false`, which
/// fails the caller's expectation, not as a wait that runs to the test's time limit.
func stopReached(within bound: Duration = .seconds(10), fileID: String = #fileID, line: Int = #line,
                 _ stopCount: () -> Int) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: bound)
    try await waitUntil("stopLoading reached", fileID: fileID, line: line) {
        stopCount() >= 1 || clock.now >= deadline
    }
    return stopCount() >= 1
}
