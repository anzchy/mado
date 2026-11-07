import CoreGraphics
import Foundation
import ImageIO
import os
import MadoCore
import UniformTypeIdentifiers

public enum ImageDecodeError: Error, Equatable {
    case budgetExceeded
    case invalidRequest
    case unreadableImage
}

/// Synchronous decoding boundary; scheduling belongs to the pipeline executor.
public protocol ImageDecoding: Sendable {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage
}

public struct ImageIODecoder: ImageDecoding {
    public init() { }
    public func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        guard request.fileURL.isFileURL && request.maximumPixelSize > 0 else {
            throw ImageDecodeError.invalidRequest
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: !request.isPreview,
            // Preview first asks only for embedded pixels; the fallback below generates from the source.
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: request.maximumPixelSize
        ]
        guard let source = CGImageSourceCreateWithURL(request.fileURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ImageDecodeError.unreadableImage
        }
        _ = try DecodeBudget.outputCost(width: width, height: height, maximumPixelSize: request.maximumPixelSize,
            bytesPerPixel: ImageSourceHeader.pixelBytes(properties), budget: request.sourceByteBudget ?? DecodeConfiguration().budget)
        var thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        if thumbnail == nil {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image = thumbnail, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw ImageDecodeError.unreadableImage }
        let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return DecodedImage(image: image, sourcePixelSize: CGSize(width: rotated ? height : width, height: rotated ? width : height),
                            formatIdentifier: CGImageSourceGetType(source) as String?)
    }
}

