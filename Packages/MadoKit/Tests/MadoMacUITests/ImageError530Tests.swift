import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private func imageError530Icons(_ root: NSView) -> [NSImageView] {
    let own = (root as? NSImageView).flatMap { $0.accessibilityIdentifier() == "state.icon" ? $0 : nil }
    return (own.map { [$0] } ?? []) + root.subviews.flatMap(imageError530Icons)
}

@MainActor private func imageError530Scene() -> StatesScene {
    let scene = StatesScene(width: 1280)
    scene.window.setContentSize(NSSize(width: 1280, height: 800))
    scene.content.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    scene.state.frame = scene.content.bounds
    return scene
}

/// Rasterize the attached image, not a production path/helper. NSBitmapImageRep's
/// colorAt(x:y:) addresses image rows from the top left, as in the SVG viewBox.
@MainActor private func imageError530Raster(_ image: NSImage) throws -> NSBitmapImageRep {
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 32, height: 32))
    image.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32), from: .zero,
        operation: .copy, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap
}

@MainActor private func imageError530Alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) throws -> CGFloat {
    try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
}

@MainActor private func imageError530Maximum(_ bitmap: NSBitmapImageRep, x: ClosedRange<Int>, y: ClosedRange<Int>) throws -> CGFloat {
    var maximum: CGFloat = 0
    for row in y { for column in x { maximum = max(maximum, try imageError530Alpha(bitmap, column, row)) } }
    return maximum
}

/// #530 / amendment3: image-error.html's SVG is32/viewBox24, fill=none,
/// stroke1.3: rounded rect(3,3,18,18,rx2), circle(9,9,r2), and the two
/// mountain diagonals joined by a radius2 arc. These fixed probes derive from
/// that geometry, independently of the production NSBezierPath.
@MainActor private func imageError530AssertOutline(_ icon: NSImageView, ink: UInt32) throws -> [CGFloat] {
    let image = try #require(icon.image)
    #expect(image.isTemplate)
    #expect(image.size == NSSize(width: 32, height: 32))
    #expect(icon.frame.size == NSSize(width: 32, height: 32))
    #expect(icon.accessibilityLabel() == "Unreadable image")
    let bitmap = try imageError530Raster(image)
    // Each small positive neighborhood is isolated from unrelated strokes.
    for (x, y) in [(4, 16), (16, 4), (28, 12), (16, 28),
                    (14, 12), (12, 9), (12, 23), (16, 19), (26, 18)] {
        #expect(try imageError530Maximum(bitmap, x: x...(x + 1), y: y...(y + 1)) > 0.25,
                "Missing pinned outline near SVG-scaled pixel \(x),\(y)")
    }
    // Arc apex=(22,15.09717); its1.7333px stroke reaches y14.23050.
    // A straight chord at y16 cannot ink row14, nor can the separate diagonals.
    #expect(try imageError530Alpha(bitmap, 21, 14) > 0.10)
    #expect(try imageError530Alpha(bitmap, 22, 14) > 0.10)
    #expect(try imageError530Maximum(bitmap, x: 11...12, y: 11...12) < 0.05, "Sun must be hollow")
    #expect(try imageError530Maximum(bitmap, x: 20...24, y: 22...25) < 0.05, "Mountain must be hollow")
    #expect(try imageError530Maximum(bitmap, x: 16...16, y: 10...10) < 0.05)
    #expect(try imageError530Maximum(bitmap, x: 0...2, y: 10...20) < 0.05)
    #expect(try imageError530Alpha(bitmap, 0, 0) < 0.05)
    var borderCoverage: CGFloat = 0
    for x in 0...8 { borderCoverage += try imageError530Alpha(bitmap, x, 16) }
    #expect(borderCoverage >= 1.45 && borderCoverage <= 2.10,
            "Pinned stroke1.3 ×32/24 should cover1.7333pixels, got \(borderCoverage)")
    let tint = try #require(icon.contentTintColor)
    var resolved: NSColor?
    icon.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = tint.usingColorSpace(.sRGB) }
    let rgb = try #require(resolved)
    #expect(abs(rgb.redComponent - CGFloat((ink >> 16) & 255) / 255) <= 1.0 / 255)
    #expect(abs(rgb.greenComponent - CGFloat((ink >> 8) & 255) / 255) <= 1.0 / 255)
    #expect(abs(rgb.blueComponent - CGFloat(ink & 255) / 255) <= 1.0 / 255)
    #expect(rgb.alphaComponent == 1)
    return try (0..<32).flatMap { y in try (0..<32).map { x in try imageError530Alpha(bitmap, x, y) } }
}

@Test(.timeLimit(.minutes(2))) @MainActor func imageError530PinnedOutlineAndTint() throws {
    let scene = imageError530Scene()
    defer { scene.window.close() }
    for (appearance, ink) in [(NSAppearance.Name.aqua, UInt32(0x6b7280)), (.darkAqua, UInt32(0x9aa4b2))] {
        scene.window.appearance = NSAppearance(named: appearance)
        scene.state.display(.failed(.corruptImage, "DSC_0342.jpg"), nextEnabled: true)
        scene.state.layoutSubtreeIfNeeded()
        let icons = imageError530Icons(scene.state)
        #expect(icons.count == 1)
        _ = try imageError530AssertOutline(try #require(icons.first), ink: ink)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func imageError530AppearanceRoundTripPreservesOutline() throws {
    let scene = imageError530Scene()
    defer { scene.window.close() }
    scene.state.display(.failed(.corruptImage, "photo.jpg"), nextEnabled: true)
    var first: [CGFloat]?
    for (appearance, ink) in [(NSAppearance.Name.aqua, UInt32(0x6b7280)), (.darkAqua, UInt32(0x9aa4b2)), (.aqua, UInt32(0x6b7280))] {
        scene.window.appearance = NSAppearance(named: appearance)
        scene.state.viewDidChangeEffectiveAppearance()
        scene.state.layoutSubtreeIfNeeded()
        let raster = try imageError530AssertOutline(try #require(imageError530Icons(scene.state).first), ink: ink)
        if let first { #expect(raster == first) } else { first = raster }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func imageError530FailureReentryIsIdempotent() throws {
    let scene = imageError530Scene()
    defer { scene.window.close() }
    for (appearance, ink) in [(NSAppearance.Name.aqua, UInt32(0x6b7280)), (.darkAqua, UInt32(0x9aa4b2))] {
        scene.window.appearance = NSAppearance(named: appearance)
        var first: [CGFloat]?
        for reentry in 0..<2 {
            if reentry == 1 {
                scene.state.display(.loading("new.png"))
                #expect(imageError530Icons(scene.state).isEmpty)
            }
            for _ in 0..<2 {
                scene.state.display(.failed(.corruptImage, "DSC_0342.jpg"), nextEnabled: true)
                scene.state.layoutSubtreeIfNeeded()
                let icons = imageError530Icons(scene.state)
                #expect(icons.count == 1)
                let raster = try imageError530AssertOutline(try #require(icons.first), ink: ink)
                if let first { #expect(raster == first) } else { first = raster }
            }
        }
    }
}
