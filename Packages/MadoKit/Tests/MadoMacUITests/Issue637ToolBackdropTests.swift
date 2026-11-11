import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func issue637BackdropRasterRejectsArchivedConstruction() {
    #expect(ChromeBackdropRasterView(coder: NSKeyedArchiver(requiringSecureCoding: false)) == nil)
}

@Test @MainActor func issue637ScaleAccessibilityLabelsMatchVisibleModes() {
    #expect(ScaleIndicator.modeLabel(actualPixels: false, customZoom: nil) == "Fit window")
    #expect(ScaleIndicator.modeLabel(actualPixels: true, customZoom: nil) == "1:1 · 100%")
    #expect(ScaleIndicator.modeLabel(actualPixels: false, customZoom: 1.25) == "125%")
}

@MainActor private func issue637ToolImage(grey: CGFloat, stripes: Bool = false, size: CGSize = CGSize(width: 1280, height: 800)) throws -> CGImage {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: Int(size.width), height: Int(size.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1).cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    if stripes {
        for x in stride(from: 0, to: Int(size.width), by: 8) {
            context.setFillColor((x / 8).isMultiple(of: 2) ? NSColor.black.cgColor : NSColor.white.cgColor)
            context.fill(CGRect(x: CGFloat(x), y: 0, width: 4, height: size.height))
        }
    }
    return try #require(context.makeImage())
}

@MainActor private func issue637ToolFrame(_ image: CGImage, generation: UInt64, background: CGFloat = 0.5) -> CanvasBackdropFrame {
    let size = CGSize(width: image.width, height: image.height)
    return CanvasBackdropFrame(image: image, sourceSize: size,
        transform: CanvasTransform(backingScale: 1), canvasSize: size,
        background: NSColor(srgbRed: background, green: background, blue: background, alpha: 1), generation: generation)
}

@MainActor private func issue637ToolRaster(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: NSColorSpace.sRGB.iccProfileData)
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@MainActor private func issue637RawSRGB(_ rep: NSBitmapImageRep, x: Int, y: Int) throws -> NSColor {
    #expect(rep.cgImage?.colorSpace?.name == CGColorSpace.sRGB)
    #expect(rep.samplesPerPixel == 4 && rep.bitsPerPixel == 32 && rep.bitmapFormat.rawValue == 0)
    let data = try #require(rep.bitmapData)
    let index = y * rep.bytesPerRow + x * 4
    let alphaByte = CGFloat(data[index + 3])
    let alpha = alphaByte / 255
    return NSColor(srgbRed: alphaByte > 0 ? CGFloat(data[index]) / alphaByte : 0,
                   green: alphaByte > 0 ? CGFloat(data[index + 1]) / alphaByte : 0,
                   blue: alphaByte > 0 ? CGFloat(data[index + 2]) / alphaByte : 0,
                   alpha: alpha)
}

@MainActor private func issue637ToolSurface(_ group: NSView) throws -> NSView {
    try #require(group.subviews.first { $0.accessibilityIdentifier() == "chrome.tool-blur" })
}

@MainActor private func issue637ToolPanel(_ group: NSView) throws -> NSView {
    try #require(group.subviews.first { $0.accessibilityIdentifier() == "chrome.tool-background" })
}

@MainActor private func issue637NextMainTurn() async {
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }
}

