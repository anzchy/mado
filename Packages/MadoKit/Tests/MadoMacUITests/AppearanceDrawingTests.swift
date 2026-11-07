import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private func appearanceDrawingBitmap(_ canvas: CanvasView) throws -> NSBitmapImageRep {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width),
        pixelsHigh: Int(canvas.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = canvas.bounds.size
    bitmap.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
    return bitmap
}

@Suite(.serialized) @MainActor struct AppearanceDrawingTests {
    @Test func appearanceDrawingLifecycleInvalidatesCanvas() {
        _ = NSApplication.shared
        let canvas = CanvasView(frame: .init(x: 0, y: 0, width: 320, height: 240), session: ViewerSession())
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 320, height: 240),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        defer { window.close() }
        canvas.needsDisplay = false
        // Exercise the public native lifecycle callback, without claiming OS delivery.
        canvas.viewDidChangeEffectiveAppearance()
        #expect(canvas.needsDisplay)
    }

    @Test func appearanceDrawingSystemManualCrossProductAtLifecycle() throws {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        let store = InMemoryDisplayPreferencesStore(DisplayPreferences(alwaysShowTools: true))
        let adapter = WindowAppearanceAdapter(preferencesStore: store)
        let session = ViewerSession(preferencesStore: store)
        let window = NSWindow(contentRect: .init(x: -20000, y: -20000, width: 640, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: .init(x: 0, y: 0, width: 640, height: 400))
        let canvas = CanvasView(frame: content.bounds, session: session)
        content.addSubview(canvas)
        let chrome = ViewerChromeOverlay(frame: content.bounds, session: session)
        content.addSubview(chrome)
        window.contentView = content
        adapter.register(window)
        let context = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8,
            bytesPerRow: 160, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: 40, height: 20))
        canvas.install(DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: .init(width: 40, height: 20)))
        canvas.magnify(by: log(2), at: .init(x: 320, y: 200))
        #expect(session.zoomMode == .custom(2))
        #expect(window.makeFirstResponder(canvas))
        let responder = try #require(window.firstResponder)
        let generation = session.imageLoader.generation
        let locks = session.chrome.locks

        for preference: DisplayAppearance in [.system, .light, .dark, .system] {
            store.value.appearance = preference
            for inherited: NSAppearance.Name in [.aqua, .darkAqua, .aqua] {
                // In-process source only; the real macOS setting is never modified.
                application.appearance = try #require(NSAppearance(named: inherited))
                let expected: NSAppearance.Name = preference == .system ? inherited : preference == .dark ? .darkAqua : .aqua
                #expect(window.appearance?.name == (preference == .system ? nil : expected))
                #expect(window.effectiveAppearance.name == expected)
                #expect(canvas.effectiveAppearance.name == expected)
                #expect(chrome.effectiveAppearance.name == expected)
                // Offscreen unit evidence proves each lifecycle effect, not OS notification delivery.
                canvas.viewDidChangeEffectiveAppearance()
                chrome.viewDidChangeEffectiveAppearance()
                let dark = expected == .darkAqua
                let canvasBytes: [CGFloat] = dark ? [15, 17, 21] : [255, 255, 255]
                let chromeBytes: [CGFloat] = dark ? [20, 24, 33] : [255, 255, 255]
                let canvasRGB = canvasBytes.map { $0 / 255 }
                let chromeRGB = chromeBytes.map { $0 / 255 }
                let bitmap = try appearanceDrawingBitmap(canvas)
                let background = try #require(bitmap.colorAt(x: 0, y: 0))
                #expect(abs(background.redComponent - canvasRGB[0]) < 0.02)
                #expect(abs(background.greenComponent - canvasRGB[1]) < 0.02)
                #expect(abs(background.blueComponent - canvasRGB[2]) < 0.02)
                let imagePixel = try #require(bitmap.colorAt(x: 320, y: 200))
                #expect(imagePixel.redComponent > 0.9)
                #expect(imagePixel.greenComponent < 0.1)
                #expect(imagePixel.blueComponent < 0.1)
                for group in chrome.groups {
                    let cg = try #require(group.layer?.backgroundColor)
                    let color = try #require(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
                    #expect(abs(color.redComponent - chromeRGB[0]) < 0.00001)
                    #expect(abs(color.greenComponent - chromeRGB[1]) < 0.00001)
                    #expect(abs(color.blueComponent - chromeRGB[2]) < 0.00001)
                }
                #expect(canvas.hasImage)
                #expect(session.imageLoader.generation == generation)
                #expect(session.zoomMode == .custom(2))
                #expect(session.chrome.isPinned)
                #expect(session.chrome.locks == locks)
                #expect(window.firstResponder === responder)
            }
        }
    }
}
