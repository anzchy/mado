import Foundation
import Testing
import MadoApplication
import MadoCore
@testable import MadoInfrastructure

@Test func p305PublicCacheErrorCodeNeverIncludesAFilePath() {
    let path = "/Users/private-person/Library/Caches/Mado/Thumbnails/index.sqlite3"
    let error = NSError(domain: NSCocoaErrorDomain, code: 512, userInfo: [NSFilePathErrorKey: path])
    let code = ThumbnailDiskCache.publicErrorCode(error)
    #expect(code == "cocoa:512")
    #expect(!code.contains(path))
    #expect(ThumbnailDiskCache.publicErrorCode(NSError(domain: NSPOSIXErrorDomain, code: 28,
        userInfo: [NSFilePathErrorKey: path])) == "posix:28")
    #expect(ThumbnailDiskCache.publicErrorCode(NSError(domain: path, code: 7)) == "other:7")
}

@Test func p305ClearCountsAndRemovesOwnedSQLiteJournal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let cacheURL = root.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let journal = cacheURL.appendingPathComponent("index.sqlite3-journal")
    try Data(repeating: 7, count: 13).write(to: journal)
    let cache = ThumbnailDiskCache(directory: cacheURL)
    #expect(try await cache.sizeBytes() == 13)
    try await cache.clear()
    #expect(!FileManager.default.fileExists(atPath: journal.path))
    #expect(try await cache.sizeBytes() == 0)
}

@Test func p305ClearInvalidatesHeldStoreAndMeasuresRealBytes() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    let first = ThumbnailDiskCache(directory: cacheURL)
    let second = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let old = try #require(try await first.prepare(request))
    #expect(try await first.sizeBytes() == 0)
    try await second.clear()
    try await first.store(decoded, for: old)
    #expect(try await second.load(old).map { _ in true } == nil)
    #expect(try await second.sizeBytes() == 0)
    let fresh = try #require(try await second.prepare(request))
    try await second.store(decoded, for: fresh)
    var measuredFiles: Int64 = 0
    for name in try FileManager.default.contentsOfDirectory(atPath: cacheURL.path) {
        let attributes = try FileManager.default.attributesOfItem(atPath: cacheURL.appendingPathComponent(name).path)
        measuredFiles += (attributes[.size] as! NSNumber).int64Value
    }
    #expect(try await first.sizeBytes() == measuredFiles)
    #expect(try await first.load(old).map { _ in true } == nil)
    #expect(try await first.sizeBytes() > 0)
    #expect(try await first.load(fresh).map { _ in true } != nil)
    try await first.clear()
    #expect(try await first.sizeBytes() == 0)
    #expect(try await second.load(fresh).map { _ in true } == nil)
}

@Test @MainActor func p307SettingsModelRetainsClearFailure() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let cacheURL = rootURL.appendingPathComponent("cache")
    try Data("not a directory".utf8).write(to: cacheURL)
    let model = CacheSettingsModel(cache: ThumbnailDiskCache(directory: cacheURL))
    await model.clear()
    #expect(model.sizeBytes == nil)
    #expect(model.diagnostic == "Cache clear failed")
    #expect(!(model.diagnostic ?? "").contains(cacheURL.path))
    #expect(try Data(contentsOf: cacheURL) == Data("not a directory".utf8))
}

private actor P307MeasurementGate {
    private var calls = 0
    private var entered: CheckedContinuation<Void, Never>?
    private var releaseFirst: CheckedContinuation<Void, Never>?
    func measure() async -> Int64 {
        calls += 1
        if calls == 1 {
            entered?.resume()
            await withCheckedContinuation { releaseFirst = $0 }
            return 999
        }
        return 0
    }
    func waitForFirst() async {
        if calls > 0 { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { releaseFirst?.resume() }
}

@Test @MainActor func p307NewMeasurementCannotBeOverwrittenByOlderResult() async {
    let cache = ThumbnailDiskCache()
    let model = CacheSettingsModel(cache: cache)
    let gate = P307MeasurementGate()
    let first = Task { await model.refresh(measureBytes: { await gate.measure() }) }
    await gate.waitForFirst()
    await model.refresh(measureBytes: { await gate.measure() })
    #expect(model.sizeBytes == 0)
    await gate.release()
    await first.value
    #expect(model.sizeBytes == 0)
}

@Test func p305WriteFailureRetriesWithoutClearAfterOneSkippedAttempt() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    try Data("block".utf8).write(to: cacheURL)
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let failed = await cache.writeDiagnostics()
    #expect(failed.failureCount == 1)
    #expect(failed.lastFailure != nil)
    try FileManager.default.removeItem(at: cacheURL)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    try await cache.store(decoded, for: ticket)
    let skipped = await cache.writeDiagnostics()
    #expect(skipped.failureCount == 1)
    #expect(skipped.skippedWriteCount == 1)
    #expect(try await cache.load(ticket).map { _ in true } == nil)
    try await cache.store(decoded, for: ticket)
    #expect(try await cache.load(ticket).map { _ in true } != nil)
    #expect((await cache.writeDiagnostics()).failureCount == 1)
    #expect((await cache.writeDiagnostics()).lastFailure == nil)
    try await cache.clear()
    let recovered = await cache.writeDiagnostics()
    #expect(recovered.failureCount == 0)
    let fresh = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: fresh)
    #expect(try await cache.load(fresh).map { _ in true } != nil)
}

