import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func cancelledBeforeRegistrationNeverSubmitsWork() async {
    for realQueue in [false, true] {
        let controlled = ControlledExecutor()
        let executor: any DecodeExecuting = realQueue ? OperationDecodeExecutor(workers: 1) : controlled
        let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1), executor: executor, decoder: TinyDecoder())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await admission.image(tinyRequest, key: decodeKey(40), cost: 4, heavy: false, priority: .current)
        }
        do { _ = try await task.value; Issue.record("cancel before registration succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(await admission.activity().running == 0)
        #expect(await admission.activity().waiting == 0)
        #expect(controlled.count == 0)
    }
    let pipeline = ImageIOPipeline()
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await pipeline.image(for: tinyRequest)
    }
    do { _ = try await task.value; Issue.record("pre-cancelled pipeline succeeded") }
    catch { #expect((error as? ImageLoadError)?.kind == .cancelled) }
}

@Test(.timeLimit(.minutes(2))) func taskCancellationResumesOnceAfterBlockingDecoderReturns() async throws {
    let decoder = BlockingDecoder()
    defer { decoder.gate.open() }
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4),
        executor: OperationDecodeExecutor(workers: 1), decoder: decoder)
    let task = Task { try await admission.image(tinyRequest, key: decodeKey(41), cost: 4, heavy: true, priority: .current) }
    var iterator = decoder.started.makeAsyncIterator()
    _ = await iterator.next()
    task.cancel()
    #expect(await admission.activity().reservedBytes == 4)
    decoder.gate.signal()
    var resumes = 0
    do { _ = try await task.value; Issue.record("cancelled task succeeded") }
    catch { resumes += 1; #expect(error is CancellationError) }
    #expect(resumes == 1)
    #expect(await admission.activity().running == 0)
}

private struct FailingDecoder: ImageDecoding {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage { throw ImageDecodeError.unreadableImage }
}
@Test(.timeLimit(.minutes(2))) func failureReleasesPermitsAndFinishesAllConsumersOnce() async {
    for realQueue in [false, true] {
        let controlled = ControlledExecutor()
        let executor: any DecodeExecuting = realQueue ? OperationDecodeExecutor(workers: 1) : controlled
        let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4), executor: executor, decoder: FailingDecoder())
        let a = await admission.subscribe(tinyRequest, key: decodeKey(42), cost: 4, heavy: true, priority: .current)
        if !realQueue { controlled.runFirst() }
        var resumes = 0
        do { _ = try await a.value(); Issue.record("failed decoder succeeded") }
        catch { resumes += 1; #expect(error as? ImageDecodeError == .unreadableImage) }
        #expect(resumes == 1)
        #expect(await admission.activity().reservedBytes == 0)
        await a.cancel() // late cancellation is harmless
        await a.raisePriority(to: .current)
    }
}

@Test(.timeLimit(.minutes(2))) func preparedRequestsShareIdentityAndRejectChangedRevisions() async throws {
    let pipeline = ImageIOPipeline()
    let file = fixture("orientation-1.tiff")
    let a = try await pipeline.request(for: file, maximumPixelSize: 128)
    let b = try await pipeline.request(for: file, maximumPixelSize: 128)
    #expect(a.renderKey == b.renderKey)
    #expect(try await pipeline.image(for: a).image.width == 128)
    let key = try #require(a.renderKey)
    let changed = RenderKey(itemID: key.itemID, revision: FileRevision(byteCount: 0, modificationDate: nil), maximumPixelSize: 128)
    await #expect(performing: {
        try await pipeline.image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 128, renderKey: changed))
    }, throws: loadError(.sourceChanged))
    // These errors must also be typed at the synchronous decoder boundary.
    #expect(throws: ImageDecodeError.invalidRequest) { try ImageIODecoder().decode(ImageDecodeRequest(fileURL: file, maximumPixelSize: 0)) }
    #expect(throws: ImageDecodeError.unreadableImage) { try ImageIODecoder().decode(ImageDecodeRequest(fileURL: fixture("corrupt.png"), maximumPixelSize: 1)) }
}

@Test(.timeLimit(.minutes(2))) func eligibleVisibleWorkPrecedesPrefetchAndCurrentWorkCanUseAllSlots() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 2, visible: 1, budget: 8), executor: executor, decoder: TinyDecoder())
    let first = await admission.subscribe(tinyRequest, key: decodeKey(50), cost: 4, heavy: false, priority: .current)
    let secondWindow = await admission.subscribe(tinyRequest, key: decodeKey(51), cost: 4, heavy: false, priority: .current)
    let prefetch = await admission.subscribe(tinyRequest, key: decodeKey(52), cost: 4, heavy: false, priority: .prefetch)
    let visible = await admission.subscribe(tinyRequest, key: decodeKey(53), cost: 4, heavy: false, priority: .visible)
    #expect(await admission.activity().running == 2)
    executor.runFirst(); _ = try await first.value()
    #expect(await admission.activity().visible == 1)
    executor.runFirst(); _ = try await secondWindow.value()
    // The remaining slot stays reserved for current work, not filled by prefetch.
    #expect(await admission.activity().waiting == 1)
    executor.runFirst(); _ = try await visible.value()
    #expect(await admission.activity().waiting == 0)
    executor.runFirst(); _ = try await prefetch.value()
    #expect(await admission.activity().running == 0)
}

