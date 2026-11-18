import Foundation
import MadoApplication
@preconcurrency import Vision

// Test doubles and drivers for the #706/#711 cancellation tests in OnDeviceSaturationTests.

/// A fake whose cancel blocks the calling thread, as `-[VNCanceller signalCancellation]`
/// did on CI, until the test lets it go (or a deadline passes, so a failure cannot hang).
final class BlockingCanceller: @unchecked Sendable {
    let performEntered = DispatchSemaphore(value: 0)
    let cancelEntered = DispatchSemaphore(value: 0)
    let releasePerform = DispatchSemaphore(value: 0)
    let releaseCancel = DispatchSemaphore(value: 0)
    let throwsTypedError: Bool
    let performDeadline: DispatchTimeInterval
    private let lock = NSLock()
    private var timedOut = false

    init(throwsTypedError: Bool = false, performDeadline: DispatchTimeInterval = .seconds(30)) {
        self.throwsTypedError = throwsTypedError
        self.performDeadline = performDeadline
    }

    func perform() throws {
        performEntered.signal()
        if releasePerform.wait(timeout: .now() + performDeadline) == .timedOut {
            lock.lock(); timedOut = true; lock.unlock()
        }
        if throwsTypedError { throw TextRecognitionError.recognitionFailed(domain: "BlockingCanceller", code: 1) }
        throw NSError(domain: "BlockingCanceller", code: 1)
    }

    func cancel(_ request: VNRecognizeTextRequest) {
        cancelEntered.signal()
        _ = releaseCancel.wait(timeout: .now() + .seconds(2))
    }

    var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
}

/// Once the fake's perform has entered, cancels `task`, then lets the fake's cancel and perform
/// go. Returns how long `task.cancel()` took. All of it runs on its own thread, so the fake is
/// released however long the caller's executor takes to resume (#749).
func cancelAndRelease(_ fake: BlockingCanceller, _ task: Task<TextRecognitionError?, Never>) async -> Duration {
    await withCheckedContinuation { done in
        Thread.detachNewThread {
            fake.performEntered.wait()
            let started = ContinuousClock.now
            task.cancel()
            let cancelTook = ContinuousClock.now - started
            fake.releaseCancel.signal()
            fake.releasePerform.signal()
            done.resume(returning: cancelTook)
        }
    }
}

/// A task executor with one thread that a test can hold, standing in for a cooperative pool
/// whose threads are all busy (#749: a 3-core CI runner).
@available(macOS 15.0, *)
final class HoldableExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.mado.tests.holdable-executor")

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }

    /// Keeps the executor's thread busy for `duration`; jobs enqueued meanwhile wait.
    func hold(for duration: TimeInterval) {
        queue.async { Thread.sleep(forTimeInterval: duration) }
    }
}