public final class ImageIOPipeline: ImagePipeline, CoverageRequesting, ImagePresentationPinning, PrefetchResuming,
    ThumbnailCacheProviding, Sendable {
    private let configuration: DecodeConfiguration
    private let rootResolvers = RootIdentityResolvers.shared
    private let identityResolver: any ItemIdentityResolving
    private let executor: OperationDecodeExecutor
    let admission: DecodeAdmission
    let cache: ImageMemoryCache
    private let cacheTrace: (any ResourceSnapshotTracing)?
    package let thumbnailCache: (any ThumbnailCaching)?
    private let pressureSleep: @Sendable (TimeInterval) async throws -> Void
    public init(decoder: any ImageDecoding = ImageIODecoder(), configuration: DecodeConfiguration = DecodeConfiguration(),
                identityResolver: any ItemIdentityResolving = FileItemIdentityResolver(),
                cache: ImageMemoryCache? = nil, cacheTrace: (any ResourceSnapshotTracing)? = nil,
                thumbnailCache: (any ThumbnailCaching)? = nil,
                pressureClock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                pressureSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.configuration = configuration
        self.pressureSleep = pressureSleep
        let cache = cache ?? ImageMemoryCache(capacity: configuration.cacheCapacity, budget: MemoryBudget(limit: configuration.budget),
            pressureRecoveryDelay: configuration.pressureRecoveryDelay, pressureClock: pressureClock, movementTrace: cacheTrace)
        self.cache = cache
        self.cacheTrace = cacheTrace
        self.thumbnailCache = thumbnailCache
        self.identityResolver = identityResolver
        let executor = OperationDecodeExecutor(workers: configuration.workers)
        self.executor = executor
        admission = DecodeAdmission(configuration: configuration, executor: executor, decoder: RevisionReportingDecoder(decoder: decoder),
            memory: cache.budget, release: { [cache] bytes in await cache.release(bytes: bytes) })
    }
    private func snapshotContext() async -> ResourceSnapshotContext? {
        guard let cacheTrace else { return nil }
        return ResourceSnapshotContext(tracer: cacheTrace, activity: await admission.activity())
    }
    @discardableResult public func pin(_ key: RenderKey, image: DecodedImage) async -> Bool {
        let context = await snapshotContext()
        return await cache.pin(key, image: image, context: context)
    }
    public func unpin(_ key: RenderKey) async {
        let context = await snapshotContext()
        await cache.unpin(key, context: context)
        await admission.retry()
    }
    public func memoryPressure(_ level: MemoryPressureLevel) async {
        let context = await snapshotContext()
        await cache.pressure(level, context: context)
    }
    /// Sleeps until the cache admits prefetch again; a cancelled caller returns.
    public func prefetchResumes() async {
        while !Task.isCancelled, let delay = await cache.prefetchDelay() {
            try? await pressureSleep(delay)
        }
    }
    private func header(_ request: ImageDecodeRequest) async throws -> ImageSourceHeader {
        guard request.fileURL.isFileURL, request.maximumPixelSize > 0 else {
            throw ImageLoadError(.sourceChanged, itemID: request.renderKey?.itemID, revision: request.renderKey?.revision)
        }
        let item: ItemID
        do {
            let resolver: any ItemIdentityResolving
            if let root = request.identityRoot { resolver = await rootResolvers.resolver(for: root) }
            else { resolver = identityResolver }
            item = try await resolver.identity(for: request.fileURL)
        }
        catch { throw loadFailure(error, request: request, revision: request.renderKey?.revision, unreadableKind: .corruptImage) }
        let budget = configuration.budget
        return try await withCheckedThrowingContinuation { continuation in
            executor.submit {
                continuation.resume(with: Result {
                    do { return try ImageSourceHeader.read(request, budget: budget, itemID: item) }
                    catch {
                        let revision: FileRevision
                        do { revision = try FileRevisionReader.read(request.fileURL) }
                        catch {
                            throw loadFailure(error, request: request, revision: request.renderKey?.revision,
                                              itemID: request.renderKey?.itemID ?? item, unreadableKind: .corruptImage)
                        }
                        throw loadFailure(error, request: request, revision: revision, itemID: request.renderKey?.itemID ?? item,
                                          unreadableKind: error as? ImageDecodeError == .unreadableImage
                                            ? imageFailureKind(request.fileURL) : .corruptImage)
                    }
                })
            }
        }
    }
    public func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: nil)
    }
    public func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        if Task.isCancelled { throw ImageLoadError(.cancelled) }
        let header = try await header(ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot))
        let key = await admission.key(for: header.itemID, revision: header.revision, maximumPixelSize: maximumPixelSize)
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key, identityRoot: identityRoot)
    }
    /// One header read chooses the edge from the upright source ratio (#161). The read itself asks for a
    /// one-pixel edge; the decode checks the budget at the edge chosen here.
    public func request(for fileURL: URL, covering: ThumbnailCoverage, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        if Task.isCancelled { throw ImageLoadError(.cancelled) }
        let header = try await header(ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: 1, identityRoot: identityRoot))
        let (width, height) = header.rotated ? (header.height, header.width) : (header.width, header.height)
        let edge = covering.edge(sourceWidth: Double(width), sourceHeight: Double(height))
        let key = await admission.key(for: header.itemID, revision: header.revision, maximumPixelSize: edge)
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: edge, renderKey: key, identityRoot: identityRoot)
    }
    public func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        try request.accessPermit?.check()
        return try await cache.withObservation(itemID: request.renderKey?.itemID) { observation in
            try await self.image(for: request, observation: observation)
        }
    }
    package func imageFresh(for request: ImageDecodeRequest) async throws -> DecodedImage {
        try request.accessPermit?.check()
        if Task.isCancelled {
            throw ImageLoadError(.cancelled, itemID: request.renderKey?.itemID, revision: request.renderKey?.revision)
        }
        let header = try await header(request)
        let key = await admission.key(for: header.itemID, revision: header.revision,
                                      maximumPixelSize: request.maximumPixelSize, isPreview: request.isPreview)
        if let requested = request.renderKey, requested != key {
            throw ImageLoadError(.sourceChanged, itemID: requested.itemID, revision: header.revision)
        }
        guard await cache.permits(request.priority) else {
            throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision)
        }
        let cost = try DecodeBudget.outputCost(width: header.width, height: header.height,
            maximumPixelSize: request.maximumPixelSize, bytesPerPixel: header.bytesPerPixel,
            budget: configuration.budget)
        let admittedRequest = ImageDecodeRequest(fileURL: request.fileURL, maximumPixelSize: request.maximumPixelSize,
            renderKey: key, priority: request.priority, sourceByteBudget: cost,
            isPreview: request.isPreview, identityRoot: request.identityRoot, accessPermit: request.accessPermit)
        do {
            let image = try await admission.image(admittedRequest, key: key, cost: cost,
                heavy: DecodeBudget.isHeavy(width: header.width, height: header.height),
                priority: request.priority, reuseExisting: false)
            try Task.checkCancellation()
            guard image.itemID == key.itemID, image.revision == key.revision else {
                throw ImageLoadError(.sourceChanged, itemID: key.itemID, revision: image.revision)
            }
            try request.accessPermit?.check()
            return image
        } catch {
            throw loadFailure(error, request: admittedRequest, revision: header.revision,
                              unreadableKind: .corruptImage)
        }
    }
    /// A durable hit decodes its payload inside the shared budget: it reserves the square bound for its edge
    /// (the payload's real ratio is unknown until it is read), capped at the budget.
    package func cachedImage(for ticket: ThumbnailCacheTicket) async throws -> DecodedImage? {
        guard let result = try await cachedThumbnail(for: ticket, allowingMemory: true) else { return nil }
        if result.fromMemory {
            try Task.checkCancellation()
            try ticket.request.accessPermit?.check()
            guard thumbnailCache?.memoryGenerationIsCurrent(ticket) == true else { return nil }
        }
        return result.image
    }
    package func cachedThumbnail(for ticket: ThumbnailCacheTicket, allowingMemory: Bool) async throws -> CachedThumbnailResult? {
        guard let thumbnailCache, let key = ticket.request.renderKey else { return nil }
        try Task.checkCancellation()
        try ticket.request.accessPermit?.check()
        let memoryPermitted: Bool
        if allowingMemory && thumbnailCache.supportsMemoryReuse { memoryPermitted = await cache.permits(ticket.request.priority) }
        else { memoryPermitted = false }
        let context = await snapshotContext()
        var resolvedMemoryHit = false
        if memoryPermitted, let resident = await cache.holdThumbnail(ticket, context: context) {
            let validated: DecodedImage?
            do {
                validated = try await thumbnailCache.revalidateMemory(resident, for: ticket)
                try Task.checkCancellation()
                try ticket.request.accessPermit?.check()
            } catch {
                await unpin(key)
                throw error
            }
            if let validated {
                await cache.retainThumbnail(validated, for: ticket, context: context)
                await unpin(key)
                try Task.checkCancellation()
                try ticket.request.accessPermit?.check()
                if thumbnailCache.memoryGenerationIsCurrent(ticket) {
                    await cache.thumbnailLookup(ticket, hit: true, context: context)
                    resolvedMemoryHit = true
                    // Lookup tracing can suspend this handoff; nothing may await after this final gate.
                    try Task.checkCancellation()
                    try ticket.request.accessPermit?.check()
                    if thumbnailCache.memoryGenerationIsCurrent(ticket) {
                        return CachedThumbnailResult(image: validated, fromMemory: true)
                    }
                }
            } else {
                await unpin(key)
            }
        }
        if memoryPermitted && !resolvedMemoryHit { await cache.thumbnailLookup(ticket, hit: false, context: context) }
        let edge = ticket.request.maximumPixelSize
        let cost = (try? DecodeBudget.outputCost(width: edge, height: edge, maximumPixelSize: edge, bytesPerPixel: 4,
            budget: configuration.budget)) ?? configuration.budget
        let image = try await admission.staged(ticket.request, key: key, cost: cost, priority: ticket.request.priority) { [cacheTrace] in
            // Counted when the load returned, as the disk cache counts it; a throw is neither a hit nor a miss.
            let image = try await thumbnailCache.load(ticket)
            cacheTrace?.diskLookup(hit: image != nil)
            return image
        }
        return image.map { CachedThumbnailResult(image: $0) }
    }
    package func retainThumbnail(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) async {
        guard thumbnailCache?.supportsMemoryReuse == true else { return }
        let context = await snapshotContext()
        await cache.retainThumbnail(image, for: ticket, context: context)
    }
    private func lookup(_ request: ImageDecodeRequest, key: RenderKey, observation: UUID) async throws -> ImageCacheRequest {
        let context = await snapshotContext()
        if Task.isCancelled { throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision) }
        let result = await cache.lookup(key, observation: observation, context: context)
        if Task.isCancelled {
            _ = await cache.finish(result, image: nil, context: context)
            throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision)
        }
        guard result.requiresSourceValidation else { return result }
        // One bounded reread, inside the caller's existing lease. Observe BEFORE reading so a
        // conflicting lookup during this validation still rejects us, including after eviction.
        return try await cache.withObservation(itemID: key.itemID) { freshObservation in
            let fresh = try await self.header(request)
            let freshKey = await self.admission.key(for: fresh.itemID, revision: fresh.revision,
                maximumPixelSize: request.maximumPixelSize, isPreview: request.isPreview)
            guard freshKey == key else {
                throw ImageLoadError(.sourceChanged, itemID: key.itemID, revision: fresh.revision)
            }
            if Task.isCancelled { throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision) }
            let context = await self.snapshotContext()
            if Task.isCancelled { throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision) }
            let result = await self.cache.lookup(key, observation: freshObservation, sourceRevalidated: true, context: context)
            if Task.isCancelled {
                _ = await self.cache.finish(result, image: nil, context: context)
                throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision)
            }
            return result
        }
    }
    private func image(for request: ImageDecodeRequest, observation: UUID) async throws -> DecodedImage {
        if Task.isCancelled { throw ImageLoadError(.cancelled, itemID: request.renderKey?.itemID, revision: request.renderKey?.revision) }
        let header = try await header(request)
        if Task.isCancelled { throw ImageLoadError(.cancelled, itemID: header.itemID, revision: header.revision) }
        let key = await admission.key(for: header.itemID, revision: header.revision, maximumPixelSize: request.maximumPixelSize, isPreview: request.isPreview)
        // An explicit request revision must still match at the last predecode check.
        if let requested = request.renderKey, requested != key {
            throw ImageLoadError(.sourceChanged, itemID: requested.itemID, revision: header.revision)
        }
        guard await cache.permits(request.priority) else {
            throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision)
        }
        let cached = try await lookup(request, key: key, observation: observation)
        if cached.sourceChanged { throw ImageLoadError(.sourceChanged, itemID: key.itemID, revision: key.revision) }
        if let image = cached.image {
            if Task.isCancelled { throw ImageLoadError(.cancelled, itemID: key.itemID, revision: key.revision) }
            try request.accessPermit?.check()
            return image
        }
        let cost = try DecodeBudget.outputCost(width: header.width, height: header.height, maximumPixelSize: request.maximumPixelSize, bytesPerPixel: header.bytesPerPixel, budget: configuration.budget)
        let admittedRequest = ImageDecodeRequest(fileURL: request.fileURL, maximumPixelSize: request.maximumPixelSize,
            renderKey: key, priority: request.priority, sourceByteBudget: cost, isPreview: request.isPreview, identityRoot: request.identityRoot, accessPermit: request.accessPermit)
        do {
            let image = try await admission.image(admittedRequest, key: key, cost: cost,
                heavy: DecodeBudget.isHeavy(width: header.width, height: header.height), priority: request.priority)
            let context = await snapshotContext()
            let retained = await cache.finish(cached, image: image, context: context, accessPermit: request.accessPermit)
            try Task.checkCancellation()
            try request.accessPermit?.check()
            if retained == nil, image.itemID == key.itemID, image.revision == key.revision {
                throw ImageLoadError(.sourceChanged, itemID: key.itemID, revision: image.revision)
            }
            return retained ?? image
        } catch {
            let context = await snapshotContext()
            _ = await cache.finish(cached, image: nil, context: context)
            throw loadFailure(error, request: admittedRequest, revision: header.revision, unreadableKind: .corruptImage)
        }
    }
}