@Test func p305AuthorizedImagesStillDisplayWhenCacheCannotWrite() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let originalBytes = try Data(contentsOf: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    try Data("blocked".utf8).write(to: cacheURL)
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let access = try FileAccess(scope: CountingScope(), bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: rootURL.appendingPathComponent("roots.json")), buildSHA: "p305")
    let root = try await access.grant(folder: rootURL)
    let pipeline = ImageIOPipeline(thumbnailCache: cache)
    let referenceRequest = try await ImageIOPipeline().request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: root, url: rootURL))
    let reference = try await ImageIOPipeline().image(for: referenceRequest)
    for _ in 0..<2 {
        let opened = try await AccessImageSource.open(.root(root, file: source), access: access, pipeline: pipeline)
        let (_, image) = try await opened.image(maximumPixelSize: 128)
        #expect(try rgba(image.image) == rgba(reference.image))
        await opened.close()
    }
    let diagnostics = await cache.writeDiagnostics()
    #expect(diagnostics.failureCount == 1)
    #expect(diagnostics.skippedWriteCount == 1)
    let settings = await CacheSettingsModel(cache: cache)
    await settings.refresh()
    #expect(await settings.diagnostic == "Cache write failed")
    #expect(try Data(contentsOf: source) == originalBytes)
    #expect(try Data(contentsOf: cacheURL) == Data("blocked".utf8))
}

@Test @MainActor func p307SettingsModelShowsMeasuredBytesAndClear() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let model = CacheSettingsModel(cache: cache)
    #expect(model.sizeBytes == nil)
    await model.refresh()
    #expect(model.sizeBytes == (try await cache.sizeBytes()))
    #expect(model.sizeBytes ?? 0 > 0)
    await model.clear()
    #expect(model.sizeBytes == 0)
    #expect(try await cache.load(ticket).map { _ in true } == nil)
}

private actor P305ReadGate {
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

private actor P305WaitRegistration {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        entered = true
        waiter?.resume()
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@Test func p305ClearKeepsLeasedPayloadAndNeverDeletesForeignFiles() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    let seed = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let ticket = try #require(try await seed.prepare(request))
    try await seed.store(decoded, for: ticket)
    let payload = cacheURL.appendingPathComponent(ticket.key.filename + ".png")
    let foreign = cacheURL.appendingPathComponent("foreign.txt")
    let parent = rootURL.appendingPathComponent("parent.txt")
    try Data("foreign".utf8).write(to: foreign)
    try Data("parent".utf8).write(to: parent)
    let gate = P305ReadGate()
    let reader = ThumbnailDiskCache(directory: cacheURL, afterReadLeaseAcquired: { await gate.pause() })
    let pending = Task { try await reader.load(ticket).map { _ in true } }
    await gate.waitForEntry()
    try await seed.clear()
    #expect(FileManager.default.fileExists(atPath: payload.path))
    #expect(try await seed.load(ticket).map { _ in true } == nil)
    let registration = P305WaitRegistration()
    let drain = Task {
        await seed.waitForPendingDeletions(onRegistered: {
            Task { await registration.signal() }
        })
    }
    await registration.wait()
    #expect(FileManager.default.fileExists(atPath: payload.path))
    await gate.release()
    #expect(try await pending.value == true)
    await drain.value
    #expect(!FileManager.default.fileExists(atPath: payload.path))
    try await seed.clear()
    #expect(!FileManager.default.fileExists(atPath: payload.path))
    #expect(try Data(contentsOf: foreign) == Data("foreign".utf8))
    #expect(try Data(contentsOf: parent) == Data("parent".utf8))
    #expect(try await seed.sizeBytes() == 0)
}

@Test func p305ClearRejectsSymlinkDirectory() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let outside = rootURL.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let payload = outside.appendingPathComponent(String(repeating: "a", count: 64) + ".png")
    try Data("keep".utf8).write(to: payload)
    let linkedCache = rootURL.appendingPathComponent("cache")
    try FileManager.default.createSymbolicLink(at: linkedCache, withDestinationURL: outside)
    let cache = ThumbnailDiskCache(directory: linkedCache)
    await #expect(throws: Error.self) { try await cache.clear() }
    guard FileManager.default.fileExists(atPath: payload.path) else {
        Issue.record("clear removed a file outside the cache directory")
        return
    }
    #expect(try Data(contentsOf: payload) == Data("keep".utf8))
}

