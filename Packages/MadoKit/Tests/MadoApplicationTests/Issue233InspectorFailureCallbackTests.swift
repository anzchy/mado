import Foundation
import Testing
import MadoCore
import MadoApplication

@MainActor private func r2CallbackWait(
    fileID: String = #fileID, line: Int = #line, _ condition: @MainActor () async -> Bool
) async throws {
    try await waitUntil(fileID: fileID, line: line) { await condition() }
}

private actor R2CallbackReader: InspectorMetadataReading {
    private var gates: [String: CheckedContinuation<InspectorMetadata, any Error>] = [:]
    private var finished: [String: Int] = [:]
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        defer { finished[url.lastPathComponent, default: 0] += 1 }
        return try await withCheckedThrowingContinuation { gates[url.lastPathComponent] = $0 }
    }
    func held(_ name: String) -> Bool { gates[name] != nil }
    func completed(_ name: String) -> Int { finished[name, default: 0] }
    func release(_ name: String, _ result: Result<InspectorMetadata, any Error>) { gates.removeValue(forKey: name)?.resume(with: result) }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue233R2InspectorCurrentFailureCallbackFollowsMappedStateAndIsOptional() async throws {
    let reader = R2CallbackReader(), model = InspectorModel(reader: reader)
    let url = URL(fileURLWithPath: "/tmp/r2-current.png")
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    try await r2CallbackWait { await reader.held(url.lastPathComponent) }
    await reader.release(url.lastPathComponent, .failure(InspectorReadError.noPermission))
    try await r2CallbackWait { model.value != .loading }
    #expect(model.value == .noPermission)
    #expect(model.name == url.lastPathComponent)
    var delivered: [(URL, AccessRequest, InspectorReadError?, InspectorValue)] = []
    model.onReadFailure = { file, access, error in delivered.append((file, access, error as? InspectorReadError, model.value)) }
    defer { model.onReadFailure = nil }
    for error in [InspectorReadError.noPermission, .unreadable] {
        model.select(itemID: nil, url: url, access: .fileGrant(url), refresh: true)
        try await r2CallbackWait { await reader.held(url.lastPathComponent) }
        await reader.release(url.lastPathComponent, .failure(error))
        try await r2CallbackWait { model.value != .loading }
        #expect(model.value == (error == .noPermission ? .noPermission : .unreadable))
        #expect(delivered.last?.0 == url)
        #expect(delivered.last?.1 == .fileGrant(url))
        #expect(delivered.last?.2 == error)
        #expect(delivered.last?.3 == model.value)
    }
    #expect(delivered.count == 2)
    model.select(itemID: nil, url: url, access: .fileGrant(url), refresh: true)
    try await r2CallbackWait { await reader.held(url.lastPathComponent) }
    let metadata = InspectorMetadata(pixelWidth: 600, pixelHeight: 400)
    await reader.release(url.lastPathComponent, .success(metadata))
    try await r2CallbackWait { model.value != .loading }
    #expect(model.value == .known(metadata))
    #expect(delivered.count == 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue233R2InspectorOldFailureAfterClearAndReplacementCannotReport() async throws {
    let reader = R2CallbackReader(), model = InspectorModel(reader: reader)
    let a = URL(fileURLWithPath: "/tmp/r2-old.png"), b = URL(fileURLWithPath: "/tmp/r2-new.png")
    var delivered: [URL] = []
    model.onReadFailure = { file, _, _ in delivered.append(file) }
    defer { model.onReadFailure = nil }
    model.select(itemID: nil, url: a, access: .fileGrant(a))
    try await r2CallbackWait { await reader.held(a.lastPathComponent) }
    model.select(itemID: nil, url: nil, access: nil)
    await reader.release(a.lastPathComponent, .failure(InspectorReadError.noPermission))
    try await r2CallbackWait { await reader.completed(a.lastPathComponent) > 0 }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.name == nil)
    #expect(model.value == .unknown)
    #expect(delivered.isEmpty)
    let oldCompletions = await reader.completed(a.lastPathComponent)
    model.select(itemID: nil, url: a, access: .fileGrant(a))
    try await r2CallbackWait { await reader.held(a.lastPathComponent) }
    model.select(itemID: nil, url: b, access: .fileGrant(b))
    try await r2CallbackWait { await reader.held(b.lastPathComponent) }
    let metadata = InspectorMetadata(pixelWidth: 200, pixelHeight: 300)
    await reader.release(b.lastPathComponent, .success(metadata))
    try await r2CallbackWait { model.value == .known(metadata) }
    await reader.release(a.lastPathComponent, .failure(InspectorReadError.unreadable))
    try await r2CallbackWait { await reader.completed(a.lastPathComponent) > oldCompletions }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.name == b.lastPathComponent)
    #expect(model.value == .known(metadata))
    #expect(delivered.isEmpty)
    model.select(itemID: nil, url: b, access: .fileGrant(b), refresh: true)
    try await r2CallbackWait { await reader.held(b.lastPathComponent) }
    await reader.release(b.lastPathComponent, .failure(InspectorReadError.unreadable))
    try await r2CallbackWait { model.value == .unreadable }
    #expect(delivered == [b])
}

