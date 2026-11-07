import Testing
import MadoInfrastructure

@Test func sharedDecodeKeepsConsumersIndependentAndCleanupMatchesTask() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 1, budget: 4), executor: executor, decoder: TinyDecoder())
    let a = await admission.subscribe(tinyRequest, key: decodeKey(30), cost: 4, heavy: false, priority: .current)
    let b = await admission.subscribe(tinyRequest, key: decodeKey(30), cost: 4, heavy: false, priority: .visible)
    await b.raisePriority(to: .current)
    #expect(await admission.activity().waiting == 0)
    await a.cancel()
    executor.runFirst()
    // With no dedup the queued b can be driven too, so RED completes normally.
    await expectCancelled(a)
    if executor.count > 0 { executor.runFirst() }
    #expect(try await b.value().image.width == 1)
    #expect(await admission.activity().running == 0)

    let old = await admission.subscribe(tinyRequest, key: decodeKey(31), cost: 4, heavy: false, priority: .current)
    await old.cancel()
    let replacement = await admission.subscribe(tinyRequest, key: decodeKey(31), cost: 4, heavy: false, priority: .current)
    #expect(await admission.activity().waiting == 1)
    executor.runFirst(); await expectCancelled(old)
    let joined = await admission.subscribe(tinyRequest, key: decodeKey(31), cost: 4, heavy: false, priority: .current)
    #expect(await admission.activity().waiting == 0)
    executor.runFirst(); _ = try await replacement.value()
    if executor.count > 0 { executor.runFirst() }
    _ = try await joined.value()
    #expect(await admission.activity().reservedBytes == 0)
}

@Test func replacementNeverDecodesConcurrentlyWithCancelledTaskForSameKey() async throws {
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 3, budget: 12), executor: executor, decoder: TinyDecoder())
    let old = await admission.subscribe(tinyRequest, key: decodeKey(32), cost: 4, heavy: false, priority: .current)
    await old.cancel()
    let replacement = await admission.subscribe(tinyRequest, key: decodeKey(32), cost: 4, heavy: false, priority: .current)
    #expect(executor.count == 1)
    #expect(await admission.activity().waiting == 1)
    executor.runFirst(); await expectCancelled(old)
    #expect(executor.count == 1)
    executor.runFirst(); _ = try await replacement.value()
    #expect(await admission.activity().running == 0)
}
