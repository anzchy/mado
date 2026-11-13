import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor HeldInspectorReader: InspectorMetadataReading {
    private var waits: [String: CheckedContinuation<InspectorMetadata, Error>] = [:]
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        try await withCheckedThrowingContinuation { waits[url.lastPathComponent] = $0 }
    }
    func release(_ name: String, result: Result<InspectorMetadata, Error>) {
        waits.removeValue(forKey: name)?.resume(with: result)
    }
    func hasWait(_ name: String) -> Bool { waits[name] != nil }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136InspectorRejectsLateOldItemAndClearsValuesImmediately() async throws {
    let reader = HeldInspectorReader()
    let model = InspectorModel(reader: reader)
    let first = URL(fileURLWithPath: "/tmp/first.png"), second = URL(fileURLWithPath: "/tmp/second.jpg")
    model.select(itemID: nil, url: first, access: .fileGrant(first))
    await Task.yield()
    #expect(model.name == "first.png")
    #expect(model.value == .loading)
    model.select(itemID: nil, url: second, access: .fileGrant(second))
    #expect(model.name == "second.jpg")
    #expect(model.value == .loading)
    await Task.yield()
    await reader.release("first.png", result: .success(.init(pixelWidth: 100, pixelHeight: 200)))
    await Task.yield()
    #expect(model.value == .loading)
    await reader.release("second.jpg", result: .success(.init(pixelWidth: 300, pixelHeight: 400)))
    try await waitUntil { model.value != .loading }
    #expect(model.value == .known(.init(pixelWidth: 300, pixelHeight: 400)))
    model.select(itemID: nil, url: nil, access: nil)
    #expect(model.name == nil)
    #expect(model.value == .unknown)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136InspectorDistinguishesNoPermissionAndUnreadable() async throws {
    let reader = HeldInspectorReader(), model = InspectorModel(reader: reader)
    let url = URL(fileURLWithPath: "/tmp/a.jpg")
    model.select(itemID: nil, url: url, access: .fileGrant(url))
    await Task.yield()
    await reader.release("a.jpg", result: .failure(InspectorReadError.noPermission))
    try await waitUntil { model.value != .loading }
    #expect(model.value == .noPermission)
    model.select(itemID: nil, url: url, access: .fileGrant(url), refresh: true)
    await Task.yield()
    await reader.release("a.jpg", result: .failure(InspectorReadError.unreadable))
    try await waitUntil { model.value != .loading }
    #expect(model.value == .unreadable)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136InspectorRefreshesSameURLWhenRevisionChanges() async throws {
    let reader = HeldInspectorReader(), model = InspectorModel(reader: reader)
    let url = URL(fileURLWithPath: "/tmp/revised.png")
    model.select(itemID: nil, url: url, access: .fileGrant(url), revision: "first")
    await Task.yield()
    await reader.release("revised.png", result: .success(.init(pixelWidth: 100)))
    try await waitUntil { model.value != .loading }
    #expect(model.value == .known(.init(pixelWidth: 100)))
    model.select(itemID: nil, url: url, access: .fileGrant(url), revision: "second")
    #expect(model.value == .loading)
    await Task.yield()
    await reader.release("revised.png", result: .success(.init(pixelWidth: 200)))
    try await waitUntil { model.value != .loading }
    #expect(model.value == .known(.init(pixelWidth: 200)))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136GridCurrentItemCanOpenInspectorAndEscapeRestoresCanvas() {
    let host = FakeSessionHost(), session = ViewerSession(host: host)
    let first = ItemID.rootRelative(rootID: AccessRootID(), relativePath: "one.png")
    session.beginBrowsing(items: [first], sourceVersion: .init(1), scrollAnchor: first)
    session.focus(first)
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    #expect(router.route(.inspector, from: .key, to: session))
    #expect(session.inspectorFocus.isVisible)
    session.tab(reverse: false)
    #expect(session.inspectorFocus.focus == .textInput)
    #expect(router.route(.escape, from: .key, to: session))
    #expect(session.inspectorFocus.focus == .canvas)
    #expect(session.inspectorFocus.isVisible)
}
