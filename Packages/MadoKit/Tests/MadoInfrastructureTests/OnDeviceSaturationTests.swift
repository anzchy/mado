import Foundation
import Testing
@preconcurrency import Vision
@testable import MadoInfrastructure
import MadoApplication

/// A fake recogniser that blocks the thread that runs `perform`, as Vision's synchronous
/// `VNImageRequestHandler.perform` does, until the request is cancelled. The wait has a
/// deadline so a starved test fails instead of hanging the process: if no cancellation
/// arrives within `deadline`, the perform records starvation and returns.
private final class BlockingRecogniser: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = 0
    private var starved = 0
    private var cancelled = 0
    private let release = DispatchSemaphore(value: 0)
    let deadline: DispatchTimeInterval

    init(deadline: DispatchTimeInterval) { self.deadline = deadline }

    func perform() throws {
        lock.lock(); entered += 1; lock.unlock()
        if release.wait(timeout: .now() + deadline) == .timedOut {
            lock.lock(); starved += 1; lock.unlock()
            throw NSError(domain: "BlockingRecogniser", code: 1)
        }
        throw NSError(domain: "BlockingRecogniser", code: 2)
    }

    func cancel(_ request: VNRecognizeTextRequest) {
        request.cancel()
        lock.lock(); cancelled += 1; lock.unlock()
        release.signal()
    }

    var enteredCount: Int { lock.lock(); defer { lock.unlock() }; return entered }
    var starvedCount: Int { lock.lock(); defer { lock.unlock() }; return starved }
}

private func saturationImage() throws -> Data {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    return try Data(contentsOf: root.appendingPathComponent("TestAssets/TextRecognition/mixed.png"))
}

/// #706: more blocking requests than the cooperative pool has threads, then cancel.
/// When `perform` runs on the cooperative pool, every pool thread is blocked, the test
/// cannot resume to cancel, and each perform hits its deadline (starved, not cancelled).
/// When `perform` runs off the pool, the test cancels promptly and every request
/// returns `.cancelled` without any perform starving.
@Test(.timeLimit(.minutes(2)))
func issue706SaturatedBlockingRequestsCancelPromptly() async throws {
    let width = ProcessInfo.processInfo.activeProcessorCount + 2
    let recogniser = BlockingRecogniser(deadline: .seconds(3))
    let provider = OnDeviceTextRecognitionProvider(
        performRequest: { _, _ in try recogniser.perform() },
        cancelRequest: { recogniser.cancel($0) }
    )
    let bytes = try saturationImage()
    // The driver runs at the provider's worker priority, so it competes for the same
    // cooperative threads as the requests it must cancel (as the CI test task did).
    let results = await Task.detached(priority: .userInitiated) { () -> [TextRecognitionError?] in
        let tasks = (0..<width).map { _ in
            Task(priority: .userInitiated) { () -> TextRecognitionError? in
                do throws(TextRecognitionError) { _ = try await provider.recognise(bytes); return nil }
                catch { return error }
            }
        }
        // Give every request the chance to reach `perform` (on the cooperative pool they
        // all do, which saturates it); off the pool only one is inside the serial perform.
        let settle = ContinuousClock.now + .seconds(1)
        while recogniser.enteredCount < width, ContinuousClock.now < settle {
            try? await Task.sleep(for: .milliseconds(10))
        }
        for task in tasks { task.cancel() }
        var results: [TextRecognitionError?] = []
        for task in tasks { results.append(await task.value) }
        return results
    }.value

    #expect(recogniser.enteredCount >= 1)
    #expect(recogniser.starvedCount == 0)
    #expect(results.allSatisfy { $0 == .cancelled })
}

/// A fake whose cancel blocks the calling thread, as `-[VNCanceller signalCancellation]`
/// did on CI, until the test lets it go (or a deadline passes, so a failure cannot hang).
private final class BlockingCanceller: @unchecked Sendable {
    let performEntered = DispatchSemaphore(value: 0)
    let cancelEntered = DispatchSemaphore(value: 0)
    let releaseCancel = DispatchSemaphore(value: 0)

    func perform() throws {
        performEntered.signal()
        _ = cancelEntered.wait(timeout: .now() + .seconds(5))
        throw NSError(domain: "BlockingCanceller", code: 1)
    }

    func cancel(_ request: VNRecognizeTextRequest) {
        cancelEntered.signal()
        _ = releaseCancel.wait(timeout: .now() + .seconds(2))
    }
}

/// #706: cancelling a recognition never waits for Vision's cancel to return. On CI the
/// synchronous `request.cancel()` in the cancellation handler blocked the canceller.
@Test(.timeLimit(.minutes(2)))
func issue706CancelDoesNotWaitForVisionCancel() async throws {
    let fake = BlockingCanceller()
    let provider = OnDeviceTextRecognitionProvider(
        performRequest: { _, _ in try fake.perform() },
        cancelRequest: { fake.cancel($0) }
    )
    let bytes = try saturationImage()
    let task = Task { () -> TextRecognitionError? in
        do throws(TextRecognitionError) { _ = try await provider.recognise(bytes); return nil }
        catch { return error }
    }
    await withCheckedContinuation { done in
        DispatchQueue.global().async { fake.performEntered.wait(); done.resume() }
    }
    let started = ContinuousClock.now
    task.cancel()
    let cancelTook = ContinuousClock.now - started
    fake.releaseCancel.signal()

    #expect(cancelTook < .milliseconds(500))
    #expect(await task.value == .cancelled)
}
