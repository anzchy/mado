import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

func expectCancelled(_ subscription: DecodeSubscription) async {
    do { _ = try await subscription.value(); Issue.record("cancelled subscription succeeded") }
    catch { #expect(error is CancellationError) }
}

@Test(.timeLimit(.minutes(2))) func cancellationKeepsRunningReservationsUntilActualReturn() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4), executor: executor, decoder: TinyDecoder())
    let running = await admission.subscribe(tinyRequest, key: decodeKey(10), cost: 4, heavy: true, priority: .current)
    let waiting = await admission.subscribe(tinyRequest, key: decodeKey(11), cost: 4, heavy: true, priority: .current)
    await waiting.cancel(); await waiting.cancel()
    #expect(await admission.activity().waiting == 0)
    await running.cancel(); await running.cancel()
    #expect(await admission.activity().reservedBytes == 4)
    #expect(await admission.activity().running == 1)
    executor.runFirst()
    // Do not await the stub's never-completing cancelled queued delivery on RED.
    if await admission.activity().waiting == 0 { await expectCancelled(waiting) }
    do { _ = try await running.value(); Issue.record("cancelled decode delivered success") }
    catch { #expect(error is CancellationError) }
    #expect(await admission.activity().reservedBytes == 0)
}

final class BlockingDecoder: ImageDecoding, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    let gate = TestGate()
    init() { (started, signal) = AsyncStream.makeStream() }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        signal.yield(())
        gate.wait()
        return try TinyDecoder().decode(request)
    }
}

@Test(.timeLimit(.minutes(2))) func realQueueCancellationBalancesThreePointsWithoutSleep() async throws {
    let decoder = BlockingDecoder()
    defer { decoder.gate.open() }
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4),
        executor: OperationDecodeExecutor(workers: 1), decoder: decoder)
    let running = await admission.subscribe(tinyRequest, key: decodeKey(20), cost: 4, heavy: true, priority: .current)
    var starts = decoder.started.makeAsyncIterator()
    _ = await starts.next()
    let queued = await admission.subscribe(tinyRequest, key: decodeKey(21), cost: 4, heavy: true, priority: .current)
    await queued.cancel()
    await running.cancel()
    #expect(await admission.activity().reservedBytes == 4)
    #expect(await admission.activity().waiting == 0)
    decoder.gate.signal()
    if await admission.activity().waiting == 0 { await expectCancelled(queued) }
    await expectCancelled(running)
    #expect(await admission.activity().running == 0)
}

@Test(.timeLimit(.minutes(2))) func submittedPixelCancellationSkipsDecoderAndBalancesResources() async throws {
    let executor = OperationDecodeExecutor(workers: 1)
    let (blocked, signalBlocked) = AsyncStream<Void>.makeStream()
    let release = TestGate()
    defer { release.open() }
    executor.submit { signalBlocked.yield(()); release.wait() }
    var blocker = blocked.makeAsyncIterator()
    _ = await blocker.next()
    let decoder = DecodeCounter()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4),
                                    executor: executor, decoder: decoder)
    // subscribe returns only after submission. The sole real worker is still blocked.
    let queued = await admission.subscribe(tinyRequest, key: decodeKey(80), cost: 4, heavy: true, priority: .current)
    #expect(await admission.activity().running == 1)
    #expect(await admission.activity().waiting == 0)
    let (registered, signalRegistered) = AsyncStream<Void>.makeStream()
    let waiter = Task {
        try await queued.delivery.value(onRegistration: { signalRegistered.yield(()) })
    }
    var registration = registered.makeAsyncIterator()
    _ = await registration.next()
    await queued.cancel(); await queued.cancel()
    #expect(decoder.count == 0)
    #expect(await admission.activity().reservedBytes == 4)
    release.signal()
    var completions = 0
    do { _ = try await waiter.value; Issue.record("queued cancellation delivered success") }
    catch { completions += 1; #expect(error is CancellationError) }
    #expect(completions == 1)
    #expect(decoder.count == 0)
    #expect(await admission.activity().reservedBytes == 0)
    #expect(await admission.activity().running == 0)
    #expect(await admission.activity().heavy == 0)
}

@Test(.timeLimit(.minutes(2))) func freshAdmittedCancellationSkipsDecoderAndReleasesReservation() async throws {
    let executor = ControlledExecutor()
    let decoder = DecodeCounter()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4),
                                    executor: executor, decoder: decoder)
    let fresh = await admission.subscribe(tinyRequest, key: decodeKey(1073), cost: 4,
                                          heavy: true, priority: .current, reuseExisting: false)
    #expect(executor.count == 1)
    #expect(await admission.activity().running == 1)
    #expect(await admission.activity().reservedBytes == 4)

    await fresh.cancel()
    #expect(await admission.activity().reservedBytes == 4)
    executor.runFirst()
    await expectCancelled(fresh)
    #expect(decoder.count == 0)
    #expect(await admission.activity().running == 0)
    #expect(await admission.activity().reservedBytes == 0)
}
