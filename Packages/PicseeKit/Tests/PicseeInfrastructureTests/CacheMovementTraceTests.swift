import CoreGraphics
import Foundation
import Testing
import PicseeCore
@testable import PicseeInfrastructure

// #146 (P3-08) counters: memory-cache admissions and departures, thumbnail disk-cache hits and misses, reported to the
// pipeline's tracer so a script can count them inside and outside a timed interval. Counters only: the cache's
// choices are unchanged. Bytes are what an entry held when it was admitted, so an emptied cache balances exactly.

final class MovementRecorder: ResourceSnapshotTracing, @unchecked Sendable {
    struct Movement: Equatable { let preview: Bool; let bytes: Int; let reason: MemoryDepartureReason? }
    private let lock = NSLock()
    private var admitted: [Movement] = []
    private var departed: [Movement] = []
    private var lookups: [Bool] = []
    var admissions: [Movement] { lock.withLock { admitted } }
    var departures: [Movement] { lock.withLock { departed } }
    var disk: [Bool] { lock.withLock { lookups } }
    func lookup(isPreview: Bool, hit: Bool) { }
    func diskLookup(hit: Bool) { lock.withLock { lookups.append(hit) } }
    func memoryAdmission(isPreview: Bool, bytes: Int) {
        lock.withLock { admitted.append(Movement(preview: isPreview, bytes: bytes, reason: nil)) }
    }
    func memoryDeparture(isPreview: Bool, bytes: Int, reason: MemoryDepartureReason) {
        lock.withLock { departed.append(Movement(preview: isPreview, bytes: bytes, reason: reason)) }
    }
}

private func movementKey(_ item: Int, revision: Int = 42) -> RenderKey {
    RenderKey(itemID: .ephemeral(UUID(uuidString: String(format: "00000000-0000-0000-0146-%012d", item))!),
              revision: FileRevision(byteCount: revision, modificationDate: nil), maximumPixelSize: 512, isPreview: item % 2 == 0)
}

@Test func p308MemoryCacheReportsAdmissionsAndBudgetEvictions() async throws {
    let recorder = MovementRecorder()
    let cache = ImageMemoryCache(capacity: 32, budget: nil, movementTrace: recorder)
    let a = cacheKey(1, preview: true), b = cacheKey(2), c = cacheKey(3)
    await cache.insert(cacheImage(try cachePixels(marker: 1), key: a), for: a)
    await cache.insert(cacheImage(try cachePixels(marker: 2), key: b), for: b)
    #expect(recorder.admissions == [.init(preview: true, bytes: 16, reason: nil), .init(preview: false, bytes: 16, reason: nil)])
    #expect(recorder.departures.isEmpty)
    await cache.insert(cacheImage(try cachePixels(marker: 3), key: c), for: c)
    #expect(recorder.departures == [.init(preview: true, bytes: 16, reason: .budget)], "the oldest (a) is evicted to fit")
    // An oversize image is refused before admission; a hit moves an entry but admits nothing.
    await cache.insert(cacheImage(try cachePixels(rows: 3), key: cacheKey(4)), for: cacheKey(4))
    _ = await cache.image(for: b)
    #expect(recorder.admissions.count == 3 && recorder.departures.count == 1)
}

@Test func p308ReplacingAKeyIsADiscardThenAnAdmission() async throws {
    let recorder = MovementRecorder()
    let cache = ImageMemoryCache(capacity: 64, budget: nil, movementTrace: recorder)
    let a = cacheKey(1)
    await cache.insert(cacheImage(try cachePixels(rows: 1), key: a), for: a)
    await cache.insert(cacheImage(try cachePixels(rows: 2), key: a), for: a)
    #expect(recorder.admissions.map(\.bytes) == [16, 32])
    #expect(recorder.departures == [.init(preview: false, bytes: 16, reason: .discarded)])
    await cache.remove(a)
    #expect(recorder.departures.last == .init(preview: false, bytes: 32, reason: .discarded))
}

