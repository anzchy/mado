import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

// #904: the #890 cancellation test sampled Stub890.stopCount once, but URLSession delivers stopLoading
// asynchronously after the cancel. These pin the wait that replaced the sample, with the stop made late on purpose.
// They live in the serialized Issue890TransportTests, which owns Stub890's shared state.

extension Issue890TransportTests {
    /// Starts a hanging table run and waits for its load; the caller set the stub.
    private func startHanging904() async throws -> Task<TableRecognitionResult, Never> {
        let service = tableService890()
        let image = try png890(width: 3, height: 2)
        let task = Task { await service.recognise(image) }
        try await awaitLoads890(1)
        try #require(Stub890.requests.count == 1)
        return task
    }

    /// Cancels `task` and returns its result, ending the hung load as the network would.
    private func cancel904(_ task: Task<TableRecognitionResult, Never>) async -> TableRecognitionResult {
        task.cancel()
        let result = await task.value
        Stub890.failHung(URLError(.timedOut))
        return result
    }

    @Test(.timeLimit(.minutes(2)))
    func issue904DelayedStopIsAwaitedNotSampled() async throws {
        Stub890.reset([.hang], stops: .after(1.0))
        let result = await cancel904(try await startHanging904())
        #expect(result == .cancelled)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(try await stopReached { Stub890.stopCount })
        // It answers once the stop lands, well inside its 10-second bound.
        #expect(clock.now - started < .seconds(5))
        #expect(Stub890.stopCount == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue904StopThatNeverArrivesFailsTheCheck() async throws {
        Stub890.reset([.hang], stops: .never)
        #expect(await cancel904(try await startHanging904()) == .cancelled)
        try await waitUntil("stopLoading called") { Stub890.stopCalls >= 1 }
        let clock = ContinuousClock()
        let started = clock.now
        #expect(try await stopReached(within: .milliseconds(300)) { Stub890.stopCount } == false)
        // Its own bound ended the wait, not the test's time limit.
        let waited = clock.now - started
        #expect(waited >= .milliseconds(300))
        #expect(waited < .seconds(3))
    }

    @Test(.timeLimit(.minutes(2)))
    func issue904LateStopFromAnEarlierResetIsNotCounted() async throws {
        Stub890.reset([.hang], stops: .after(0.3))
        #expect(await cancel904(try await startHanging904()) == .cancelled)
        try await waitUntil("stopLoading called") { Stub890.stopCalls >= 1 }
        Stub890.reset([], stops: .after(0.3))
        try await Task.sleep(for: .milliseconds(700))
        #expect(Stub890.stopCount == 0)
    }

    @Test(.timeLimit(.minutes(2)))
    func issue904StopCalledAfterTheNextResetIsNotCounted() async throws {
        Stub890.reset([.hang])
        let task = try await startHanging904()
        Stub890.reset([])
        task.cancel()
        #expect(await task.value == .cancelled)
        try await waitUntil("stopLoading called") { Stub890.stopCalls >= 1 }
        #expect(Stub890.stopCount == 0)
    }
}
