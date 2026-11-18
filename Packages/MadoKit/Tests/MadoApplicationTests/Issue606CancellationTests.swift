import Foundation
import Testing

/// Runs the wait independently of the cooperative pool that other parallel tests occupy.
private actor DedicatedCancellationWait {
    nonisolated let queue = DispatchSerialQueue(label: "app.mado.tests.issue606.wait")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    func run(signal: AsyncStream<Void>.Continuation, finished: DispatchSemaphore) async -> String {
        defer { finished.signal() }
        do {
            try await waitUntil(fileID: "fixture", line: 606) {
                signal.yield()
                return false
            }
            return "unexpected return"
        } catch { return String(describing: error) }
    }
}

@MainActor private func holdMainActorUntilWaitFinishes(_ finished: DispatchSemaphore) -> Bool {
    finished.wait(timeout: .now() + 5) == .success
}

/// Cancel only after the background wait has started, then occupy MainActor until it throws.
/// The finite semaphore bound releases MainActor even on the old, broken implementation.
@Test(.timeLimit(.minutes(2))) @MainActor
func issue606CancelledBackgroundWaitDoesNotHopToBusyMainActor() async {
    let (started, signal) = AsyncStream<Void>.makeStream()
    let finished = DispatchSemaphore(value: 0)
    let runner = DedicatedCancellationWait()
    let waiter = Task { await runner.run(signal: signal, finished: finished) }
    var starts = started.makeAsyncIterator()
    _ = await starts.next()
    waiter.cancel()
    // Blocking here is intentional: a cancelled background wait must not need this actor to throw.
    let threwWhileMainActorWasBusy = holdMainActorUntilWaitFinishes(finished)
    let description = await waiter.value
    #expect(threwWhileMainActorWasBusy, "cancelled wait must finish before MainActor is released")
    #expect(description == "wait cancelled at fixture:606")
}
