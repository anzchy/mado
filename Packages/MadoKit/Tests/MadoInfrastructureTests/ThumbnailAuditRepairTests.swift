import Foundation
import SQLite3
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func p304AuditMalformedEvictionRowCannotDeleteOutsideCache() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let outside = folder.appendingPathComponent("original.png")
    let sentinel = Data("original must survive malformed cache index".utf8)
    try sentinel.write(to: outside)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<2 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    let payload = cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")
    let payloadBytes = try Data(contentsOf: payload).count
    let index = cacheDirectory.appendingPathComponent("index.sqlite3")
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    let sql = "INSERT INTO thumbnails (key,item_id,source_sha256,payload,byte_count,payload_sha256,last_access,cache_version,source_width,source_height,row_sha256) VALUES ('../original','bad','bad','../original.png',\(3 * payloadBytes),'bad',0,2,1,1,'bad')"
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let limited = ThumbnailDiskCache(directory: cacheDirectory,
                                     highWaterBytes: 4 * payloadBytes, lowWaterBytes: 2 * payloadBytes)
    try await limited.store(images[1], for: tickets[1])
    let outsideSurvived = (try? Data(contentsOf: outside)) == sentinel
    #expect(outsideSurvived)
    #expect(try await limited.load(tickets[0]).map { _ in true } == true)
    #expect(try await limited.load(tickets[1]).map { _ in true } == true)
    var check: OpaquePointer?
    #expect(sqlite3_open_v2(index.path, &check, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { if let check { sqlite3_close(check) } }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(check, "SELECT count(*) FROM thumbnails WHERE key='../original'", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 0)
}

@Test func p304AuditStoreAndTouchShareOneRecencyOrder() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<3 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    let bytes = try Data(contentsOf: cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")).count
    let limited = ThumbnailDiskCache(directory: cacheDirectory,
                                     highWaterBytes: 2 * bytes + 1, lowWaterBytes: 2 * bytes)
    for _ in 0..<20 {
        #expect(try await limited.load(tickets[0]).map { _ in true } == true)
    }
    try await limited.store(images[1], for: tickets[1])
    try await limited.store(images[2], for: tickets[2])
    #expect(!FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png").path))
    #expect(try await limited.load(tickets[1]).map { _ in true } == true)
    #expect(try await limited.load(tickets[2]).map { _ in true } == true)
}

@Test func p304AuditMissingPayloadRowsConvergeWithoutEvictingLiveImages() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<4 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    for index in 0..<3 { try await seed.store(images[index], for: tickets[index]) }
    let payload = cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")
    let bytes = try Data(contentsOf: payload).count
    for index in 0..<2 {
        try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(tickets[index].key.filename + ".png"))
    }
    let limited = ThumbnailDiskCache(directory: cacheDirectory,
                                     highWaterBytes: 3 * bytes, lowWaterBytes: 2 * bytes)
    try await limited.store(images[3], for: tickets[3])
    #expect(try await limited.load(tickets[2]).map { _ in true } == true)
    #expect(try await limited.load(tickets[3]).map { _ in true } == true)
    var db: OpaquePointer?
    let index = cacheDirectory.appendingPathComponent("index.sqlite3")
    #expect(sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { if let db { sqlite3_close(db) } }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM thumbnails", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 2)
}

@Test func p304DeleteFailureDoesNotOverEvictAndConvergesNextPass() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<3 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    try await seed.store(images[1], for: tickets[1])
    let payloads = tickets.map { cacheDirectory.appendingPathComponent($0.key.filename + ".png") }
    let bytes = try Data(contentsOf: payloads[0]).count
    let index = cacheDirectory.appendingPathComponent("index.sqlite3")
    var db: OpaquePointer?
    #expect(sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TRIGGER reject_thumbnail_delete BEFORE DELETE ON thumbnails BEGIN SELECT RAISE(ABORT, 'injected delete failure'); END", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)

    let limited = ThumbnailDiskCache(directory: cacheDirectory,
        highWaterBytes: 2 * bytes + 1, lowWaterBytes: 2 * bytes)
    try await limited.store(images[2], for: tickets[2])
    #expect(!FileManager.default.fileExists(atPath: payloads[0].path))
    #expect(FileManager.default.fileExists(atPath: payloads[1].path))
    #expect(FileManager.default.fileExists(atPath: payloads[2].path))

    #expect(sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    var retained: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM thumbnails WHERE key='\(tickets[0].key.filename)'", -1, &retained, nil) == SQLITE_OK)
    #expect(sqlite3_step(retained) == SQLITE_ROW)
    #expect(sqlite3_column_int(retained, 0) == 1)
    sqlite3_finalize(retained)
    #expect(sqlite3_exec(db, "DROP TRIGGER reject_thumbnail_delete", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    try await limited.store(images[2], for: tickets[2])
    #expect(FileManager.default.fileExists(atPath: payloads[1].path))
    #expect(FileManager.default.fileExists(atPath: payloads[2].path))
    #expect(sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
    defer { if let db { sqlite3_close(db) } }
    var statement: OpaquePointer?
    #expect(sqlite3_prepare_v2(db, "SELECT count(*) FROM thumbnails", -1, &statement, nil) == SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    #expect(sqlite3_step(statement) == SQLITE_ROW)
    #expect(sqlite3_column_int(statement, 0) == 2)
}

