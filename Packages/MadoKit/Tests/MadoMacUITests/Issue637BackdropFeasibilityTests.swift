import AppKit
import CoreImage
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private func issue637Image(alpha: Bool = false) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
        bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.clear.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    for row in 0..<8 {
        for column in 0..<8 {
            if alpha && (row == 0 || column == 0 || row == 7 || column == 7) { continue }
            context.setFillColor(NSColor(srgbRed: CGFloat(column) / 7, green: CGFloat(row) / 7,
                blue: CGFloat((column + row) % 4) / 3, alpha: 1).cgColor)
            context.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
        }
    }
    return try #require(context.makeImage())
}

@MainActor private func issue637Canvas() -> (CanvasView, NSWindow) {
    _ = NSApplication.shared
    let canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 160, height: 120), session: ViewerSession())
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 160, height: 120),
        styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = canvas
    canvas.appearance = NSAppearance(named: .aqua)
    return (canvas, window)
}

@MainActor private func issue637Raster(_ canvas: CanvasView, scale: Int) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.bounds.width) * scale, pixelsHigh: Int(canvas.bounds.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = canvas.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    return rep
}

@MainActor private func issue637Pixel(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
    let rep = NSBitmapImageRep(cgImage: image)
    return try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
}

@MainActor private func issue637CompareCrop(_ canvas: CanvasView, rect: CGRect, scale: Int) throws {
    let reference = try issue637Raster(canvas, scale: scale)
    let actual = try #require(ChromeBackdropRenderer.render(canvas.backdropFrame, pillRect: rect,
        backingScale: CGFloat(scale), blurRadius: 0, saturation: 1))
    #expect(actual.width == Int(rect.width) * scale)
    #expect(actual.height == Int(rect.height) * scale)
    for y in stride(from: 4, to: actual.height - 4, by: 5) {
        for x in stride(from: 4, to: actual.width - 4, by: 5) {
            let expected = try #require(reference.colorAt(x: Int(rect.minX) * scale + x,
                y: Int(rect.minY) * scale + y)?.usingColorSpace(.sRGB))
            let observed = try issue637Pixel(actual, x: x, y: y)
            let delta = max(abs(expected.redComponent - observed.redComponent),
                abs(expected.greenComponent - observed.greenComponent),
                abs(expected.blueComponent - observed.blueComponent))
            #expect(delta <= 2.0 / 255.0, "crop mismatch at \(x),\(y), scale \(scale)")
        }
    }
}

@Test @MainActor func issue637BackdropCropTracksCanvasFitZoomPanAndReplacement() throws {
    let (canvas, window) = issue637Canvas()
    defer { window.close() }
    canvas.install(DecodedImage(image: try issue637Image(), sourcePixelSize: CGSize(width: 64, height: 64)))
    let pill = CGRect(x: 25, y: 42, width: 100, height: 38)
    try issue637CompareCrop(canvas, rect: pill, scale: 1)
    canvas.magnify(by: log(2), at: CGPoint(x: 80, y: 60))
    try issue637CompareCrop(canvas, rect: pill, scale: 1)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(CGPoint(x: 80, y: 60), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1))
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: canvas.convert(CGPoint(x: 89, y: 65), to: nil),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    canvas.mouseDown(with: down); canvas.mouseDragged(with: drag)
    try issue637CompareCrop(canvas, rect: pill, scale: 1)
    canvas.install(DecodedImage(image: try issue637Image(alpha: true), sourcePixelSize: CGSize(width: 64, height: 64)))
    try issue637CompareCrop(canvas, rect: pill, scale: 1)
}

@Test @MainActor func issue637BackdropCropMatchesCanvasAtTwoPixelScaleAndImageEdge() throws {
    let (canvas, window) = issue637Canvas()
    defer { window.close() }
    canvas.appearance = NSAppearance(named: .darkAqua)
    canvas.install(DecodedImage(image: try issue637Image(alpha: true), sourcePixelSize: CGSize(width: 64, height: 64)))
    try issue637CompareCrop(canvas, rect: CGRect(x: 32, y: 44, width: 96, height: 38), scale: 2)
}

@Test @MainActor func issue637BackdropInvalidationPublishesNewestFrameAndClearsFailure() throws {
    let (canvas, window) = issue637Canvas()
    defer { window.close() }
    var generations: [UInt64] = []
    canvas.onBackdropChange = { generations.append($0.generation) }
    canvas.install(DecodedImage(image: try issue637Image(), sourcePixelSize: CGSize(width: 64, height: 64)))
    let first = canvas.backdropFrame
    canvas.magnify(by: log(1.25), at: CGPoint(x: 80, y: 60))
    let second = canvas.backdropFrame
    canvas.install(DecodedImage(image: try issue637Image(alpha: true), sourcePixelSize: CGSize(width: 64, height: 64)))
    let third = canvas.backdropFrame
    canvas.showFailure()
    let failure = canvas.backdropFrame
    #expect(first.generation < second.generation && second.generation < third.generation && third.generation < failure.generation)
    #expect(generations.last == failure.generation)
    #expect(failure.image == nil)
    #expect(ChromeBackdropRenderer.render(failure, pillRect: CGRect(x: 20, y: 20, width: 0, height: 38),
        backingScale: 1, blurRadius: 20, saturation: 1.6) == nil)
}

