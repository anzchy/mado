import Foundation
import CoreGraphics
import Testing
import MadoCore

@Test func previewAlwaysPrecedesViewportDetailAndNeverExceeds512() {
    #expect(CanvasDecodePolicy.previewMaximumPixelSize == 512)
    #expect(CanvasDecodePolicy.maximumPixelSize(source: CGSize(width: 8000, height: 6000), viewport: CGSize(width: 1920, height: 1080), zoom: 0.18) == 1920)
    #expect(CanvasDecodePolicy.maximumPixelSize(source: CGSize(width: 8000, height: 6000), viewport: CGSize(width: 1920, height: 1080), zoom: 1) == 8000)
}

@Test func previewAtViewportSizeStillRequiresFullImageDecode() throws {
    let context = try #require(CGContext(data: nil, width: 160, height: 120, bitsPerComponent: 8, bytesPerRow: 640,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 2000, height: 1500))
    var progress = CanvasDecodeProgress()
    #expect(progress.nextMaximum(desired: 512) == 512)
    progress.completed(image, isPreview: true)
    #expect(progress.completedMaximum == 160)
    #expect(progress.previewCompleted)
    #expect(progress.nextMaximum(desired: 512) == 512)
    progress.completed(image, isPreview: false)
    #expect(progress.nextMaximum(desired: 160) == nil)
    // A tiny source is complete at source resolution even in a larger viewport.
    var small = CanvasDecodeProgress()
    let tiny = DecodedImage(image: image.image, sourcePixelSize: CGSize(width: 160, height: 120))
    small.completed(tiny, isPreview: true)
    #expect(small.nextMaximum(desired: 512) == 160)
    small.completed(tiny, isPreview: false)
    #expect(small.nextMaximum(desired: 512) == nil)
}

@Test func revisionMismatchRetriesCurrentGenerationOnceAndResetsDecodeProgress() throws {
    let token = PresentationToken(binding: UUID(), generation: UUID())
    let stale = PresentationToken(binding: token.binding, generation: UUID())
    let rebound = PresentationToken(binding: UUID(), generation: token.generation)
    var progress = CanvasDecodeProgress()
    let retry1 = progress.restartForRevision(request: stale, current: token)
    #expect(!retry1)
    let retry2 = progress.restartForRevision(request: rebound, current: token)
    #expect(!retry2)
    let retry3 = progress.restartForRevision(request: token, current: token)
    #expect(retry3)
    let retry4 = progress.restartForRevision(request: token, current: token)
    #expect(!retry4)
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    progress.completed(DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 1, height: 1)), isPreview: false)
    #expect(progress.completedMaximum == 1)
    #expect(progress.nextMaximum(desired: 1000) == nil)
    // A successful install ends the consecutive-mismatch sequence.
    let retry5 = progress.restartForRevision(request: token, current: token)
    #expect(retry5)
    #expect(progress.completedMaximum == 0)
    #expect(!progress.previewCompleted)
    #expect(progress.nextMaximum(desired: 1000) == 512)
    #expect(progress.nextMaximum(desired: 0) == nil)
    let retry6 = progress.restartForRevision(request: token, current: token)
    #expect(!retry6)
}
