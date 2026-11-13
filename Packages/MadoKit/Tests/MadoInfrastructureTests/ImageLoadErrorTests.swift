import Foundation
import ImageIO
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func loadErrorsClassifyRealInputs() async throws {
    let text = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
    try Data("This is not an image".utf8).write(to: text)
    defer { try? FileManager.default.removeItem(at: text) }
    for (url, kind) in [(text, ImageLoadError.Kind.unsupportedFormat),
                        (fixture("truncated.png"), .corruptImage), (fixture("corrupt.png"), .corruptImage),
                        (fixture("oversize-header.png"), .resourceLimit)] {
        do {
            _ = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: url, maximumPixelSize: 512))
            Issue.record("Expected a typed failure")
        } catch {
            let failure = try #require(error as? ImageLoadError)
            #expect(failure.kind == kind)
            #expect(failure.revision?.byteCount == (try Data(contentsOf: url)).count)
        }
    }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsCarryKnownIdentityAndRevision() async throws {
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 123, modificationDate: nil)
    let key = RenderKey(itemID: item, revision: revision, maximumPixelSize: 128)
    do {
        _ = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: fixture("orientation-1.tiff"), maximumPixelSize: 128, renderKey: key))
        Issue.record("Expected changed source")
    } catch {
        let failure = try #require(error as? ImageLoadError)
        #expect(failure.kind == .sourceChanged)
        #expect(failure.itemID == item)
        #expect(failure.revision != nil)
    }
    for kind in ImageLoadError.Kind.allCases {
        let failure = ImageLoadError(kind, itemID: item, revision: revision)
        #expect(failure.kind == kind)
        #expect(failure.itemID == item)
        #expect(failure.revision == revision)
    }
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await ImageIOPipeline().request(for: fixture("orientation-1.tiff"), maximumPixelSize: 128)
    }
    do { _ = try await task.value; Issue.record("Expected cancellation") }
    catch { #expect((error as? ImageLoadError)?.kind == .cancelled) }
}

func loadError(_ kind: ImageLoadError.Kind) -> @Sendable (any Error) -> Bool {
    { ($0 as? ImageLoadError)?.kind == kind }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsRejectPNGWithoutEndChunk() async throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: file) }
    let complete = try Data(contentsOf: fixture("alpha-gradient.png"))
    #expect(Array(complete.suffix(8).prefix(4)) == [73, 69, 78, 68]) // IEND
    try Data(complete.dropLast(12)).write(to: file)

    // ImageIO still sees a complete image. The missing terminal chunk is the only
    // reason the header reader can reject these otherwise intact PNG bytes.
    let source = try #require(CGImageSourceCreateWithURL(file as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary))
    #expect(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil)
    #expect(CGImageSourceGetStatus(source) == .statusComplete)
    #expect(CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete)
    _ = try ImageSourceHeader.read(ImageDecodeRequest(fileURL: fixture("alpha-gradient.png"), maximumPixelSize: 128),
        budget: 1_000_000, itemID: .ephemeral(UUID()))
    #expect(throws: ImageDecodeError.unreadableImage) {
        try ImageSourceHeader.read(ImageDecodeRequest(fileURL: file, maximumPixelSize: 128),
            budget: 1_000_000, itemID: .ephemeral(UUID()))
    }
    do {
        _ = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: file, maximumPixelSize: 128))
        Issue.record("Expected missing PNG end chunk failure")
    } catch {
        let failure = try #require(error as? ImageLoadError)
        #expect(failure.kind == .corruptImage)
        #expect(failure.itemID != nil)
        #expect(failure.revision?.byteCount == complete.count - 12)
    }
}