private actor R2CancellationCompletion {
    var completed = false
    func finish() { completed = true }
}
private struct R2CancelledReader: InspectorMetadataReading {
    let completion: R2CancellationCompletion
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        withUnsafeCurrentTask { $0?.cancel() }
        await completion.finish()
        throw InspectorReadError.unreadable
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue233R2InspectorCancelledCurrentReadCannotMapOrReport() async throws {
    let completion = R2CancellationCompletion()
    let model = InspectorModel(reader: R2CancelledReader(completion: completion))
    let url = URL(fileURLWithPath: "/tmp/r2-cancel.png")
    var reports = 0
    model.onReadFailure = { _, _, _ in reports += 1 }
    defer { model.onReadFailure = nil }
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    try await r2CallbackWait { await completion.completed }
    try? await Task.sleep(for: .milliseconds(20))
    #expect(model.name == url.lastPathComponent)
    #expect(model.value == .loading)
    #expect(reports == 0)
    model.select(itemID: nil, url: nil, access: nil)
    #expect(model.value == .unknown)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue233R2InspectorFailureCallbackCanSynchronouslyClearWithoutRepaint() async throws {
    let reader = R2CallbackReader(), model = InspectorModel(reader: reader)
    let url = URL(fileURLWithPath: "/tmp/r2-reentrant.png")
    var observed: InspectorValue?
    model.onReadFailure = { _, _, _ in
        observed = model.value
        model.select(itemID: nil, url: nil, access: nil)
    }
    defer { model.onReadFailure = nil }
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    try await r2CallbackWait { await reader.held(url.lastPathComponent) }
    await reader.release(url.lastPathComponent, .failure(InspectorReadError.noPermission))
    try await r2CallbackWait { observed != nil }
    #expect(observed == .noPermission)
    #expect(model.name == nil)
    #expect(model.value == .unknown)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue233R2InspectorSnapshotsFailureCallbackForEachRead() async throws {
    let reader = R2CallbackReader(), model = InspectorModel(reader: reader)
    let url = URL(fileURLWithPath: "/tmp/r2-snapshot.png")
    var oldReadStates: [InspectorValue] = [], newReadStates: [InspectorValue] = []
    model.onReadFailure = { _, _, _ in oldReadStates.append(model.value) }
    defer { model.onReadFailure = nil }
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    try await r2CallbackWait { await reader.held(url.lastPathComponent) }
    model.onReadFailure = { _, _, _ in newReadStates.append(model.value) }
    await reader.release(url.lastPathComponent, .failure(InspectorReadError.noPermission))
    try await r2CallbackWait { model.value == .noPermission }
    #expect(oldReadStates == [.noPermission])
    #expect(newReadStates.isEmpty)
    model.select(itemID: nil, url: url, access: .fileGrant(url), refresh: true)
    try await r2CallbackWait { await reader.held(url.lastPathComponent) }
    await reader.release(url.lastPathComponent, .failure(InspectorReadError.unreadable))
    try await r2CallbackWait { model.value == .unreadable }
    #expect(oldReadStates == [.noPermission])
    #expect(newReadStates == [.unreadable])
}
