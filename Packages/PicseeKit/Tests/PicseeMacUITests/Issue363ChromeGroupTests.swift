import AppKit
import Testing
import PicseeApplication
@testable import PicseeMacUI

private final class Issue363ContourReference: NSView {
    let spread: Double
    let radius: Double
    let color: PinnedDesign.Color
    init(frame: NSRect, spread: Double, radius: Double, color: PinnedDesign.Color) {
        self.spread = spread; self.radius = radius; self.color = color
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            DesignColor.popoverBackground.nsColor.setFill()
            let inset = spread / 2
            let contour = NSBezierPath(roundedRect: bounds.insetBy(dx: inset, dy: inset),
                                       xRadius: radius - inset, yRadius: radius - inset)
            contour.fill()
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setStroke()
            contour.lineWidth = spread
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
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 480, height: 240),
                                      session: ViewerSession())
    overlay.refresh(filename: "a.png")
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        let design = try PinnedDesign.page("viewer-controls", appearance: name == .darkAqua ? "dark" : "light")
        let layers = try design.boxShadowLayers(".zoom-pod", viewport: 1280)
        try #require(layers.count == 2)
        let contour = layers[0]
        let radius = try design.length(".zoom-pod", "border-radius", viewport: 1280)
        overlay.appearance = appearance
        overlay.viewDidChangeEffectiveAppearance()
        for group in overlay.groups { group.layer?.shadowOpacity = 0 }

        let strip = NSRect(x: 0, y: 9, width: 6, height: 20)
        let actual = try issue363Raster(overlay.groups[0], in: strip)
        let reference = Issue363ContourReference(frame: overlay.groups[0].bounds,
            spread: contour.spread, radius: radius, color: contour.color)
        reference.appearance = appearance
        reference.wantsLayer = true
        reference.layer?.cornerRadius = radius
        appearance.performAsCurrentDrawingAppearance {
            reference.layer?.backgroundColor = DesignColor.popoverBackground.nsColor.cgColor
        }
        let expected = try issue363Raster(reference, in: strip)
        #expect(actual.tiffRepresentation == expected.tiffRepresentation,
                "single pinned \(contour.spread) pt contour in \(name)")

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
