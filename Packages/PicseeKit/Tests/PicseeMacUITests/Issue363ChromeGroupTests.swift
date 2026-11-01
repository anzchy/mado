import AppKit
import Testing
import PicseeApplication
@testable import PicseeMacUI

private final class Issue363ContourReference: NSView {
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            DesignColor.popoverBackground.nsColor.setFill()
            let contour = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 5.75, yRadius: 5.75)
            contour.fill()
            DesignColor.textPrimary.nsColor.withAlphaComponent(0.12).setStroke()
            contour.lineWidth = 0.5
            contour.stroke()
        }
    }
}

@MainActor private func issue363Raster(_ view: NSView, in rect: NSRect, cache: Bool = true) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width),
        pixelsHigh: Int(rect.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = rect.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    if cache {
        view.cacheDisplay(in: rect, to: rep)
    } else {
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.draw(rect)
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

@Test @MainActor func issue363ChromeGroupsHaveOnePinnedContourAndNoOverlayStroke() throws {
    _ = NSApplication.shared
    let design = try PinnedDesign.page("viewer-controls", appearance: "light")
    let layers = try design.boxShadowLayers(".zoom-pod", viewport: 1280)
    #expect(layers.count == 2)
    #expect(layers[0].spread == 0.5 && layers[0].color.alpha == 0.12)

    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 480, height: 240),
                                      session: ViewerSession())
    overlay.refresh(filename: "a.png")
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        overlay.appearance = appearance
        overlay.viewDidChangeEffectiveAppearance()
        for group in overlay.groups { group.layer?.shadowOpacity = 0 }

        let strip = NSRect(x: 0, y: 9, width: 6, height: 20)
        let actual = try issue363Raster(overlay.groups[0], in: strip)
        let reference = Issue363ContourReference(frame: overlay.groups[0].bounds)
        reference.appearance = appearance
        reference.wantsLayer = true
        reference.layer?.cornerRadius = DesignMetrics.radii["control"]!
        appearance.performAsCurrentDrawingAppearance {
            reference.layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
        }
        let expected = try issue363Raster(reference, in: strip)
        #expect(actual.tiffRepresentation == expected.tiffRepresentation,
                "single 0.5 pt text@12% contour in \(name)")

        let overlayPixels = try issue363Raster(overlay, in: overlay.bounds, cache: false)
        var drewOverlayStroke = false
        for y in 0..<overlayPixels.pixelsHigh {
            for x in 0..<overlayPixels.pixelsWide {
                if try #require(overlayPixels.colorAt(x: x, y: y)).alphaComponent > 0 {
                    drewOverlayStroke = true
                }
            }
        }
        #expect(!drewOverlayStroke, "ViewerChromeOverlay adds no second contour")
    }
}
