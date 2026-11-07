import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

private final class HeldWatchMetadataReader: FolderMetadataReading, @unchecked Sendable {
    private let lock = NSLock()
    private let releaseFirstB = DispatchSemaphore(value: 0)
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
        if name == "b.png" && attempt == 1 { releaseFirstB.wait() }
        lock.lock(); active -= 1; lock.unlock()
        let seconds: TimeInterval = name == "b.png" && attempt == 1 ? 99 : (name == "b.png" ? 1 : 3)
        return .init(captureDate: Date(timeIntervalSince1970: seconds))
    }
    func release() { releaseFirstB.signal() }
    var counts: [String: Int] { lock.lock(); defer { lock.unlock() }; return calls }
    var maxConcurrent: Int { lock.lock(); defer { lock.unlock() }; return peak }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue134WatchRefreshRejectsHeldReplyWithoutRereadingSettledNeighbor() async throws {
    let f = try WatchFixture(folders: ["root/F"]); defer { f.remove() }
    let rootID = try await f.access.grant(folder: f.url("root"))
    let reader = HeldWatchMetadataReader()
    defer { reader.release() }
    let coordinator = FolderScanCoordinator(access: f.access, scanner: FolderBrowser(), trace: nil,
        metadataReader: reader, watcher: f.hub)
    try Data(repeating: 1, count: 3).write(to: f.url("root/F/a.png"))
    try await coordinator.begin(folder: f.url("root/F"), rootID: rootID).value
    coordinator.setConditions(.init(sort: .captureDate))
    try await waitUntil { coordinator.metadataSortState == .complete }
    #expect(reader.counts == ["a.png": 1])

    try Data(repeating: 1, count: 1).write(to: f.url("root/F/b.png"))
    try await #require(coordinator.refresh()).value
    try await waitUntil { reader.counts["b.png"] == 1 }
    #expect(coordinator.metadataSortState == .pending)
    try await #require(coordinator.refresh()).value
    #expect(reader.counts == ["a.png": 1, "b.png": 1])
    reader.release()
    try await waitUntil { coordinator.metadataSortState == .complete }
    #expect(reader.counts == ["a.png": 1, "b.png": 2])
    #expect(reader.maxConcurrent == 1)
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["b.png", "a.png"])
    coordinator.end()
    try await waitUntil { f.source.active == 0 && f.scope.counts[0] == f.scope.counts[1] }
}