@Test @MainActor func issue637BackdropUsesDecodedOrientationWithoutRotatingAgain() async throws {
    let (canvas, window) = issue637Canvas()
    defer { window.close() }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for orientation in [1, 3, 6, 8] {
        let url = root.appendingPathComponent("TestAssets/synthetic/orientation-\(orientation).tiff")
        let decoded = try await ImageIOPipeline().image(for: ImageDecodeRequest(fileURL: url,
            maximumPixelSize: 128, isPreview: true))
        canvas.install(decoded)
        try issue637CompareCrop(canvas, rect: CGRect(x: 26, y: 41, width: 104, height: 38), scale: 1)
    }
}

@Test @MainActor func issue637BackdropBlurCompositesTransparentEdgeBeforeFiltering() throws {
    let (canvas, window) = issue637Canvas()
    defer { window.close() }
    canvas.appearance = NSAppearance(named: .darkAqua)
    canvas.install(DecodedImage(image: try issue637Image(alpha: true), sourcePixelSize: CGSize(width: 64, height: 64)))
    let rect = CGRect(x: 36, y: 41, width: 88, height: 38)
    let radius: CGFloat = 6
    let actual = try #require(ChromeBackdropRenderer.render(canvas.backdropFrame, pillRect: rect,
        backingScale: 1, blurRadius: radius, saturation: 1.6))
    let full = try issue637Raster(canvas, scale: 1)
    let fullImage = try #require(full.cgImage)
    let gaussian = try #require(CIFilter(name: "CIGaussianBlur"))
    gaussian.setValue(CIImage(cgImage: fullImage), forKey: kCIInputImageKey)
    gaussian.setValue(radius, forKey: kCIInputRadiusKey)
    let gaussianOutput = try #require(gaussian.outputImage)
    let saturated = try #require(CIFilter(name: "CIColorControls"))
    saturated.setValue(gaussianOutput, forKey: kCIInputImageKey)
    saturated.setValue(1.6, forKey: kCIInputSaturationKey)
    let saturatedOutput = try #require(saturated.outputImage)
    let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    let expected = try #require(context.createCGImage(saturatedOutput, from:
        CGRect(x: rect.minX, y: canvas.bounds.height - rect.maxY, width: rect.width, height: rect.height)))
    for (x, y) in [(8, 18), (24, 18), (44, 18), (68, 18)] {
        let observed = try issue637Pixel(actual, x: x, y: y)
        let reference = try issue637Pixel(expected, x: x, y: y)
        #expect(observed.alphaComponent > 0.99)
        #expect(abs(observed.redComponent - reference.redComponent) < 3.0 / 255.0)
        #expect(abs(observed.greenComponent - reference.greenComponent) < 3.0 / 255.0)
        #expect(abs(observed.blueComponent - reference.blueComponent) < 3.0 / 255.0)
    }
    #expect(try issue637Pixel(actual, x: 0, y: 0).alphaComponent < 0.01)
}

@Test @MainActor func issue637BackdropAppearanceResizeAndBackingEventsPublishNewFrame() throws {
    let (canvas, window) = issue637Canvas()
    defer { window.close() }
    canvas.install(DecodedImage(image: try issue637Image(alpha: true), sourcePixelSize: CGSize(width: 64, height: 64)))
    let initial = canvas.backdropFrame
    canvas.appearance = NSAppearance(named: .darkAqua)
    canvas.viewDidChangeEffectiveAppearance()
    let dark = canvas.backdropFrame
    canvas.setFrameSize(NSSize(width: 180, height: 140))
    let resized = canvas.backdropFrame
    canvas.viewDidChangeBackingProperties()
    let backing = canvas.backdropFrame
    #expect(initial.generation < dark.generation && dark.generation < resized.generation && resized.generation < backing.generation)
    #expect(dark.background.usingColorSpace(.sRGB) != initial.background.usingColorSpace(.sRGB))
    #expect(resized.canvasSize == CGSize(width: 180, height: 140))
}

@Test @MainActor func issue637BackdropDropsOutOfOrderResultsAndHiddenResult() throws {
    let red = try issue637Image()
    let green = try issue637Image(alpha: true)
    let presentation = ChromeBackdropPresentation()
    presentation.request(generation: 1)
    presentation.request(generation: 2)
    presentation.complete(red, generation: 1)
    #expect(presentation.visibleImage == nil)
    presentation.complete(green, generation: 2)
    #expect(presentation.visibleImage === green)
    #expect(presentation.visibleGeneration == 2)
    presentation.request(generation: 3)
    presentation.setHidden(true)
    presentation.complete(red, generation: 3)
    #expect(presentation.visibleImage == nil)
    presentation.setHidden(false)
    #expect(presentation.visibleImage == nil)
}

@Test @MainActor func issue637BackdropBurstCoalescesToNewestAndSuppressesHiddenWork() {
    let presentation = ChromeBackdropPresentation()
    for generation in 1...50 { presentation.request(generation: UInt64(generation)) }
    #expect(presentation.takePendingGeneration() == 50)
    #expect(presentation.takePendingGeneration() == nil)
    presentation.request(generation: 50)
    #expect(presentation.takePendingGeneration() == nil)
    presentation.setHidden(true)
    presentation.request(generation: 51)
    #expect(presentation.takePendingGeneration() == nil)
    presentation.setHidden(false)
    presentation.request(generation: 52)
    #expect(presentation.takePendingGeneration() == 52)
}
