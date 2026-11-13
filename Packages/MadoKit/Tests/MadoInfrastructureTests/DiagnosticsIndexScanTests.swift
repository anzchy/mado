import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

/// A settable uptime for the disk cache's diagnostics clock.
final class StatsClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 1_000
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

@Test(.timeLimit(.minutes(2))) func diagnosticsDiskIndexIsScannedAtMostOncePerTenSeconds() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["a.png", "b.png"] {
        try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: folder.appendingPathComponent(name))
    }
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let clock = StatsClock()
    let cache = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"), statsClock: { clock.now })
    let pipeline = ImageIOPipeline()
    func store(_ name: String) async throws {
        let request = try await pipeline.request(for: folder.appendingPathComponent(name), maximumPixelSize: 64, identityRoot: root)
        let ticket = try #require(try await cache.prepare(request))
        try await cache.store(try await pipeline.image(for: request), for: ticket)
    }
    try await store("a.png")
    for _ in 0..<5 { #expect(await cache.diagnostics().entries == 1) }
    #expect(await cache.indexScans == 1)

    // Within ten seconds the last scan stands, even after another store.
    try await store("b.png")
    clock.advance(9.9)
    #expect(await cache.diagnostics().entries == 1)
    #expect(await cache.indexScans == 1)
    clock.advance(0.1)
    #expect(await cache.diagnostics().entries == 2)
    #expect(await cache.indexScans == 2)

    // Clearing drops the stale figures at once.
    try await cache.clear()
    await cache.waitForPendingDeletions()
    let cleared = await cache.diagnostics()
    #expect(cleared.entries == 0 && cleared.storedBytes == 0)
}
