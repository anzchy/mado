import Foundation
import CoreGraphics
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoInfrastructure

/// Suspends scheduling only; the real scoped resolver and ImageIO still read the file.
private actor Issue58IdentityGate: ItemIdentityResolving {
    private let resolver: FileItemIdentityResolver
    let arrivals: AsyncStream<Int>
    private let signal: AsyncStream<Int>.Continuation
    private let holds: Set<Int>
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private(set) var count = 0
    init(root: ItemIdentityRoot, holds: Set<Int>) {
        resolver = FileItemIdentityResolver(root: root); self.holds = holds
        (arrivals, signal) = AsyncStream.makeStream()
    }
    func identity(for fileURL: URL) async throws -> ItemID {
        count += 1
        let call = count
        if holds.contains(call) {
            await withCheckedContinuation { waiting[call] = $0; signal.yield(call) }
        }
        return try await resolver.identity(for: fileURL)
    }
    func release(_ call: Int) { waiting.removeValue(forKey: call)?.resume() }
    func finished() { signal.yield(-1) }
}

private actor Issue58Presentation: ImagePresentationPinning {
    let pipeline: ImageIOPipeline
    let releases: AsyncStream<RenderKey>
    private let signal: AsyncStream<RenderKey>.Continuation
    init(_ pipeline: ImageIOPipeline) {
        self.pipeline = pipeline; (releases, signal) = AsyncStream.makeStream()
    }
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) async -> Bool { await pipeline.pin(key, image: image) }
    func unpin(_ key: RenderKey) async { await pipeline.unpin(key); signal.yield(key) }
}

private struct Issue122CancelOnMiss: ResourceSnapshotTracing {
    func lookup(isPreview: Bool, hit: Bool) {
        if !hit { withUnsafeCurrentTask { $0?.cancel() } }
    }
}

private let issue58Time = Date(timeIntervalSince1970: 1_000_000)
private func issue58Write(_ name: String, to file: URL) throws {
    try Data(contentsOf: fixture(name)).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: issue58Time], ofItemAtPath: file.path)
}

@MainActor private func issue122RunLoader(tree: IdentityTree, cache: ImageMemoryCache,
    pipeline: ImageIOPipeline, old: RenderKey, observation: UUID) async throws {
    try issue58Write("pan-grid-4096x3072.png", to: tree.file)
    let access = CacheLeases(rootURL: tree.root), host = CacheHost()
    let loader = ViewerImageLoader(trace: nil, presentation: Issue58Presentation(pipeline))
    loader.host = host
    loader.open(tree.file, maximumPixelSize: 128) {
        try await AccessImageSource.open(.root(tree.id, file: tree.file), access: access, pipeline: pipeline)
    }
    await loader.loadTask?.value
    let shown = try #require(loader.presented?.key)
    #expect(shown.revision != old.revision && loader.phase == .settled)
    let obsolete = await cache.lookup(old, observation: observation)
    #expect(obsolete.sourceChanged && obsolete.requiresSourceValidation)
    loader.requireResolution(2048)
    await loader.loadTask?.value
    #expect(loader.phase == .settled && loader.failure == nil && host.failures.isEmpty)
    #expect(loader.presented?.key.revision == shown.revision)
    #expect(host.images.count == 3)
    #expect(await cache.finish(obsolete, image: cacheImage(try cachePixels(marker: 9), key: old)) == nil)
    loader.close()
    await access.waitUntilEmpty()
}

