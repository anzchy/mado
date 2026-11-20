import Dispatch
import Foundation

/// Label of the serial queue `offCooperativePool` runs its body on.
let offCooperativePoolLabel = "app.mado.tests.off-cooperative-pool"

/// Runs long CPU-bound synchronous test work on its own serial queue instead of a cooperative-pool thread (#774).
/// The body stays in the calling test's task, so `#expect`, `Test.current` and the test's time limit still apply.
/// A 3-core CI runner has three cooperative threads; long property walks on them kept every other async test of
/// the package run waiting. Call it from nonisolated tests (an actor-isolated caller keeps the body on its actor).
/// #787: at most `offCooperativePoolWidth` bodies run at once, so the walks never take more than all cores but two
/// (one core on a 3-core runner); CI run 44671441840 showed eight walks at once stretching unrelated tests to 29 s.
/// Before macOS 15 (no task executors) the body runs where it is called.
func offCooperativePool<T>(_ body: () -> T) async -> T {
    guard #available(macOS 15.0, *) else { return body() }
    return await withTaskExecutorPreference(OwnQueueExecutor()) { body() }
}

/// How many `offCooperativePool` bodies may run at once: all cores but two, at least one.
let offCooperativePoolWidth = max(1, ProcessInfo.processInfo.activeProcessorCount - 2)

/// Shared by every `offCooperativePool` call. A job waits for a slot on its own dispatch thread, never on a cooperative
/// one, and a body never awaits, so every slot is given back when its job ends.
private let offCooperativePoolSlots = DispatchSemaphore(value: offCooperativePoolWidth)

/// A task executor backed by one serial dispatch queue, which is not a cooperative-pool thread.
@available(macOS 15.0, *)
private final class OwnQueueExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: offCooperativePoolLabel)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async {
            offCooperativePoolSlots.wait()
            defer { offCooperativePoolSlots.signal() }
            job.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }
}