private struct LoadFailureDecoder: ImageDecoding {
    let failure: any Error
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage { throw failure }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsKeepContextAndPassThroughAccessErrors() async throws {
    let failures: [(any Error, ImageLoadError.Kind)] = [
        (ImageDecodeError.invalidRequest, .sourceChanged), (ImageDecodeError.unreadableImage, .corruptImage),
        (ImageDecodeError.budgetExceeded, .resourceLimit), (CancellationError(), .cancelled)
    ]
    for (failure, kind) in failures {
        let pipeline = ImageIOPipeline(decoder: LoadFailureDecoder(failure: failure))
        let request = try await pipeline.request(for: fixture("orientation-1.tiff"), maximumPixelSize: 128)
        do { _ = try await pipeline.image(for: request); Issue.record("Expected decoder failure") }
        catch {
            let actual = try #require(error as? ImageLoadError)
            #expect(actual.kind == kind)
            #expect(actual.itemID == request.renderKey?.itemID)
            #expect(actual.revision == request.renderKey?.revision)
        }
    }
    let access = ImageIOPipeline(decoder: LoadFailureDecoder(failure: FileAccessError.startFailed))
    await #expect(throws: FileAccessError.startFailed) {
        try await access.image(for: ImageDecodeRequest(fileURL: fixture("orientation-1.tiff"), maximumPixelSize: 128))
    }
}

private struct DisappearingResourceReader: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        try FileManager.default.removeItem(at: fileURL)
        return FileResourceIdentity(volumeUUID: "VOL", fileIdentifier: "42")
    }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsSourceDisappearingAfterIdentityKeepsKnownContext() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let item = ItemID.rootRelative(rootID: tree.id, relativePath: "b.png")
    let revision = FileRevision(byteCount: 5, modificationDate: nil)
    let key = RenderKey(itemID: item, revision: revision, maximumPixelSize: 128)
    let pipeline = ImageIOPipeline(identityResolver: FileItemIdentityResolver(root: tree.scope, reader: DisappearingResourceReader()))
    do {
        _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: tree.file, maximumPixelSize: 128, renderKey: key))
        Issue.record("Expected disappeared source")
    } catch {
        let failure = try #require(error as? ImageLoadError)
        #expect(failure.kind == .sourceChanged)
        #expect(failure.itemID == item)
        #expect(failure.revision == revision)
    }
}

private struct RemovingAfterDecode: ImageDecoding {
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        let decoded = try ImageIODecoder().decode(request)
        try FileManager.default.removeItem(at: request.fileURL)
        return decoded
    }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsRealMissingSourceKeepsPreparedContext() async throws {
    for afterDecode in [false, true] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let pipeline = ImageIOPipeline(decoder: RemovingAfterDecode())
        let request = try await pipeline.request(for: url, maximumPixelSize: 128)
        if !afterDecode { try FileManager.default.removeItem(at: url) }
        do { _ = try await pipeline.image(for: request); Issue.record("Expected missing source failure") }
        catch {
            let receivedTypedFailure = error is ImageLoadError
            #expect(receivedTypedFailure)
            guard let failure = error as? ImageLoadError else { continue }
            #expect(failure.kind == .sourceChanged)
            #expect(failure.itemID == request.renderKey?.itemID)
            #expect(failure.revision == request.renderKey?.revision)
        }
    }
}

private struct ResourceReadingFailure: ItemIdentityResolving {
    let failure: NSError
    func identity(for fileURL: URL) async throws -> ItemID { throw failure }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsPreserveFoundationPermissionErrors() async throws {
    for failure in [NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError),
                    NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))] {
        for atIdentity in [true, false] {
            let pipeline = atIdentity
                ? ImageIOPipeline(identityResolver: ResourceReadingFailure(failure: failure))
                : ImageIOPipeline(decoder: LoadFailureDecoder(failure: failure))
            do {
                _ = try await pipeline.image(for: ImageDecodeRequest(fileURL: fixture("orientation-1.tiff"), maximumPixelSize: 128))
                Issue.record("Expected access failure")
            } catch { #expect((error as NSError) == failure) }
        }
    }
}

private struct RealReadingThenRemoving: FileIdentityResourceReading {
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        let identity = try URLIdentityResourceReader().identity(for: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        return identity
    }
}

@Test(.timeLimit(.minutes(2))) func loadErrorsMissingUnpreparedSourceRetainsResolvedItem() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let resolver = FileItemIdentityResolver(root: tree.scope, reader: RealReadingThenRemoving())
    let pipeline = ImageIOPipeline(identityResolver: resolver)
    do {
        _ = try await pipeline.request(for: tree.file, maximumPixelSize: 128)
        Issue.record("Expected source to disappear after resolving its identity")
    } catch {
        let failure = try #require(error as? ImageLoadError)
        #expect(failure.kind == .sourceChanged)
        #expect(failure.itemID == .rootRelative(rootID: tree.id, relativePath: "b.png"))
        #expect(failure.revision == nil)
    }
}