@Suite struct ImageCacheConflictResolutionTests {
    @Test(.timeLimit(.minutes(2))) func issue122CancellationAfterRevalidatedMissReleasesTicket() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let pipeline = ImageIOPipeline(cache: cache, cacheTrace: Issue122CancelOnMiss())
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let current = try #require(request.renderKey)
        let old = issue58RevisionKey(current, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R0"))
        await cache.pin(old, image: cacheImage(try cachePixels(marker: 6), key: old))
        let load = Task { try await pipeline.image(for: request) }
        do { _ = try await load.value; Issue.record("cancelled revalidated load returned an image") }
        catch { #expect((error as? ImageLoadError)?.kind == .cancelled) }
        #expect(await cache.pendingCount() == 0)
        await cache.unpin(old)
    }

    @Test(.timeLimit(.minutes(2))) func issue122DelayedOldPipelineHeaderRejectsReplacement() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-1.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let resolver = Issue58IdentityGate(root: tree.scope, holds: [2])
        let pipeline = ImageIOPipeline(identityResolver: resolver, cache: cache)
        let oldRequest = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let old = try #require(oldRequest.renderKey)
        let delayed = Task { try await pipeline.image(for: oldRequest) }
        var arrivals = resolver.arrivals.makeAsyncIterator()
        #expect(await arrivals.next() == 2)
        try issue58Write("orientation-2.tiff", to: tree.file)
        let currentRequest = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let current = try #require(currentRequest.renderKey)
        #expect(current.revision != old.revision)
        let shown = try await pipeline.imageFresh(for: currentRequest)
        await pipeline.pin(current, image: shown)
        await resolver.release(2)
        do { _ = try await delayed.value; Issue.record("old pipeline request delivered after replacement") }
        catch { #expect((error as? ImageLoadError)?.kind == .sourceChanged) }
        let detail = try await pipeline.request(for: tree.file, maximumPixelSize: 256)
        #expect(try await pipeline.image(for: detail).revision == current.revision)
        #expect(await cache.image(for: current)?.image === shown.image)
        await pipeline.unpin(current)
    }

    @Test(.timeLimit(.minutes(2))) func issue122StalePinnedRevisionDoesNotForceReread() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let old = cacheKey(125)
        let current = issue58RevisionKey(old, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R1"))
        let detail = RenderKey(itemID: current.itemID, revision: current.revision, maximumPixelSize: 1024, isPreview: false)
        await cache.pin(old, image: cacheImage(try cachePixels(marker: 5), key: old))
        let first = await cache.lookup(current)
        #expect(!first.sourceChanged)
        try await cache.withObservation(itemID: current.itemID) { observation in
            let second = await cache.lookup(detail, observation: observation)
            #expect(!second.requiresSourceValidation && !second.sourceChanged)
            _ = await cache.finish(second, image: nil)
        }
        _ = await cache.finish(first, image: nil)
        await cache.unpin(old)
    }

    @Test(.timeLimit(.minutes(2))) func issue122CancellationAfterCacheMissReleasesTicket() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let pipeline = ImageIOPipeline(cache: cache, cacheTrace: Issue122CancelOnMiss())
        let request = try await pipeline.request(for: fixture("coordinate-grid.png"), maximumPixelSize: 16)
        let load = Task { try await pipeline.image(for: request) }
        do { _ = try await load.value; Issue.record("cancelled load returned an image") }
        catch { #expect((error as? ImageLoadError)?.kind == .cancelled) }
        #expect(await cache.pendingCount() == 0)
    }

    @Test(.timeLimit(.minutes(2))) func issue122LateOldPinCannotEraseNewerRevisionObservation() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let old = cacheKey(123)
        let current = issue58RevisionKey(old, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R1"))
        let detail = RenderKey(itemID: current.itemID, revision: current.revision, maximumPixelSize: 1024, isPreview: false)
        let currentPixels = try cachePixels(marker: 1)
        let oldPixels = try cachePixels(marker: 2)
        try await cache.withObservation(itemID: old.itemID) { delayed in
            let loaded = await cache.lookup(current)
            #expect(await cache.finish(loaded, image: cacheImage(currentPixels, key: current))?.image === currentPixels)
            let pending = await cache.lookup(detail)
            await cache.pin(old, image: cacheImage(oldPixels, key: old))
            let obsolete = await cache.lookup(old, observation: delayed)
            #expect(obsolete.sourceChanged && obsolete.requiresSourceValidation && obsolete.image == nil)
            #expect(await cache.image(for: current)?.image === currentPixels)
            let detailPixels = try cachePixels(marker: 3)
            #expect(await cache.finish(pending, image: cacheImage(detailPixels, key: detail))?.image === detailPixels)
            await cache.unpin(old)
        }
    }

    @Test(.timeLimit(.minutes(2))) func issue122PinRecordProtectsUnpinnedCurrentRevision() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let old = cacheKey(124)
        let current = issue58RevisionKey(old, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R1"))
        let pixels = try cachePixels(marker: 4)
        try await cache.withObservation(itemID: old.itemID) { delayed in
            await cache.pin(current, image: cacheImage(pixels, key: current))
            await cache.unpin(current)
            let obsolete = await cache.lookup(old, observation: delayed)
            #expect(obsolete.sourceChanged && obsolete.requiresSourceValidation)
            #expect(await cache.image(for: current)?.image === pixels)
        }
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func issue122DisplayedCurrentRevisionSurvivesDelayedOldLookupAndZoom() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-1.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 32_000_000)
        let disk = ThumbnailDiskCache(directory: tree.root.appendingPathComponent("cache"))
        let pipeline = ImageIOPipeline(cache: cache, thumbnailCache: disk)
        let old = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128,
                                                           identityRoot: tree.scope).renderKey)
        try await cache.withObservation(itemID: old.itemID) { delayed in
            try await issue122RunLoader(tree: tree, cache: cache, pipeline: pipeline, old: old, observation: delayed)
        }
    }

    @Test(.timeLimit(.minutes(2))) func issue122CancelledCacheActorLookupKeepsOtherTicket() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let old = cacheKey(120)
        let current = issue58RevisionKey(old, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R1"))
        let pending = await cache.lookup(old)
        let currentPixels = try cachePixels(marker: 4)
        await cache.pin(current, image: cacheImage(currentPixels, key: current))
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.lookup(current)
        }
        let result = await cancelled.value
        #expect(result.sourceChanged && result.image == nil)
        let oldPixels = try cachePixels(marker: 5)
        #expect(await cache.finish(pending, image: cacheImage(oldPixels, key: old))?.image === oldPixels)
        #expect(await cache.image(for: current)?.image === currentPixels)
        await cache.unpin(current)
    }

    @Test(.timeLimit(.minutes(2))) func issue122PinnedFreshImageSurvivesRealReplacementAndOldObservation() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-1.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let pipeline = ImageIOPipeline(cache: cache)
        let old = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128).renderKey)
        try await cache.withObservation(itemID: old.itemID) { delayed in
            try issue58Write("orientation-2.tiff", to: tree.file)
            let preview = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
            let current = try #require(preview.renderKey)
            #expect(old.revision != current.revision)
            let shown = try await pipeline.imageFresh(for: preview)
            await pipeline.pin(current, image: shown)
            let obsolete = await cache.lookup(old, observation: delayed)
            #expect(obsolete.sourceChanged && obsolete.requiresSourceValidation && obsolete.image == nil)
            let detail = try await pipeline.request(for: tree.file, maximumPixelSize: 256)
            let detailed = try await pipeline.image(for: detail)
            #expect(detailed.revision == current.revision)
            #expect(await cache.image(for: current)?.image === shown.image)
            #expect(await cache.finish(obsolete, image: cacheImage(try cachePixels(marker: 9), key: old)) == nil)
            await pipeline.unpin(current)
        }
    }

    @Test(.timeLimit(.minutes(2))) func issue122CancelledHeaderCannotPrunePendingRevision() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-2.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let resolver = Issue58IdentityGate(root: tree.scope, holds: [2])
        let pipeline = ImageIOPipeline(identityResolver: resolver, cache: cache)
        let request = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let current = try #require(request.renderKey)
        let old = issue58RevisionKey(current, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R0"))
        let pending = await cache.lookup(old)
        let currentPixels = try cachePixels(marker: 2)
        await cache.pin(current, image: cacheImage(currentPixels, key: current))
        let task = Task { try await pipeline.image(for: request) }
        var arrivals = resolver.arrivals.makeAsyncIterator()
        #expect(await arrivals.next() == 2)
        task.cancel()
        await resolver.release(2)
        do { _ = try await task.value; Issue.record("cancelled request returned an image") }
        catch { #expect((error as? ImageLoadError)?.kind == .cancelled) }
        let oldPixels = try cachePixels(marker: 3)
        #expect(await cache.finish(pending, image: cacheImage(oldPixels, key: old))?.image === oldPixels)
        #expect(await cache.image(for: current)?.image === currentPixels)
        await cache.unpin(current)
    }

    @Test(.timeLimit(.minutes(2))) func issue122FreshCurrentObservationHealsPinnedRevisionAfterDelayedOldLookup() async throws {
        let cache = ImageMemoryCache(capacity: 1_000_000)
        let old = cacheKey(122)
        let current = issue58RevisionKey(old, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R1"))
        let detail = RenderKey(itemID: current.itemID, revision: current.revision, maximumPixelSize: 1024, isPreview: false)
        let pixels = try cachePixels(marker: 7)
        await cache.pin(current, image: cacheImage(pixels, key: current))
        try await cache.withObservation(itemID: old.itemID) { delayed in
            // The old header has been read. A newer presentation is already pinned.
            let obsolete = await cache.lookup(old, observation: delayed)
            #expect(obsolete.image == nil)
            try await cache.withObservation(itemID: current.itemID) { fresh in
                let recovered = await cache.lookup(current, observation: fresh)
                #expect(!recovered.sourceChanged)
                #expect(recovered.image?.image === pixels)
                let anotherSize = await cache.lookup(detail, observation: fresh)
                #expect(!anotherSize.sourceChanged)
                #expect(anotherSize.image == nil)
                let detailPixels = try cachePixels(marker: 8)
                #expect(await cache.finish(anotherSize, image: cacheImage(detailPixels, key: detail))?.image === detailPixels)
            }
            #expect(await cache.finish(obsolete, image: cacheImage(try cachePixels(marker: 9), key: old)) == nil)
        }
        #expect(await cache.image(for: current)?.image === pixels)
        await cache.unpin(current)
    }

    @Test(.timeLimit(.minutes(2))) func issue58OlderLookupFirstCurrentRevisionSucceeds() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-1.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 1_000_000), decoder = CacheCountingDecoder()
        let resolver = Issue58IdentityGate(root: tree.scope, holds: [3])
        let pipeline = ImageIOPipeline(decoder: decoder, identityResolver: resolver, cache: cache)
        let r1 = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let old = try #require(r1.renderKey)
        try issue58Write("orientation-2.tiff", to: tree.file)
        let r2 = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        let current = try #require(r2.renderKey)
        #expect(old.itemID == current.itemID)
        #expect(old.revision.byteCount == current.revision.byteCount)
        #expect(old.revision.modificationDate == current.revision.modificationDate)
        #expect(old.revision != current.revision)
        try await cache.withObservation(itemID: old.itemID) { b in
            let task = Task { try await pipeline.image(for: r2) }
            var arrivals = resolver.arrivals.makeAsyncIterator()
            #expect(await arrivals.next() == 3)
            let delayed = await cache.lookup(old, observation: b)
            #expect(!delayed.sourceChanged)
            await resolver.release(3)
            let image = try await task.value
            #expect(image.itemID == current.itemID && image.revision == current.revision)
            #expect(image.image.width == 128 && image.image.height == 96)
            let expectedPixels = try ImageIODecoder().decode(ImageDecodeRequest(
                fileURL: fixture("orientation-2.tiff"), maximumPixelSize: 128)).image
            #expect(issue58Pixels(image.image) == issue58Pixels(expectedPixels))
            #expect(await cache.image(for: current)?.image === image.image)
            #expect(await cache.finish(delayed, image: cacheImage(try cachePixels(), key: old)) == nil)
            #expect(await cache.image(for: old) == nil)
            #expect(await resolver.count == 4)
            #expect(decoder.count == 1)
        }
    }

    @MainActor @Test(.timeLimit(.minutes(2))) func issue58LoaderSettlesAfterSingleReplacementAndDelayedOldLookup() async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-1.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 1_000_000), decoder = CacheBlockingDecoder()
        defer { decoder.gate.open() }
        let resolver = Issue58IdentityGate(root: tree.scope, holds: [5])
        let pipeline = ImageIOPipeline(decoder: decoder, identityResolver: resolver, cache: cache)
        let old = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128).renderKey)
        try await cache.withObservation(itemID: old.itemID) { b in
            try await issue58RunLoader(tree: tree, cache: cache, decoder: decoder, resolver: resolver,
                                       pipeline: pipeline, old: old, observation: b)
        }
    }
}

