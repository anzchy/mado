import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

/// Pressure time that moves only when the test advances it; each sleep wakes once the clock reaches its end.
private final class SteppedPressureTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var sleepers: [(id: UUID, until: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = []
    private var asked: [TimeInterval] = []
    var now: TimeInterval { lock.withLock { current } }
    var requested: [TimeInterval] { lock.withLock { asked } }
    var sleeping: Int { lock.withLock { sleepers.count } }
    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = lock.withLock {
                    asked.append(seconds)
                    if Task.isCancelled { return true }
                    sleepers.append((id, current + seconds, continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index).continuation
            }
            sleeper?.resume(throwing: CancellationError())
        }
    }
    func advance(by seconds: TimeInterval) {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            current += seconds
            let due = sleepers.filter { $0.until <= current }
            sleepers.removeAll { $0.until <= current }
            return due.map(\.continuation)
        }
        for sleeper in woken { sleeper.resume() }
    }
    /// True once `count` sleeps have been asked for and are pending; throws when the bounded wait ends first (#392).
    func waitFor(asked count: Int) async throws -> Bool {
        try await waitUntil { requested.count == count && sleeping == 1 }
        return requested.count == count && sleeping == 1
    }
}

@Suite(.timeLimit(.minutes(1))) struct PrefetchResumptionTests {
    private static func pipeline(_ time: SteppedPressureTime, delay: TimeInterval = 5) -> ImageIOPipeline {
        ImageIOPipeline(configuration: DecodeConfiguration(pressureRecoveryDelay: delay),
            pressureClock: { time.now }, pressureSleep: { try await time.sleep($0) })
    }

    // R1 1.4: the wait polls while pressure lasts, then sleeps only what is left of the recovery delay.
    @Test func pipelinePrefetchResumptionWaitsOutPressureAndTheRecoveryDelay() async throws {
        let time = SteppedPressureTime(), pipeline = Self.pipeline(time)
        await pipeline.memoryPressure(.warning)
        let waiting = Task { await pipeline.prefetchResumes() }
        #expect(try await time.waitFor(asked: 1))
        time.advance(by: 5)
        #expect(try await time.waitFor(asked: 2))
        time.advance(by: 1)
        await pipeline.memoryPressure(.normal)
        time.advance(by: 4)
        #expect(try await time.waitFor(asked: 3))
        #expect(await !pipeline.cache.permits(.prefetch))
        time.advance(by: 1)
        await waiting.value
        #expect(time.requested == [5, 5, 1])
        #expect(await pipeline.cache.permits(.prefetch))
    }

    // R1 1.4c: with prefetch already permitted the wait returns without sleeping; a zero delay still polls pressure.
    @Test func pipelinePrefetchResumptionReturnsAtOnceWhenPermitted() async throws {
        let time = SteppedPressureTime(), pipeline = Self.pipeline(time, delay: 0)
        await pipeline.prefetchResumes()
        #expect(time.requested.isEmpty)
        await pipeline.memoryPressure(.critical)
        let waiting = Task { await pipeline.prefetchResumes() }
        #expect(try await time.waitFor(asked: 1))
        #expect(time.requested == [1])
        await pipeline.memoryPressure(.normal)
        time.advance(by: 1)
        await waiting.value
        #expect(time.requested == [1])
    }

    // #673: the injected clock owns both the recovery deadline and the pending sleep.
    @Test func pipelinePrefetchResumptionStaysBlockedUntilInjectedDeadline() async throws {
        let time = SteppedPressureTime(), pipeline = Self.pipeline(time)
        await pipeline.memoryPressure(.warning)
        await pipeline.memoryPressure(.normal)
        let waiting = Task { await pipeline.prefetchResumes() }
        #expect(try await time.waitFor(asked: 1))
        time.advance(by: 4.999)
        #expect(await !pipeline.cache.permits(.prefetch))
        #expect(time.sleeping == 1)
        time.advance(by: 0.001)
        await waiting.value
        #expect(time.requested == [5])
        #expect(await pipeline.cache.permits(.prefetch))
    }

    // R1 1.4d: a cancelled wait returns and stops sleeping.
    @Test func pipelinePrefetchResumptionStopsWhenCancelled() async throws {
        let time = SteppedPressureTime(), pipeline = Self.pipeline(time)
        await pipeline.memoryPressure(.warning)
        let waiting = Task { await pipeline.prefetchResumes() }
        #expect(try await time.waitFor(asked: 1))
        waiting.cancel()
        await waiting.value
        for _ in 0..<20 { await Task.yield() }
        #expect(time.requested == [5])
        #expect(time.sleeping == 0)
    }
}

@Suite(.timeLimit(.minutes(2))) struct PrefetchDefaultClockTests {
    // R1 1.4e: the default sleep waits on the real clock for a short recovery delay.
    @Test func pipelinePrefetchResumptionUsesTheRealClockByDefault() async throws {
        let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(pressureRecoveryDelay: 0.05))
        await pipeline.memoryPressure(.warning)
        await pipeline.memoryPressure(.normal)
        #expect(await !pipeline.cache.permits(.prefetch))
        await pipeline.prefetchResumes()
        #expect(await pipeline.cache.permits(.prefetch))
    }
}
