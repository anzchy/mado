import CoreGraphics
import Foundation
import Testing
import MadoCore
import MadoApplication

private func t229PermissionError() -> NSError {
    NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 13)])
}
private struct T229PermissionCache: ThumbnailCaching {
    let phase: String
    func prepare(_ request: ImageDecodeRequest) throws -> ThumbnailCacheTicket? {
        if phase == "prepare" { throw t229PermissionError() }
        let render = request.renderKey!, sha = String(repeating: "a", count: 64)
        return ThumbnailCacheTicket(request: request,
            key: DurableThumbnailKey(renderKey: render, sourceSHA256: sha)!, sourceSHA256: sha)
    }
    func load(_ ticket: ThumbnailCacheTicket) throws -> DecodedImage? {
        if phase == "load" { throw t229PermissionError() }
        if phase == "hit" {
            let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
                revision: ticket.request.renderKey?.revision, itemID: ticket.request.renderKey?.itemID)
        }
        return nil
    }
    func store(_ image: DecodedImage, for ticket: ThumbnailCacheTicket) throws {
        if phase == "store" { throw t229PermissionError() }
    }
}
private actor T229PermissionPipeline: ThumbnailCacheProviding {
    let thumbnailCache: (any ThumbnailCaching)?
    private(set) var decodes = 0
    init(phase: String) { thumbnailCache = T229PermissionCache(phase: phase) }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        let key = RenderKey(itemID: .rootRelative(rootID: AccessRootID(), relativePath: "a.png"),
            revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize)
        return ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: key)
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage {
        decodes += 1
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1),
            revision: request.renderKey?.revision, itemID: request.renderKey?.itemID)
    }
    func imageFresh(for request: ImageDecodeRequest) -> DecodedImage { image(for: request) }
}

@Test(arguments: ["prepare", "load", "store"]) func t229CachePermissionFailureCannotBecomeFallbackPixels(phase: String) async throws {
    let access = AccessProbe(), pipeline = T229PermissionPipeline(phase: phase)
    let source = try await AccessImageSource.open(.fileGrant(URL(fileURLWithPath: "/tmp/t229-permission.png")),
        access: access, pipeline: pipeline)
    do { _ = try await source.image(maximumPixelSize: 64); Issue.record("permission failure delivered pixels") }
    catch { #expect((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == 257) }
    #expect(await pipeline.decodes == (phase == "store" ? 1 : 0))
    #expect(await access.count() == 0)
}

@Test func t229PermissionSignalIncludesUnderlyingPOSIXWithoutGuessingOtherErrors() {
    #expect(AccessReadFailure.isPermissionDenied(t229PermissionError()))
    #expect(AccessReadFailure.isPermissionDenied(NSError(domain: "wrapper", code: 0,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: 1)])))
    #expect(!AccessReadFailure.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: 2)))
    #expect(!AccessReadFailure.isPermissionDenied(CancellationError()))
}

@MainActor @Test func t229SourceTagsBothDecodeAndDurableHitWithCapturedPermit() async throws {
    let state = AccessState(), id = AccessRootID()
    state.register(id, volumeUUID: "a")
    let permit = try #require(state.permit(for: id))
    for phase in ["miss", "hit"] {
        let access = AccessProbe(), pipeline = T229PermissionPipeline(phase: phase)
        let source = try await AccessImageSource.open(.fileGrant(URL(fileURLWithPath: "/tmp/t229-tag.png")),
            access: access, pipeline: pipeline, accessPermit: permit)
        let (request, image) = try await source.image(maximumPixelSize: 64)
        #expect(request.accessPermit === permit)
        #expect(image.accessPermit === permit)
        #expect(await pipeline.decodes == (phase == "hit" ? 0 : 1))
        await source.close()
        #expect(await access.count() == 0)
    }
}