@MainActor private func issue58RunLoader(tree: IdentityTree, cache: ImageMemoryCache, decoder: CacheBlockingDecoder,
    resolver: Issue58IdentityGate, pipeline: ImageIOPipeline, old: RenderKey, observation: UUID) async throws {
    let access = CacheLeases(), host = CacheHost(), presentation = Issue58Presentation(pipeline)
    let loader = ViewerImageLoader(trace: nil, presentation: presentation)
    loader.host = host
    var opens = 0
    loader.open(tree.file, maximumPixelSize: 128) {
        opens += 1
        return try await AccessImageSource.open(.fileGrant(tree.file), access: access, pipeline: pipeline)
    }
    var decodes = decoder.started.makeAsyncIterator(), arrivals = resolver.arrivals.makeAsyncIterator()
    _ = await decodes.next()
    // Exactly one real replacement. The production postdecode revision check consumes the retry.
    try issue58Write("orientation-2.tiff", to: tree.file)
    let revision = try FileRevisionReader.read(tree.file)
    decoder.gate.signal()
    #expect(await arrivals.next() == 5)
    #expect(opens == 2 && host.images.isEmpty)
    #expect(await access.active.count == 2)
    let delayed = await cache.lookup(old, observation: observation)
    #expect(!delayed.sourceChanged)
    await resolver.release(5)
    await loader.loadTask?.value
    #expect(loader.phase == .settled)
    #expect(loader.failure == nil && host.failures.isEmpty)
    #expect(loader.presented?.key.revision == revision && revision != old.revision)
    #expect(host.images.count == 2)
    #expect(host.images.allSatisfy { $0.width == 128 && $0.height == 96 })
    let expectedPixels = try ImageIODecoder().decode(ImageDecodeRequest(
        fileURL: fixture("orientation-2.tiff"), maximumPixelSize: 128)).image
    #expect(host.images.allSatisfy { issue58Pixels($0) == issue58Pixels(expectedPixels) })
    #expect(opens == 2 && decoder.count == 3)
    #expect(await resolver.count == 8)
    #expect(await cache.finish(delayed, image: cacheImage(try cachePixels(), key: old)) == nil)
    #expect(await cache.image(for: old) == nil)
    guard loader.phase == .settled else { loader.close(); await access.waitUntilEmpty(); return }
    var releases = presentation.releases.makeAsyncIterator()
    _ = await releases.next() // preview unpin after detail installation
    let shown = loader.presented?.key
    loader.close()
    #expect(await releases.next() == shown)
    await access.waitUntilEmpty()
    #expect(await cache.usage().pinnedBytes == 0)
    let acquired = await access.acquired, released = await access.released
    #expect(acquired.count == 5 && released.count == 5)
    for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
}