/// Runs inside the bounded executor, including the post-decode filesystem read.
private struct RevisionReportingDecoder: ImageDecoding {
    let decoder: any ImageDecoding
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        try request.accessPermit?.check()
        let decoded = try decoder.decode(request)
        try request.accessPermit?.check()
        return DecodedImage(image: decoded.image, sourcePixelSize: decoded.sourcePixelSize,
            formatIdentifier: decoded.formatIdentifier, revision: try FileRevisionReader.read(request.fileURL),
            itemID: request.renderKey?.itemID, accessPermit: request.accessPermit ?? decoded.accessPermit)
    }
}

/// Called only on the bounded executor. Extensions are not evidence of an image format.
private func imageFailureKind(_ url: URL) -> ImageLoadError.Kind {
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetType(source) != nil {
        return .corruptImage
    }
    // A recognised signature identifies damaged PNG data even if ImageIO cannot construct a source.
    let file = try? FileHandle(forReadingFrom: url)
    let prefix = try? file?.read(upToCount: 512)
    try? file?.close()
    if prefix?.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) == true { return .corruptImage }
    // With no decoder signature, binary data advertised as an image is treated as corrupt.
    // Plain text remains unsupported regardless of its suffix (including a misleading .jpg).
    if prefix?.contains(0) == true, UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
        return .corruptImage
    }
    return .unsupportedFormat
}

private func loadFailure(_ error: Error, request: ImageDecodeRequest, revision: FileRevision?, itemID: ItemID? = nil,
                         unreadableKind: ImageLoadError.Kind) -> Error {
    let kind: ImageLoadError.Kind
    switch error {
    case ImageDecodeError.budgetExceeded: kind = .resourceLimit
    case ImageDecodeError.invalidRequest: kind = .sourceChanged
    case ImageDecodeError.unreadableImage: kind = unreadableKind
    case is CancellationError: kind = .cancelled
    default:
        let sourceError = error as NSError
        let missing = (sourceError.domain == NSCocoaErrorDomain &&
            [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(sourceError.code)) ||
            (sourceError.domain == NSPOSIXErrorDomain && sourceError.code == Int(ENOENT))
        guard missing else { return error } // Includes permission and FileAccess errors, unchanged.
        kind = .sourceChanged
    }
    return ImageLoadError(kind, itemID: itemID ?? request.renderKey?.itemID, revision: revision ?? request.renderKey?.revision)
}