/// Random operations over every admission and removal site. After each: admissions − departures == entries, and the
/// departures the operation caused carry an allowed reason. Emptying the cache at the end balances the bytes.
@Test func p308RandomCacheOperationsConserveEntriesAndBytes() async throws {
    let recorder = MovementRecorder()
    let cache = ImageMemoryCache(capacity: 96, budget: nil, movementTrace: recorder)
    var generator = SplitMix64(seed: 0x146_3)
    // Pins belong to a key (item and revision); a permit to the key it was inserted with.
    var revisions = [Int: Int](), pins = [RenderKey: Int](), authorities = [Int: (AccessWorkAuthority, RenderKey)]()
    func key(_ item: Int) -> RenderKey { movementKey(item, revision: revisions[item, default: 42]) }
    enum Operation: CaseIterable { case insert, insertWithPermit, pin, unpin, remove, trim, release, pressure, newRevision, revoke }
    var seen: Set<String> = []
    for step in 0..<600 {
        let operation = Operation.allCases.randomElement(using: &generator)!
        let item = Int.random(in: 1...6, using: &generator)
        let before = recorder.departures.count
        switch operation {
        case .insert:
            let k = key(item)
            await cache.insert(cacheImage(try cachePixels(rows: Int.random(in: 1...3, using: &generator)), key: k), for: k)
        case .insertWithPermit:
            let authority = AccessWorkAuthority()
            let k = key(item)
            authorities[item] = (authority, k)
            await cache.insert(cacheImage(try cachePixels(rows: 1), key: k), for: k, accessPermit: authority.permit(counter: 0))
        case .pin:
            let k = key(item)
            if await cache.pin(k, image: cacheImage(try cachePixels(rows: Int.random(in: 1...2, using: &generator)), key: k)) {
                pins[k, default: 0] += 1
            }
        case .unpin:
            // Any pinned revision of this item.
            guard let k = pins.first(where: { $0.key.itemID == key(item).itemID && $0.value > 0 })?.key else { continue }
            pins[k]! -= 1
            await cache.unpin(k)
        case .remove:
            await cache.remove(key(item))
        case .trim:
            await cache.trim(to: [0, 32, 96].randomElement(using: &generator)!)
        case .release:
            await cache.release(bytes: Int.random(in: 1...48, using: &generator))
        case .pressure:
            await cache.pressure([MemoryPressureLevel.normal, .warning, .critical].randomElement(using: &generator)!)
        case .newRevision:
            // A pinned old revision would keep two live revisions; the cache only marks it stale.
            revisions[item, default: 42] += 1
            _ = await cache.finish(await cache.lookup(key(item)), image: nil)
        case .revoke:
            guard let (authority, k) = authorities.removeValue(forKey: item) else { continue }
            authority.update(counter: 1, readable: false)
            _ = await cache.image(for: k)
        }
        let caused = Set(recorder.departures.dropFirst(before).compactMap(\.reason))
        let allowed: Set<MemoryDepartureReason> = switch operation {
        case .trim, .release, .pressure, .pin: [.budget]
        case .remove: [.discarded]
        case .insert, .insertWithPermit, .unpin, .newRevision, .revoke: [.budget, .discarded]
        }
        #expect(caused.isSubset(of: allowed), "step \(step) \(operation): reasons \(caused)")
        if !caused.isEmpty { seen.insert("\(operation)") }
        let entries = await cache.diagnostics().entries
        #expect(recorder.admissions.count - recorder.departures.count == entries,
                "step \(step) \(operation): admitted \(recorder.admissions.count) departed \(recorder.departures.count) entries \(entries)")
    }
    // Every removal site was reached at least once; a revoked entry has its own test below.
    #expect(seen.isSuperset(of: ["insert", "unpin", "remove", "trim", "release", "pressure", "newRevision"]), "\(seen.sorted())")
    for (k, count) in pins { for _ in 0..<count { await cache.unpin(k) } }
    await cache.trim(to: 0)
    #expect(await cache.diagnostics().entries == 0)
    #expect(recorder.admissions.count == recorder.departures.count)
    #expect(recorder.admissions.map(\.bytes).reduce(0, +) == recorder.departures.map(\.bytes).reduce(0, +),
            "departures do not report what their admissions did")
    #expect(Set(recorder.admissions.map(\.preview)) == [true, false])
}

@Test func p308MemoryCacheDiscardsARevokedEntryOnItsNextRead() async throws {
    let recorder = MovementRecorder()
    let cache = ImageMemoryCache(capacity: 64, budget: nil, movementTrace: recorder)
    let authority = AccessWorkAuthority()
    let a = cacheKey(1)
    await cache.insert(cacheImage(try cachePixels(rows: 1), key: a), for: a, accessPermit: authority.permit(counter: 0))
    authority.update(counter: 1, readable: false)
    #expect(await cache.image(for: a) == nil)
    #expect(recorder.admissions == [.init(preview: false, bytes: 16, reason: nil)])
    #expect(recorder.departures == [.init(preview: false, bytes: 16, reason: .discarded)])
    #expect(await cache.diagnostics().entries == 0)
}

private struct MovementRig {
    let folder: URL, root: ItemIdentityRoot
    init(count: Int) throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("p308-movement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<count {
            try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: folder.appendingPathComponent("\(index).png"))
        }
        root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    }
    func file(_ index: Int) -> URL { folder.appendingPathComponent("\(index).png") }
    var cacheDirectory: URL { folder.appendingPathComponent("cache") }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