private enum Issue58Interruption: CaseIterable, Sendable {
    case conflict, replacement, cancel, corrupt, missing, unrelatedRoot
}

private func issue58RevisionKey(_ key: RenderKey, revision: FileRevision) -> RenderKey {
    RenderKey(itemID: key.itemID, revision: revision, maximumPixelSize: key.maximumPixelSize,
              isPreview: key.isPreview)
}

extension ImageCacheConflictResolutionTests {
    @Test(.timeLimit(.minutes(2)), arguments: Issue58Interruption.allCases)
    fileprivate func issue58FreshValidationPreservesAuthorityAndCleanup(_ interruption: Issue58Interruption) async throws {
        let tree = try IdentityTree(); defer { tree.remove() }
        try issue58Write("orientation-1.tiff", to: tree.file)
        let cache = ImageMemoryCache(capacity: 1_000_000), decoder = CacheCountingDecoder()
        let resolver = Issue58IdentityGate(root: tree.scope, holds: [3, 4])
        let pipeline = ImageIOPipeline(decoder: decoder, identityResolver: resolver, cache: cache)
        let old = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128).renderKey)
        try issue58Write("orientation-2.tiff", to: tree.file)
        let current = issue58RevisionKey(old, revision: try FileRevisionReader.read(tree.file))
        let foreign = RenderKey(itemID: .rootRelative(rootID: AccessRootID(), relativePath: "b.png"),
                                revision: current.revision, maximumPixelSize: 128)
        let foreignPixels = try cachePixels(marker: 8)
        await cache.pin(foreign, image: cacheImage(foreignPixels, key: foreign))
        let foreignPendingKey = RenderKey(itemID: foreign.itemID, revision: foreign.revision, maximumPixelSize: 256)
        let foreignPending = await cache.lookup(foreignPendingKey)
        let access = CacheLeases()
        let source = try await AccessImageSource.open(.fileGrant(tree.file), access: access, pipeline: pipeline)
        try await cache.withObservation(itemID: old.itemID) { b in
            let task = Task {
                do {
                    let result = try await source.image(maximumPixelSize: 128)
                    await resolver.finished(); return result
                } catch { await resolver.finished(); throw error }
            }
            var arrivals = resolver.arrivals.makeAsyncIterator()
            #expect(await arrivals.next() == 3)
            let delayed = await cache.lookup(old, observation: b)
            await resolver.release(3)
            let next = await arrivals.next()
            guard next == 4 else {
                Issue.record("Expected one fresh validation before completion")
                task.cancel(); await resolver.release(4); _ = await task.result
                await source.close(); return
            }
            #expect(await access.active.count == 2)
            var survivor: ImageCacheRequest?
            var expected: ImageLoadError.Kind? = .sourceChanged
            switch interruption {
            case .conflict:
                let revision = FileRevision(byteCount: current.revision.byteCount,
                    modificationDate: current.revision.modificationDate, resourceIdentifier: "intervening")
                survivor = await cache.lookup(issue58RevisionKey(current, revision: revision))
            case .replacement:
                try issue58Write("orientation-3.tiff", to: tree.file)
                survivor = await cache.lookup(issue58RevisionKey(current, revision: try FileRevisionReader.read(tree.file)))
            case .cancel:
                task.cancel(); expected = .cancelled
            case .corrupt:
                try Data(contentsOf: fixture("truncated.png")).write(to: tree.file, options: .atomic)
                expected = .corruptImage
            case .missing:
                try FileManager.default.removeItem(at: tree.file)
            case .unrelatedRoot:
                // Same relative path and revision in a distinct root cannot poison this validation.
                let unrelated = await cache.lookup(foreignPendingKey)
                _ = await cache.finish(unrelated, image: nil)
                expected = nil
            }
            await resolver.release(4)
            if let expected {
                await #expect(performing: { try await task.value }, throws: loadError(expected))
                #expect(decoder.count == 0)
                #expect(await cache.image(for: current) == nil)
            } else {
                let (request, image) = try await task.value
                #expect(request.renderKey == current && image.revision == current.revision)
                #expect(image.image.width == 128 && image.image.height == 96)
                #expect(decoder.count == 1)
                #expect(await cache.finish(delayed, image: cacheImage(try cachePixels(), key: old)) == nil)
            }
            #expect(await arrivals.next() == -1)
            #expect(await resolver.count == 4) // No third validation, even for another conflict.
            if let survivor {
                let pixels = try cachePixels(marker: 3)
                #expect(await cache.finish(survivor, image: cacheImage(pixels, key: survivor.key))?.image === pixels)
                #expect(await cache.finish(survivor, image: cacheImage(pixels, key: survivor.key)) == nil)
            }
            _ = await cache.finish(delayed, image: nil)
            #expect(await cache.image(for: old) == nil)
        }
        await source.close(); await access.waitUntilEmpty()
        let acquired = await access.acquired, released = await access.released
        #expect(acquired.count == 2 && released.count == 2)
        for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
        #expect(await cache.image(for: foreign)?.image === foreignPixels)
        #expect(await cache.pinCount(for: foreign) == 1)
        #expect(await cache.finish(foreignPending, image: cacheImage(foreignPixels, key: foreignPendingKey))?.image === foreignPixels)
        await cache.unpin(foreign)
        #expect(await cache.usage().pinnedBytes == 0)
        // A new independent operation progresses after all failure/cancellation observations retire.
        if interruption == .corrupt || interruption == .missing {
            try issue58Write("orientation-2.tiff", to: tree.file)
        }
        let reopened = try await AccessImageSource.open(.fileGrant(tree.file), access: access, pipeline: pipeline)
        let (_, restored) = try await reopened.image(maximumPixelSize: 128)
        #expect(restored.revision == (try FileRevisionReader.read(tree.file)))
        await reopened.close(); await access.waitUntilEmpty()
        #expect(await access.acquired.count == access.released.count)
    }

    @Test(.timeLimit(.minutes(2))) func issue58OnlyLiveMatchingObservationCanRequestResolution() async throws {
        let cache = ImageMemoryCache(capacity: 64), old = cacheKey(1), other = cacheKey(2)
        let current = issue58RevisionKey(old, revision: FileRevision(byteCount: 42, modificationDate: nil, resourceIdentifier: "R2"))
        let pixels = try cachePixels(marker: 2)
        let retired = await cache.withObservation(itemID: old.itemID) { $0 }
        let expired = await cache.lookup(old, observation: retired)
        #expect(expired.sourceChanged && !expired.requiresSourceValidation && expired.image == nil)
        await cache.withObservation(itemID: other.itemID) { wrongItem in
            let rejected = await cache.lookup(old, observation: wrongItem)
            #expect(rejected.sourceChanged && !rejected.requiresSourceValidation && rejected.image == nil)
        }
        await cache.withObservation(itemID: old.itemID) { live in
            let writer = await cache.lookup(current)
            let ambiguous = await cache.lookup(old, observation: live)
            #expect(ambiguous.sourceChanged && ambiguous.requiresSourceValidation && ambiguous.image == nil)
            #expect(await cache.finish(ambiguous, image: cacheImage(pixels, key: old)) == nil)
            #expect(await cache.finish(writer, image: cacheImage(pixels, key: current))?.image === pixels)
            await cache.pin(old, image: cacheImage(pixels, key: old))
            _ = await cache.lookup(current)
            let pinnedStale = await cache.lookup(old, observation: live)
            #expect(pinnedStale.sourceChanged && !pinnedStale.requiresSourceValidation && pinnedStale.image == nil)
            #expect(await cache.pinCount(for: old) == 1)
            #expect(await cache.image(for: current)?.image === pixels)
            await cache.unpin(old)
            #expect(await cache.usage() == ImageCacheUsage(entries: 1, previewBytes: 0, detailBytes: 16))
        }
    }
}

private func issue58Pixels(_ image: CGImage) -> Data? {
    guard let pixels = image.dataProvider?.data else { return nil }
    return pixels as Data
}