@Test(.timeLimit(.minutes(2))) func controlledExecutorMidDecodeCancellationWaitsForRealReturn() async throws {
    let executor = ControlledExecutor()
    let decoder = BlockingDecoder()
    defer { decoder.gate.open() }
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4), executor: executor, decoder: decoder)
    let consumer = await admission.subscribe(tinyRequest, key: decodeKey(60), cost: 4, heavy: true, priority: .current)
    // The fake controls dispatch; the decoder controls its real return independently.
    DispatchQueue.global().async { executor.runFirst() }
    var iterator = decoder.started.makeAsyncIterator()
    _ = await iterator.next()
    await consumer.cancel()
    #expect(await admission.activity().reservedBytes == 4)
    #expect(await admission.activity().running == 1)
    decoder.gate.signal()
    var resumes = 0
    do { _ = try await consumer.value(); Issue.record("cancelled decode succeeded") }
    catch { resumes += 1; #expect(error is CancellationError) }
    #expect(resumes == 1)
    #expect(await admission.activity().running == 0)
}

@Test(.timeLimit(.minutes(2))) func cancellingAllQueuedConsumersAllowsSameKeyToBeRegisteredAgain() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4), executor: executor, decoder: TinyDecoder())
    let current = await admission.subscribe(tinyRequest, key: decodeKey(61), cost: 4, heavy: true, priority: .current)
    let a = await admission.subscribe(tinyRequest, key: decodeKey(62), cost: 4, heavy: true, priority: .visible)
    let b = await admission.subscribe(tinyRequest, key: decodeKey(62), cost: 4, heavy: true, priority: .current)
    await a.cancel(); await expectCancelled(a)
    await b.cancel(); await expectCancelled(b)
    #expect(await admission.activity().waiting == 0)
    let replacement = await admission.subscribe(tinyRequest, key: decodeKey(62), cost: 4, heavy: true, priority: .current)
    executor.runFirst(); _ = try await current.value()
    executor.runFirst(); _ = try await replacement.value()
    #expect(await admission.activity().reservedBytes == 0)
}

@Test(.timeLimit(.minutes(2))) func unavailableBytesDoNotTakeSlotsAndPendingPromotionDoesNotDuplicateWork() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 3, budget: 8), executor: executor, decoder: TinyDecoder())
    let a = await admission.subscribe(tinyRequest, key: decodeKey(70), cost: 8, heavy: false, priority: .current)
    let visible = await admission.subscribe(tinyRequest, key: decodeKey(71), cost: 4, heavy: false, priority: .visible)
    let current = await admission.subscribe(tinyRequest, key: decodeKey(72), cost: 4, heavy: false, priority: .current)
    #expect(await admission.activity().running == 1)
    #expect(await admission.activity().reservedBytes == 8)
    #expect(await admission.activity().waiting == 2)
    await a.cancel()
    #expect(await admission.activity().running == 1)
    executor.runFirst(); await expectCancelled(a)
    #expect(await admission.activity().running == 2)
    #expect(await admission.activity().visible == 1)
    executor.runFirst(); _ = try await current.value()
    executor.runFirst(); _ = try await visible.value()

    let serialExecutor = ControlledExecutor()
    let serial = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4), executor: serialExecutor, decoder: TinyDecoder())
    let first = await serial.subscribe(tinyRequest, key: decodeKey(73), cost: 4, heavy: false, priority: .current)
    let shared = await serial.subscribe(tinyRequest, key: decodeKey(74), cost: 4, heavy: false, priority: .prefetch)
    let joined = await serial.subscribe(tinyRequest, key: decodeKey(74), cost: 4, heavy: false, priority: .visible)
    await shared.raisePriority(to: .current)
    #expect(await serial.activity().waiting == 1)
    serialExecutor.runFirst(); _ = try await first.value()
    #expect(serialExecutor.count == 1)
    #expect(await serial.activity().nonCurrent == 0)
    serialExecutor.runFirst(); _ = try await shared.value(); _ = try await joined.value()
    #expect(await serial.activity().running == 0)

}

@Test func directDecoderUsesItsDefaultSourceBudget() throws {
    let decoded = try ImageIODecoder().decode(ImageDecodeRequest(fileURL: fixture("orientation-1.tiff"), maximumPixelSize: 128))
    #expect(decoded.image.width == 128 && decoded.image.height == 96)
}

private final class SubmissionHandshake: DecodeExecuting, Sendable {
    let controlled = ControlledExecutor()
    let submitted: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    init() { (submitted, signal) = AsyncStream.makeStream() }
    func submit(_ work: @escaping @Sendable () -> Void) {
        controlled.submit(work)
        signal.yield(())
    }
}
@Test(.timeLimit(.minutes(2))) func cancellationAfterCompletionWinsStillRejectsDeliveredSuccess() async throws {
    let executor = SubmissionHandshake()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4),
                                    executor: executor, decoder: TinyDecoder())
    let (completed, signalCompleted) = AsyncStream<Void>.makeStream()
    let (release, signalRelease) = AsyncStream<Void>.makeStream()
    await admission.setCompletionBarrier {
        signalCompleted.yield(())
        var gate = release.makeAsyncIterator()
        _ = await gate.next()
    }
    let task = Task { try await admission.image(tinyRequest, key: decodeKey(81), cost: 4, heavy: false, priority: .current) }
    var submitted = executor.submitted.makeAsyncIterator()
    _ = await submitted.next()
    executor.controlled.runFirst()
    var completion = completed.makeAsyncIterator()
    _ = await completion.next()
    // Completion already won: the job and resources are gone. The cancellation
    // message cannot mark that finished job; the consumer must recheck its Task.
    #expect(await admission.activity().running == 0)
    task.cancel()
    signalRelease.yield(())
    var completions = 0
    do { _ = try await task.value; completions += 1; Issue.record("cancelled task accepted delivered success") }
    catch { completions += 1; #expect(error is CancellationError) }
    #expect(completions == 1)
    #expect(await admission.activity().reservedBytes == 0)
}