/// The App's configuration: the pipeline makes its own cache and gives it the tracer. Real decodes insert through
/// `finish`, which passes no snapshot context, and the cache trims to its capacity.
@Test(.timeLimit(.minutes(2))) func p308PipelineReportsCacheMovementOnTheRealPaths() async throws {
    let rig = try MovementRig(count: 5)
    defer { rig.remove() }
    let recorder = MovementRecorder()
    // A 64-px decode of the fixture is a few KiB; a 7 000-byte cache keeps at most two of them.
    let pipeline = ImageIOPipeline(configuration: DecodeConfiguration(budget: 30_000, cacheCapacity: 7_000), cacheTrace: recorder)
    for index in 0..<5 {
        let request = try await pipeline.request(for: rig.file(index), maximumPixelSize: 64, identityRoot: rig.root)
        _ = try await pipeline.image(for: request)
        let entries = await pipeline.cache.diagnostics().entries
        #expect(recorder.admissions.count - recorder.departures.count == entries, "decode \(index)")
    }
    #expect(recorder.admissions.count == 5)
    let decoded = try #require(recorder.admissions.first).bytes
    #expect(decoded > 0 && decoded <= 3_500, "one decode is \(decoded) bytes; the capacity assumes two fit and three do not")
    #expect(recorder.admissions.allSatisfy { $0.bytes == decoded && !$0.preview })
    let entries = await pipeline.cache.diagnostics().entries
    #expect(entries == 2 && recorder.departures.count == 3, "entries \(entries) departures \(recorder.departures)")
    #expect(recorder.departures.allSatisfy { $0.reason == .budget && $0.bytes == decoded }, "\(recorder.departures)")
    #expect(await pipeline.cache.diagnostics().bytes == 2 * decoded)
}

/// A disk lookup is counted only when the thumbnail cache's load returned, exactly as the cache counts it.
@Test(.timeLimit(.minutes(2))) func p308DiskLookupsMatchTheDiskCacheCounts() async throws {
    let rig = try MovementRig(count: 1)
    defer { rig.remove() }
    let recorder = MovementRecorder()
    let disk = ThumbnailDiskCache(directory: rig.cacheDirectory)
    let pipeline = ImageIOPipeline(cacheTrace: recorder, thumbnailCache: disk)
    let request = try await pipeline.request(for: rig.file(0), maximumPixelSize: 64, identityRoot: rig.root)
    let ticket = try #require(try await disk.prepare(request))
    func agree(_ phase: String) async {
        let counted = await disk.diagnostics()
        #expect(recorder.disk.filter { $0 }.count == counted.hits && recorder.disk.filter { !$0 }.count == counted.misses,
                "\(phase): traced \(recorder.disk) disk hits \(counted.hits) misses \(counted.misses)")
    }
    #expect(try await pipeline.cachedImage(for: ticket) == nil)
    #expect(recorder.disk == [false])
    try await disk.store(try await pipeline.image(for: request), for: ticket)
    #expect(try await pipeline.cachedImage(for: ticket) != nil)
    #expect(recorder.disk == [false, true])
    await agree("hit and miss")
    // Cancelled before the load: neither side counts.
    let cancelled = Task { () async throws -> DecodedImage? in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await pipeline.cachedImage(for: ticket)
    }
    _ = try? await cancelled.value
    await agree("cancelled")
    // No thumbnail cache: nothing to look up.
    _ = try await ImageIOPipeline(cacheTrace: recorder).cachedImage(for: ticket)
    await agree("no disk cache")
    #expect(recorder.disk.count == 2)
}

@Test func p308CacheTraceMessagesMatchTheSharedTable() throws {
    let table = try p308InfrastructureSignpostMessages()
    #expect(CacheTraceMessage.diskLookup(hit: true) == table["ThumbnailDiskLookup.hit"])
    #expect(CacheTraceMessage.diskLookup(hit: false) == table["ThumbnailDiskLookup.miss"])
    #expect(CacheTraceMessage.admission(isPreview: true, bytes: 4096) == table["MemoryCacheAdmission"])
    #expect(CacheTraceMessage.departure(isPreview: false, bytes: 4096, reason: .budget) == table["MemoryCacheEviction"])
    #expect(CacheTraceMessage.departure(isPreview: true, bytes: 1, reason: .discarded) == "tier=preview bytes=1 reason=discarded")
}

/// `scripts/perf/fixtures/signpost-messages.json`, package section.
private func p308InfrastructureSignpostMessages(source: String = #filePath) throws -> [String: String] {
    var root = URL(fileURLWithPath: source)
    for _ in 0..<5 { root = root.deletingLastPathComponent() }
    let data = try Data(contentsOf: root.appendingPathComponent("scripts/perf/fixtures/signpost-messages.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["package"] as? [String: String])
}