@Test func p305ClearRejectsSymlinkAncestor() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let outside = rootURL.appendingPathComponent("outside")
    let actualCache = outside.appendingPathComponent("cache")
    try FileManager.default.createDirectory(at: actualCache, withIntermediateDirectories: true)
    let payload = actualCache.appendingPathComponent(String(repeating: "b", count: 64) + ".png")
    try Data("keep".utf8).write(to: payload)
    let linkedParent = rootURL.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
    let cache = ThumbnailDiskCache(directory: linkedParent.appendingPathComponent("cache"))
    await #expect(throws: Error.self) { try await cache.clear() }
    guard FileManager.default.fileExists(atPath: payload.path) else {
        Issue.record("clear followed a symlink ancestor outside the cache directory")
        return
    }
    #expect(try Data(contentsOf: payload) == Data("keep".utf8))
}

@Test @MainActor func p307SettingsWaitsForLeasedClearBeforeShowingZero() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let gate = P305ReadGate()
    let reader = ThumbnailDiskCache(directory: cacheURL, afterReadLeaseAcquired: { await gate.pause() })
    let read = Task { try await reader.load(ticket).map { _ in true } }
    await gate.waitForEntry()
    let model = CacheSettingsModel(cache: cache)
    let clearing = Task { await model.clear() }
    await gate.release()
    #expect(try await read.value == true)
    await clearing.value
    #expect(model.sizeBytes == 0)
    #expect(!model.isMeasuring)
}

@Test func p305PendingDrainTracksAllLeasedPayloads() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let cacheURL = rootURL.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let root = ItemIdentityRoot(id: AccessRootID(), url: rootURL)
    var tickets: [ThumbnailCacheTicket] = []
    for index in 0..<2 {
        let source = rootURL.appendingPathComponent("image-\(index).tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
        let request = try await pipeline.request(for: source, maximumPixelSize: 128, identityRoot: root)
        let image = try await pipeline.image(for: request)
        let ticket = try #require(try await cache.prepare(request))
        try await cache.store(image, for: ticket)
        tickets.append(ticket)
    }
    let firstGate = P305ReadGate(), secondGate = P305ReadGate()
    let firstTicket = tickets[0], secondTicket = tickets[1]
    let firstReader = ThumbnailDiskCache(directory: cacheURL, afterReadLeaseAcquired: { await firstGate.pause() })
    let secondReader = ThumbnailDiskCache(directory: cacheURL, afterReadLeaseAcquired: { await secondGate.pause() })
    let first = Task { try await firstReader.load(firstTicket).map { _ in true } }
    let second = Task { try await secondReader.load(secondTicket).map { _ in true } }
    await firstGate.waitForEntry()
    await secondGate.waitForEntry()
    try await cache.clear()
    let registration = P305WaitRegistration()
    let drain = Task {
        await cache.waitForPendingDeletions(onRegistered: { Task { await registration.signal() } })
    }
    await registration.wait()
    await firstGate.release()
    #expect(try await first.value == true)
    #expect(FileManager.default.fileExists(atPath: cacheURL.appendingPathComponent(secondTicket.key.filename + ".png").path))
    await secondGate.release()
    #expect(try await second.value == true)
    await drain.value
    #expect(try await cache.sizeBytes() == 0)
}

@Test @MainActor func p307SettingsClearMeasuresAfterRegisteredLeaseDrain() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let payload = cacheURL.appendingPathComponent(ticket.key.filename + ".png")
    let gate = P305ReadGate(), registered = P305WaitRegistration()
    let reader = ThumbnailDiskCache(directory: cacheURL, afterReadLeaseAcquired: { await gate.pause() })
    let read = Task { try await reader.load(ticket).map { _ in true } }
    await gate.waitForEntry()
    let model = CacheSettingsModel(cache: cache)
    let clearing = Task {
        await model.clear(onWaitRegistered: { Task { await registered.signal() } })
    }
    await registered.wait()
    #expect(model.isMeasuring)
    await model.refresh()
    #expect(model.isMeasuring)
    #expect(FileManager.default.fileExists(atPath: payload.path))
    await gate.release()
    #expect(try await read.value == true)
    await clearing.value
    #expect(model.sizeBytes == 0)
    #expect(!model.isMeasuring)
}

@Test func p305FailedDeferredDeletionIsDiagnosedAndRetryable() async throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: rootURL) }
    let source = rootURL.appendingPathComponent("image.tiff")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: source)
    let cacheURL = rootURL.appendingPathComponent("cache")
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheURL.path) }
    let cache = ThumbnailDiskCache(directory: cacheURL)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: source, maximumPixelSize: 128,
        identityRoot: ItemIdentityRoot(id: AccessRootID(), url: rootURL))
    let decoded = try await pipeline.image(for: request)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    let payload = cacheURL.appendingPathComponent(ticket.key.filename + ".png")
    let gate = P305ReadGate()
    let reader = ThumbnailDiskCache(directory: cacheURL, afterReadLeaseAcquired: { await gate.pause() })
    let pending = Task { try await reader.load(ticket).map { _ in true } }
    await gate.waitForEntry()
    try await cache.clear()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: cacheURL.path)
    await gate.release()
    _ = try await pending.value
    #expect(await cache.deferredClearFailure() != nil)
    #expect(FileManager.default.fileExists(atPath: payload.path))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cacheURL.path)
    try await cache.clear()
    #expect(await cache.deferredClearFailure() == nil)
    #expect(!FileManager.default.fileExists(atPath: payload.path))
}
