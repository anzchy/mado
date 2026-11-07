import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test @MainActor func chromeGroupLayersResolveLightDarkAndBack() throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 680), session: ViewerSession())
    overlay.setToolBackgroundOpacity(100)
    let cases: [(NSAppearance.Name, [CGFloat])] = [(.aqua, [1, 1, 1, 1]), (.darkAqua, [20/255, 24/255, 33/255, 1]), (.aqua, [1, 1, 1, 1])]
    for (name, expected) in cases {
        overlay.appearance = try #require(NSAppearance(named: name))
        overlay.viewDidChangeEffectiveAppearance()
        for group in overlay.groups {
            let cg = try #require(group.layer?.backgroundColor)
            let color = try #require(NSColor(cgColor: cg)?.usingColorSpace(.sRGB))
            #expect(abs(color.redComponent - expected[0]) < 0.00001)
            #expect(abs(color.greenComponent - expected[1]) < 0.00001)
            #expect(abs(color.blueComponent - expected[2]) < 0.00001)
            #expect(color.alphaComponent == 1)
        }
    }
}

@Test @MainActor func chromeFloatingPanelsSeparateFromCanvasAcrossAppearances() throws {
    _ = NSApplication.shared
    let overlay = ViewerChromeOverlay(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
        session: ViewerSession())
    overlay.setToolBackgroundOpacity(100)
    overlay.refresh(filename: "a.png")
    let initialWidth = overlay.groups[1].frame.width

    for appearance in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
        let design = try PinnedDesign.page("viewer-controls", appearance: appearance == .darkAqua ? "dark" : "light")
        let layers = try design.boxShadowLayers(".zoom-pod", viewport: 1280)
        try #require(layers.count == 2)
        let shadow = layers[1]
        let expectedColor = NSColor(srgbRed: shadow.color.red, green: shadow.color.green,
                                    blue: shadow.color.blue, alpha: 1)
        overlay.appearance = NSAppearance(named: appearance)
        overlay.viewDidChangeEffectiveAppearance()
        for group in overlay.groups {
            let layer = try #require(group.layer)
            let shadowCG = try #require(layer.shadowColor)
            let shadowColor = try #require(NSColor(cgColor: shadowCG)?.usingColorSpace(.sRGB))
            #expect(abs(shadowColor.redComponent - expectedColor.redComponent) < 0.00001)
            #expect(abs(shadowColor.greenComponent - expectedColor.greenComponent) < 0.00001)
            #expect(abs(shadowColor.blueComponent - expectedColor.blueComponent) < 0.00001)
            #expect(shadowColor.alphaComponent == 1)
            #expect(layer.shadowOpacity == Float(shadow.color.alpha))
            #expect(abs(layer.shadowRadius - shadow.blur / 2) < 0.00001)
            #expect(abs(layer.shadowOffset.width - shadow.x) < 0.00001)
            #expect(abs(layer.shadowOffset.height + shadow.y) < 0.00001)
            #expect(layer.masksToBounds == false)
            let path = try #require(layer.shadowPath)
            #expect(path.boundingBoxOfPath == group.bounds)
        }
    }

    overlay.refresh(filename: String(repeating: "long-filename-", count: 30) + ".png")
    #expect(overlay.groups[1].frame.width > initialWidth)
    for group in overlay.groups {
        let layer = try #require(group.layer)
        let path = try #require(layer.shadowPath)
        #expect(path.boundingBoxOfPath == group.bounds)
    }
    overlay.setFrameSize(NSSize(width: 800, height: 680))
    for group in overlay.groups {
        let layer = try #require(group.layer)
        let path = try #require(layer.shadowPath)
        #expect(path.boundingBoxOfPath == group.bounds)
    }
}
