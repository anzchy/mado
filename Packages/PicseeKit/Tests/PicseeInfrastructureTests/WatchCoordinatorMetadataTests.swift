import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

private final class CountingWatchMetadataReader: FolderMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: Int] = [:]
    func read(_ url: URL) throws -> FolderImageMetadata {
        let bytes = try Data(contentsOf: url).count
        lock.lock(); calls[url.lastPathComponent, default: 0] += 1; lock.unlock()
        return .init(captureDate: Date(timeIntervalSince1970: TimeInterval(bytes)))
    }
    var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return calls }
}

private actor FailNextMetadataScan: FolderScanning {
    private let inner = FolderBrowser()
    private var failNext = false
    func arm() { failNext = true }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        if failNext { failNext = false; throw CocoaError(.fileReadUnknown) }
        try await inner.scan(in: folder, root: root, options: options, emit: emit)
    }
}

@MainActor private final class MetadataWatchFixture {
    let f: WatchFixture
    let rootID: AccessRootID
    let reader: CountingWatchMetadataReader
    let scanner = FailNextMetadataScan()
    let coordinator: FolderScanCoordinator
    init() async throws {
        f = try WatchFixture(folders: ["root/F"])
        rootID = try await f.access.grant(folder: f.url("root"))
        reader = CountingWatchMetadataReader()
        coordinator = FolderScanCoordinator(access: f.access, scanner: scanner, trace: nil,
            metadataReader: reader, watcher: f.hub)
    }
    func write(_ name: String, bytes: Int) throws {
        try Data(repeating: 1, count: bytes).write(to: f.url("root/F/" + name))
    }
    func names() -> [String] { coordinator.snapshot?.entries.map(\.url.lastPathComponent) ?? [] }
    func refresh() async throws { try await #require(coordinator.refresh()).value }
    func close() async throws {
        defer { f.remove() }
        coordinator.end()
        try await waitUntil { self.f.source.active == 0 && self.f.scope.counts[0] == self.f.scope.counts[1] }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue134WatchRefreshKeepsSettledMetadataAndReadsOnlyChangedEntries() async throws {
    let w = try await MetadataWatchFixture()
    try w.write("a.png", bytes: 3); try w.write("b.png", bytes: 1)
    try await w.coordinator.begin(folder: w.f.url("root/F"), rootID: w.rootID).value
    w.coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { w.coordinator.metadataSortState == .complete }
    #expect(w.names() == ["b.png", "a.png"])
    #expect(w.reader.counts == ["a.png": 1, "b.png": 1])

    // Unchanged hint: settled order and per-item reads stay put.
    let before = try #require(w.coordinator.snapshot)
    try await w.refresh()
    #expect(w.coordinator.metadataSortState == .complete)
    #expect(w.coordinator.snapshot == before)
    #expect(w.reader.counts == ["a.png": 1, "b.png": 1])

    // Addition: existing items keep metadata; only the new file is read.
    try w.write("c.png", bytes: 2)
    try await w.refresh()
    try await waitUntil { w.coordinator.metadataSortState == .complete }
    #expect(w.names() == ["b.png", "c.png", "a.png"])
    #expect(w.reader.counts == ["a.png": 1, "b.png": 1, "c.png": 1])

    // Changed bytes invalidate that identity's header alone.
    try w.write("b.png", bytes: 5)
    try await w.refresh()
    try await waitUntil { w.coordinator.metadataSortState == .complete }
    #expect(w.names() == ["c.png", "a.png", "b.png"])
    #expect(w.reader.counts == ["a.png": 1, "b.png": 2, "c.png": 1])

    // Removal never starts metadata work for survivors.
    try FileManager.default.removeItem(at: w.f.url("root/F/a.png"))
    try await w.refresh()
    #expect(w.coordinator.metadataSortState == .complete)
    #expect(w.names() == ["c.png", "b.png"])
    #expect(w.reader.counts == ["a.png": 1, "b.png": 2, "c.png": 1])

    // A failed refresh retains the settled source, sort and metadata work.
    await w.scanner.arm()
    await #expect(throws: CocoaError.self) { try await w.refresh() }
    #expect(w.coordinator.failure != nil)
    #expect(w.coordinator.metadataSortState == .complete)
    #expect(w.names() == ["c.png", "b.png"])
    #expect(w.reader.counts == ["a.png": 1, "b.png": 2, "c.png": 1])
    try await w.close()
}
