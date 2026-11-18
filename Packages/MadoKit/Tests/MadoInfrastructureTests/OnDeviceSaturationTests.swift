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
    private var releases: [ObjectIdentifier: DispatchSemaphore] = [:]
    let deadline: DispatchTimeInterval

    init(deadline: DispatchTimeInterval) { self.deadline = deadline }

    func perform(_ request: VNRecognizeTextRequest) throws {
        lock.lock()
        entered += 1
        let key = ObjectIdentifier(request)
        let release = releases[key] ?? DispatchSemaphore(value: 0)
        releases[key] = release
        lock.unlock()
        if release.wait(timeout: .now() + deadline) == .timedOut {
            lock.lock(); starved += 1; releases.removeValue(forKey: key); lock.unlock()
            throw NSError(domain: "BlockingRecogniser", code: 1)
        }
        lock.lock(); releases.removeValue(forKey: key); lock.unlock()
        throw NSError(domain: "BlockingRecogniser", code: 2)
    }

    func cancel(_ request: VNRecognizeTextRequest) {
        request.cancel()
        lock.lock()
        cancelled += 1
        let key = ObjectIdentifier(request)
        let release = releases[key] ?? DispatchSemaphore(value: 0)
        releases[key] = release
        lock.unlock()
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
        performRequest: { _, request in try recogniser.perform(request) },
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

/// Cancelling an unrelated request must not release a parked perform.
@Test(.timeLimit(.minutes(2)))
func issue706CancelOnlyReleasesItsOwnBlockingRequest() {
    let recogniser = BlockingRecogniser(deadline: .seconds(30))
    let parked = VNRecognizeTextRequest()
    let unrelated = VNRecognizeTextRequest()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { finished.signal() }
        try? recogniser.perform(parked)
    }
    let enteredDeadline = ContinuousClock.now + .seconds(10)
    while recogniser.enteredCount == 0 && ContinuousClock.now < enteredDeadline {
        Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(recogniser.enteredCount == 1)

    recogniser.cancel(unrelated)
    #expect(finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut)

    recogniser.cancel(parked)
    #expect(finished.wait(timeout: .now() + .seconds(10)) == .success)
    #expect(recogniser.starvedCount == 0)
}

/// #749: on CI every cooperative thread stayed busy for over 30 s, so the test could not get
/// back to cancel and release the fake before its perform deadline. Cancelling and releasing
/// must not wait for the test's executor: hold that executor past a short perform deadline.
@available(macOS 15.0, *)
@Test(.timeLimit(.minutes(1)))
func issue749CancelAndReleaseDoNotWaitForTheTestExecutor() async throws {
    let fake = BlockingCanceller(performDeadline: .seconds(1))
    let provider = OnDeviceTextRecognitionProvider(
        performRequest: { _, _ in try fake.perform() },
        cancelRequest: { fake.cancel($0) }
    )
    let bytes = try saturationImage()
    let task = Task { () -> TextRecognitionError? in
        do throws(TextRecognitionError) { _ = try await provider.recognise(bytes); return nil }
        catch { return error }
    }
    let executor = HoldableExecutor()
    let cancelTook = await withTaskExecutorPreference(executor) { () async -> Duration in
        executor.hold(for: 3)
        return await cancelAndRelease(fake, task)
    }

    let result = await task.value
    #expect(cancelTook < .milliseconds(500))
    #expect(!fake.didTimeOut)
    #expect(result == .cancelled)
}

/// The fake's perform can finish even when the asynchronous cancel callback is delayed.
@Test(.timeLimit(.minutes(2)))
func issue706BlockingCancellerPerformDoesNotWaitForCancelCallback() {
    let fake = BlockingCanceller()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        defer { finished.signal() }
        try? fake.perform()
    }
    #expect(fake.performEntered.wait(timeout: .now() + .seconds(10)) == .success)
    fake.releasePerform.signal()
    let completed = finished.wait(timeout: .now() + .seconds(1))
    #expect(completed == .success)
    fake.cancelEntered.signal()
    if completed == .timedOut { _ = finished.wait(timeout: .now() + .seconds(10)) }
    #expect(!fake.didTimeOut)
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
    let cancelTook = await cancelAndRelease(fake, task)

    let result = await task.value
    #expect(cancelTook < .milliseconds(500))
    #expect(!fake.didTimeOut)
    #expect(result == .cancelled)
}

/// #711: cancellation takes precedence even if the request completes with a typed error.
@Test(.timeLimit(.minutes(2)))
func issue711CancelledTaskOverridesTypedRequestError() async throws {
    let fake = BlockingCanceller(throwsTypedError: true)
    let provider = OnDeviceTextRecognitionProvider(
        performRequest: { _, _ in try fake.perform() },
        cancelRequest: { fake.cancel($0) }
    )
    let bytes = try saturationImage()
    let task = Task { () -> TextRecognitionError? in
        do throws(TextRecognitionError) { _ = try await provider.recognise(bytes); return nil }
        catch { return error }
    }
    let cancelTook = await cancelAndRelease(fake, task)

    let result = await task.value
    #expect(cancelTook < .milliseconds(500))
    #expect(!fake.didTimeOut)
    #expect(result == .cancelled)
}