@Test @MainActor func issue637ToolBackdropFlatGreyCoverageAllGroupsThemesAndTiers() async throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), session: ViewerSession())
    let toolFrames = overlay.tools.map(\.frame)
    let groupFrames = overlay.groups.map(\.frame)
    let labels = overlay.tools.map { $0.accessibilityLabel() }
    var generation: UInt64 = 0
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        overlay.appearance = NSAppearance(named: appearance)
        overlay.viewDidChangeEffectiveAppearance()
        for grey in [CGFloat(69) / 255, CGFloat(226) / 255] {
            generation += 1
            let frame = issue637ToolFrame(try issue637ToolImage(grey: grey), generation: generation, background: grey)
            overlay.setBackdropFrame(frame)
            for percent in [30.0, 50, 100] {
                overlay.setToolBackgroundOpacity(percent)
                await issue637NextMainTurn()
                #expect(overlay.tools.map(\.frame) == toolFrames)
                #expect(overlay.groups.map(\.frame) == groupFrames)
                #expect(overlay.tools.map { $0.accessibilityLabel() } == labels)
                for group in overlay.groups {
                    #expect(group.subviews.allSatisfy { !($0 is NSVisualEffectView) })
                    let surface = try issue637ToolSurface(group)
                    let panel = try issue637ToolPanel(group)
                    #expect(surface.frame == group.bounds && panel.frame == group.bounds)
                    let panelColor = try issue637RawSRGB(issue637ToolRaster(panel), x: 10, y: 19)
                    let backdropGrey = grey
                    let target = 0.5 + 0.5 * percent / 100
                    #expect(abs(panelColor.alphaComponent - target) < 0.015)
                    // Rasterize the whole pod so this checks the real surface/panel composition.
                    let composite = try issue637RawSRGB(issue637ToolRaster(group), x: 20, y: 34)
                    let nominalPanel = panelColor
                    let components = [(composite.redComponent, nominalPanel.redComponent),
                        (composite.greenComponent, nominalPanel.greenComponent),
                        (composite.blueComponent, nominalPanel.blueComponent)]
                    let stable = components.filter { abs($0.1 - backdropGrey) > 0.12 }
                    // White over grey 226 has too little channel separation for a stable ratio.
                    if stable.isEmpty {
                        #expect(appearance == .aqua && grey > 0.8)
                        print("issue637ToolBackdrop unstable—coverage omitted: light/grey226, group \(overlay.groups.firstIndex(of: group) ?? -1), \(percent)%")
                    }
                    for (observed, panelRGB) in stable {
                        let coverage = (observed - backdropGrey) / (panelRGB - backdropGrey)
                        #expect(abs(coverage - target) < 0.05)
                    }
                    if percent == 100 {
                        #expect(surface.isHidden)
                        #expect(panelColor.alphaComponent > 0.99)
                        for (observed, panelRGB) in components {
                            #expect(abs(observed - panelRGB) < 2.0 / 255)
                        }
                    } else {
                        #expect(!surface.isHidden)
                        let blurColor = try issue637RawSRGB(issue637ToolRaster(surface), x: 10, y: 19)
                        #expect(abs(blurColor.redComponent - backdropGrey) < 2.0 / 255)
                        #expect(abs(blurColor.greenComponent - backdropGrey) < 2.0 / 255)
                        #expect(abs(blurColor.blueComponent - backdropGrey) < 2.0 / 255)
                        #expect(blurColor.alphaComponent > 0.99)
                    }
                    #expect(surface.hitTest(CGPoint(x: 10, y: 19)) == nil)
                    #expect(!surface.acceptsFirstResponder)
                }
            }
        }
    }
}

@Test @MainActor func issue637ToolBackdropPatternSmoothsAndNeverBlursControls() async throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), session: ViewerSession())
    let stripes = try issue637ToolImage(grey: 0.5, stripes: true)
    overlay.setToolBackgroundOpacity(30)
    overlay.setBackdropFrame(issue637ToolFrame(stripes, generation: 1))
    await issue637NextMainTurn()
    let group = overlay.groups[2]
    let surface = try issue637ToolSurface(group)
    let rep = try issue637ToolRaster(surface)
    let samples = try (10..<164).map { x in
        try #require(rep.colorAt(x: x, y: 19)?.usingColorSpace(.sRGB)).redComponent
    }
    let variance = samples.reduce(0.0) { $0 + pow($1 - 0.5, 2) } / Double(samples.count)
    #expect(variance < 0.12, "4 pt contrast stripes must visibly smooth behind the tools")
    #expect(surface.frame == group.bounds)
    #expect(surface.hitTest(CGPoint(x: 40, y: 19)) == nil)
    #expect(overlay.tools[7].superview === group)
    #expect(overlay.tools[7].alphaValue == 1)
    #expect(try #require(rep.colorAt(x: 0, y: 0)).alphaComponent < 0.01)
    overlay.setToolBackgroundOpacity(100)
    await issue637NextMainTurn()
    #expect(surface.isHidden)
}

