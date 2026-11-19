import Dispatch

/// Label of the serial queue `offCooperativePool` runs its body on.
let offCooperativePoolLabel = "app.mado.tests.off-cooperative-pool"

/// Runs long CPU-bound synchronous test work on its own serial queue instead of a cooperative-pool thread (#774).
/// The body stays in the calling test's task, so `#expect`, `Test.current` and the test's time limit still apply.
/// A 3-core CI runner has three cooperative threads; long property walks on them kept every other async test of
/// the package run waiting. Call it from nonisolated tests (an actor-isolated caller keeps the body on its actor).
/// Before macOS 15 (no task executors) the body runs where it is called.
func offCooperativePool<T>(_ body: () -> T) async -> T {
    guard #available(macOS 15.0, *) else { return body() }
    return await withTaskExecutorPreference(OwnQueueExecutor()) { body() }
}

/// A task executor backed by one serial dispatch queue, which is not a cooperative-pool thread.
@available(macOS 15.0, *)
private final class OwnQueueExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: offCooperativePoolLabel)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
