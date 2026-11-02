import Foundation
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeInfrastructure

private actor HeldRefreshMetadataScanner: FolderScanning {
    private let inner = FolderBrowser()
    private var scans = 0
    private var refreshStarted = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func waitForRefresh() async {
        if refreshStarted { return }
        await withCheckedContinuation { startWaiter = $0 }
    }
    func releaseRefresh() { releaseWaiter?.resume(); releaseWaiter = nil }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
        emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        scans += 1
        if scans == 2 {
            refreshStarted = true
            startWaiter?.resume(); startWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        try await inner.scan(in: folder, root: root, options: options, emit: emit)
    }
}

private final class HeldConditionMetadataReader: FolderMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirstA = DispatchSemaphore(value: 0)
    private var calls: [String: Int] = [:]
    private var active = 0
    private var peak = 0
    func read(_ url: URL) throws -> FolderImageMetadata {
        let name = url.lastPathComponent
        lock.lock()
        calls[name, default: 0] += 1
        let attempt = calls[name, default: 0]
        active += 1; peak = max(peak, active)
        lock.unlock()
        if name == "a.png" && attempt == 1 { releaseFirstA.wait() }
        lock.lock(); active -= 1; lock.unlock()
        let seconds: TimeInterval = name == "a.png" && attempt == 1 ? 0 : (name == "a.png" ? 3 : 1)
        return .init(captureDate: Date(timeIntervalSince1970: seconds))
    }
    func release() { releaseFirstA.signal() }
    var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return calls }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue134M1SortChosenDuringHeldRefreshFinishesOnNewSnapshot() async throws {
    let f = try WatchFixture(folders: ["root/F"]); defer { f.remove() }
    let rootID = try await f.access.grant(folder: f.url("root"))
    let scanner = HeldRefreshMetadataScanner(), reader = HeldConditionMetadataReader()
    defer { reader.release() }
    let c = FolderScanCoordinator(access: f.access, scanner: scanner, trace: nil,
        metadataReader: reader, watcher: f.hub)
    try Data([1]).write(to: f.url("root/F/a.png"))
    try await c.begin(folder: f.url("root/F"), rootID: rootID).value
    let oldVersion = try #require(c.sourceSnapshot?.version)

    try Data([1, 2]).write(to: f.url("root/F/b.png"))
    let refresh = try #require(c.refresh())
    await scanner.waitForRefresh()
    c.setConditions(.init(sort: .captureDate))
    try await waitUntil { reader.counts["a.png"] == 1 }
    #expect(c.metadataSortState == .pending)
    await scanner.releaseRefresh()
    try await refresh.value
    #expect(c.sourceSnapshot?.version != oldVersion)
    reader.release()

    try await waitUntil { c.metadataSortState == .complete }
    #expect(reader.counts == ["a.png": 2, "b.png": 1])
    #expect(reader.maxConcurrent == 1)
    #expect(c.snapshot?.entries.map(\.url.lastPathComponent) == ["b.png", "a.png"])
    c.end()
    try await waitUntil { f.source.active == 0 && f.scope.counts[0] == f.scope.counts[1] }
}