@Test @MainActor func issue637ToolBackdropNewestFrameWinsAndHiddenGroupsClear() async throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), session: ViewerSession())
    overlay.setToolBackgroundOpacity(30)
    overlay.setBackdropFrame(issue637ToolFrame(try issue637ToolImage(grey: 69.0 / 255), generation: 1, background: 69.0 / 255))
    overlay.setBackdropFrame(issue637ToolFrame(try issue637ToolImage(grey: 226.0 / 255), generation: 2, background: 226.0 / 255))
    await issue637NextMainTurn()
    let surface = try issue637ToolSurface(overlay.groups[0])
    let newest = try issue637RawSRGB(issue637ToolRaster(surface), x: 10, y: 19)
    #expect(abs(newest.redComponent - 226.0 / 255) < 2.0 / 255)
    overlay.setToolsVisible(false)
    await issue637NextMainTurn()
    #expect(overlay.groups.allSatisfy { $0.isHidden })
    #expect(surface.isHidden)
    overlay.setToolsVisible(true)
    await issue637NextMainTurn()
    #expect(!overlay.groups[0].isHidden)
    #expect(!surface.isHidden)
    let restored = try issue637RawSRGB(issue637ToolRaster(surface), x: 10, y: 19)
    #expect(abs(restored.redComponent - 226.0 / 255) < 2.0 / 255)
}

@Test @MainActor func issue637ToolBackdropSurfaceKeepsCanvasVerticalAlignment() async throws {
    _ = NSApplication.shared
    let size = CGSize(width: 1280, height: 800)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: 1280, height: 800,
        bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(origin: .zero, size: size))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1280, height: 50))
    context.fill(CGRect(x: 0, y: 750, width: 1280, height: 50))
    let image = try #require(context.makeImage())
    let frame = issue637ToolFrame(image, generation: 1)
    let overlay = ViewerChromeOverlay(frame: CGRect(origin: .zero, size: size), session: ViewerSession())
    overlay.setBackdropFrame(frame)
    await issue637NextMainTurn()
    let group = overlay.groups[0]
    let surface = try issue637ToolSurface(group)
    let rect = CGRect(x: group.frame.minX, y: overlay.bounds.height - group.frame.maxY,
                      width: group.frame.width, height: group.frame.height)
    let direct = try #require(ChromeBackdropRenderer.render(frame, pillRect: rect,
        backingScale: 1, blurRadius: 20, saturation: 1.6))
    let expected = NSBitmapImageRep(cgImage: direct)
    let actual = try issue637ToolRaster(surface)
    let expectedTop = try #require(expected.colorAt(x: 20, y: 5)?.usingColorSpace(.sRGB))
    let expectedBottom = try #require(expected.colorAt(x: 20, y: 32)?.usingColorSpace(.sRGB))
    let actualTop = try #require(actual.colorAt(x: 20, y: 5)?.usingColorSpace(.sRGB))
    let actualBottom = try #require(actual.colorAt(x: 20, y: 32)?.usingColorSpace(.sRGB))
    #expect(abs(expectedTop.redComponent - expectedBottom.redComponent) > 0.08)
    #expect(abs(actualTop.redComponent - expectedTop.redComponent) < 3.0 / 255)
    #expect(abs(actualBottom.redComponent - expectedBottom.redComponent) < 3.0 / 255)
}
