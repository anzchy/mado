import Dispatch
import Foundation

/// Label of the serial queue `onSharedSerialQueue` runs its bodies on.
let sharedSerialQueueLabel = "app.mado.tests.infrastructure-shared-serial"

/// Runs an async test body, and the default actors it calls, on one serial queue shared by every caller (#798).
/// The Baidu upload tests re-encode large noise images inside the provider actor, synchronously. On the 3-core CI
/// runner three of them at once held all three cooperative threads (CI run 44724946406) while the unrelated suites
/// waited. On this queue they take at most one thread, not a cooperative one, and run one at a time.
/// The body stays in the calling test's task, so `#expect`, `Test.current` and the test's time limit still apply.
/// Before macOS 15 (no task executors) the body runs where it is called.
func onSharedSerialQueue<T, E: Error>(_ body: () async throws(E) -> T) async throws(E) -> T {
    guard #available(macOS 15.0, *) else { return try await body() }
    return try await withTaskExecutorPreference(SharedSerialQueueExecutor.shared) { () async throws(E) -> T in try await body() }
}

/// A task executor backed by one serial dispatch queue, which is not a cooperative-pool thread.
@available(macOS 15.0, *)
private final class SharedSerialQueueExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = SharedSerialQueueExecutor()
    private let queue = DispatchQueue(label: sharedSerialQueueLabel)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