@Test func p304AuditHealthyLockedIndexIsNeverUnlinked() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<2 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await cache.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await cache.store(images[0], for: tickets[0])
    let index = cacheDirectory.appendingPathComponent("index.sqlite3")
    var blocker: OpaquePointer?
    #expect(sqlite3_open_v2(index.path, &blocker, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
    #expect(sqlite3_exec(blocker, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK)
    let competing = ThumbnailDiskCache(directory: cacheDirectory)
    await #expect(throws: Error.self) { try await competing.store(images[1], for: tickets[1]) }
    #expect(sqlite3_exec(blocker, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(blocker)
    #expect(try await ThumbnailDiskCache(directory: cacheDirectory).load(tickets[0]).map { _ in true } == true)
    try await competing.store(images[1], for: tickets[1])
    #expect(try await ThumbnailDiskCache(directory: cacheDirectory).load(tickets[0]).map { _ in true } == true)
    #expect(try await ThumbnailDiskCache(directory: cacheDirectory).load(tickets[1]).map { _ in true } == true)
}

private actor P304AuditGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume()
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume() }
}

@Test func p304AuditOrphanSweepCannotDeleteNewlyCommittedPayload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<2 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    let gate = P304AuditGate()
    let sweeper = ThumbnailDiskCache(directory: cacheDirectory, afterOrphanSnapshot: { await gate.pause() })
    let oldTicket = tickets[0]
    let sweep = Task { try await sweeper.load(oldTicket).map { _ in true } }
    await gate.waitForEntry()
    try await ThumbnailDiskCache(directory: cacheDirectory).store(images[1], for: tickets[1])
    await gate.release()
    #expect(try await sweep.value == true)
    let warm = try await ThumbnailDiskCache(directory: cacheDirectory).load(tickets[1])
    #expect(try warm.map { try rgba($0.image) } == rgba(images[1].image))
}

@Test func p304AuditCancelledSameKeyWriterCannotDeleteHeldReaderPayload() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let expected = try rgba(decoded.image)
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await seed.prepare(request))
    try await seed.store(decoded, for: ticket)
    let gate = P304AuditGate()
    let reader = ThumbnailDiskCache(directory: cacheDirectory, afterReadLeaseAcquired: { await gate.pause() })
    let pending = Task { try await reader.load(ticket).map { try rgba($0.image) } }
    await gate.waitForEntry()
    let writer = ThumbnailDiskCache(directory: cacheDirectory, afterPayloadWrite: {
        withUnsafeCurrentTask { $0?.cancel() }
    })
    let work = Task { try await writer.store(decoded, for: ticket) }
    let outcome = await work.result
    if case .failure(let error) = outcome { #expect(error is CancellationError) }
    await gate.release()
    #expect(try await pending.value == expected)
    let warm = try await ThumbnailDiskCache(directory: cacheDirectory).load(ticket)
    #expect(try warm.map { try rgba($0.image) } == expected)
}

@Test func p304AuditRecencyOrderPersistsAcrossCacheActors() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let cacheDirectory = folder.appendingPathComponent("cache")
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let seed = ThumbnailDiskCache(directory: cacheDirectory)
    var tickets: [ThumbnailCacheTicket] = []
    var images: [DecodedImage] = []
    for index in 0..<3 {
        let file = folder.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
        let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
        tickets.append(try #require(try await seed.prepare(request)))
        images.append(try await pipeline.image(for: request))
    }
    try await seed.store(images[0], for: tickets[0])
    let bytes = try Data(contentsOf: cacheDirectory.appendingPathComponent(tickets[0].key.filename + ".png")).count
    let reader = ThumbnailDiskCache(directory: cacheDirectory)
    for _ in 0..<5 { #expect(try await reader.load(tickets[0]).map { _ in true } == true) }
    let writer = ThumbnailDiskCache(directory: cacheDirectory,
                                    highWaterBytes: 2 * bytes + 1, lowWaterBytes: 2 * bytes)
    try await writer.store(images[1], for: tickets[1])
    try await writer.store(images[2], for: tickets[2])
    let reopened = ThumbnailDiskCache(directory: cacheDirectory)
    #expect(try await reopened.load(tickets[0]).map { _ in true } == nil)
    #expect(try await reopened.load(tickets[1]).map { _ in true } == true)
    #expect(try await reopened.load(tickets[2]).map { _ in true } == true)
}
