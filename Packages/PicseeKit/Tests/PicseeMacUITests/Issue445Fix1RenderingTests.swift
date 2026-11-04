import AppKit
import Testing
@testable import PicseeMacUI

@MainActor private func fix445Field(_ scene: StatesScene) throws -> NSTextField {
    try #require(scene.chrome.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityIdentifier() == "chrome.filename" })
}

@MainActor private func fix445Color(_ color: NSColor, appearance: NSAppearance) -> NSColor? {
    var resolved: NSColor?
    appearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
    return resolved
}

@MainActor private func fix445ExpectColor(_ color: NSColor, _ expected: PinnedDesign.Color,
                                        appearance: NSAppearance) throws {
    let actual = try #require(fix445Color(color, appearance: appearance))
    #expect(abs(actual.redComponent - expected.red) < 0.01)
    #expect(abs(actual.greenComponent - expected.green) < 0.01)
    #expect(abs(actual.blueComponent - expected.blue) < 0.01)
    #expect(abs(actual.alphaComponent - expected.alpha) < 0.01)
}

@Test(arguments: ["light", "dark"]) @MainActor
func position445Fix1EffectivePrimaryForegroundAndHalo(_ theme: String) throws {
    let scene = StatesScene(width: 1280)
    defer { scene.window.close() }
    let appearance = try #require(NSAppearance(named: theme == "light" ? .aqua : .darkAqua))
    scene.chrome.appearance = appearance
    scene.chrome.viewDidChangeEffectiveAppearance()
    scene.chrome.refresh(filename: "DSC_0342.jpg", position: "2 / 12")
    let field = try fix445Field(scene)
    let pin = try PinnedDesign.page("viewer-controls", appearance: theme)
    // This higher-specificity rule overrides the base label span's muted color.
    let selector = ".viewer-floating-controls > [data-viewer-controls] .viewer-file-label > span"
    let primary = try pin.color(selector, "color", viewport: 1280)
    let halo = try #require(pin.boxShadowLayers(selector, "text-shadow", viewport: 1280).first)
    let text = field.attributedStringValue
    for index in [0, (text.string as NSString).range(of: "2 / 12").location] {
        let attributes = text.attributes(at: index, effectiveRange: nil)
        let foreground = (attributes[.foregroundColor] as? NSColor) ?? field.textColor ?? .labelColor
        try fix445ExpectColor(foreground, primary, appearance: appearance)
        let shadow = attributes[.shadow] as? NSShadow
        #expect(shadow != nil, "Filename and position need the pinned foreground halo")
        if let shadow {
            #expect(abs(shadow.shadowOffset.width - halo.x) < 0.01)
            #expect(abs(shadow.shadowOffset.height - halo.y) < 0.01)
            #expect(abs(shadow.shadowBlurRadius - halo.blur) < 0.01)
            try fix445ExpectColor(try #require(shadow.shadowColor as? NSColor), halo.color, appearance: appearance)
        }
    }
}

private struct Fix445Ink: CustomStringConvertible {
    let width: Int
    let height: Int
    let pixels: [Bool]
    var description: String { "Fix445Ink(\(width)×\(height), ink: \(count))" }
    subscript(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && x < width && y >= 0 && y < height && pixels[y * width + x]
    }
    var count: Int { pixels.filter { $0 }.count }
    func cropped() -> Self {
        let points = pixels.indices.filter { pixels[$0] }
        guard let minX = points.map({ $0 % width }).min(), let maxX = points.map({ $0 % width }).max(),
              !points.isEmpty else { return self }
        // Retain the full line height: three W tips can resemble an ellipsis when
        // cropped to its four-pixel height, but their upper strokes must reject it.
        let left = max(0, minX - 2), top = 0
        let right = min(width - 1, maxX + 2), bottom = height - 1
        return Self(width: right - left + 1, height: bottom - top + 1,
                    pixels: (top...bottom).flatMap { y in (left...right).map { x in self[x, y] } })
    }
    // Match a complete rendered glyph sequence, allowing one raster pixel of antialiasing drift.
    // The ink-count bound rejects a partial match hidden inside a dense run of filename glyphs.
    func contains(_ reference: Self, horizontal: ClosedRange<Double>) -> Bool {
        guard reference.count > 0, reference.width <= width, reference.height <= height else { return false }
        let start = max(0, Int(Double(width) * horizontal.lowerBound))
        let end = min(width - reference.width, Int(Double(width) * horizontal.upperBound))
        guard start <= end else { return false }
        let foreground = reference.pixels.indices.filter { reference.pixels[$0] }
        for y in 0...(height - reference.height) {
            for x in start...end {
                var hits = 0
                for point in foreground {
                    let px = x + point % reference.width, py = y + point / reference.width
                    if (-1...1).contains(where: { dy in (-1...1).contains { dx in self[px + dx, py + dy] } }) { hits += 1 }
                }
                guard Double(hits) / Double(foreground.count) >= 0.98 else { continue }
                let ink = (0..<reference.height).reduce(0) { total, dy in
                    total + (0..<reference.width).filter { dx in self[x + dx, y + dy] }.count
                }
                if Double(ink) <= Double(reference.count) * 1.35 && Double(ink) >= Double(reference.count) * 0.75 { return true }
            }
        }
        return false
    }
}

@MainActor private func fix445Render(_ field: NSTextField) throws -> Fix445Ink {
    let scale = 2
    let width = Int(ceil(field.bounds.width)) * scale, height = Int(ceil(field.bounds.height)) * scale
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
    context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    context.cgContext.clip(to: field.bounds)
    field.effectiveAppearance.performAsCurrentDrawingAppearance {
        field.draw(field.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    let pixels = (0..<height).flatMap { y in (0..<width).map { x in
        (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3
    } }
    return Fix445Ink(width: width, height: height, pixels: pixels)
}

@MainActor private func fix445Reference(_ text: String, attributes: [NSAttributedString.Key: Any],
                                      field: NSTextField) throws -> Fix445Ink {
    let reference = NSTextField(labelWithString: "")
    reference.appearance = field.effectiveAppearance
    reference.font = field.font
    reference.textColor = field.textColor
    reference.attributedStringValue = NSAttributedString(string: text, attributes: attributes)
    reference.frame = CGRect(x: 0, y: 0, width: 110, height: field.bounds.height)
    return try fix445Render(reference).cropped()
}

@Test(arguments: ["light", "dark"]) @MainActor
func position445Fix1LongNameActuallyDrawsCompleteFractionAndEllipsis(_ theme: String) throws {
    let scene = StatesScene(width: 1280)
    defer { scene.window.close() }
    scene.chrome.appearance = NSAppearance(named: theme == "light" ? .aqua : .darkAqua)
    let filename = "START_" + String(repeating: "W", count: 80) + "_TAIL.png"
    scene.chrome.refresh(filename: filename, position: "2 / 12")
    let field = try fix445Field(scene)
    let text = field.attributedStringValue
    let filenameAttributes = text.attributes(at: 0, effectiveRange: nil)
    let fractionAttributes = text.attributes(at: (text.string as NSString).range(of: "2 / 12").location, effectiveRange: nil)
    let prefix = try fix445Reference("START", attributes: filenameAttributes, field: field)
    let fraction = try fix445Reference("2 / 12", attributes: fractionAttributes, field: field)
    let ellipsis = try fix445Reference("…", attributes: filenameAttributes, field: field)
    #expect(prefix.count > 0 && fraction.count > 0 && ellipsis.count > 0)
    #expect(fraction.contains(fraction, horizontal: 0...0))
    let rendered = try fix445Render(field)
    #expect(rendered.contains(prefix, horizontal: 0...0.25), "Rendered filename beginning survives")
    #expect(rendered.contains(fraction, horizontal: 0.5...1), "Complete numeric suffix is actually drawn")
    #expect(rendered.contains(ellipsis, horizontal: 0.2...0.75), "Actual middle-truncation ellipsis is drawn")
    #expect(scene.chrome.groups[1].frame.width == 260)
    #expect(field.frame.maxX <= scene.chrome.groups[1].bounds.width - 35)
    #expect(field.stringValue == filename + "  2 / 12")
    #expect(field.accessibilityValue() as? String == filename + "  2 / 12")
    // Negative control: the raw value stays correct when right clipping hides the suffix.
    let clipped = NSTextField(labelWithString: "")
    clipped.appearance = field.effectiveAppearance
    clipped.font = field.font
    clipped.textColor = field.textColor
    let clippingText = NSMutableAttributedString(attributedString: text)
    let clippingParagraph = NSMutableParagraphStyle()
    clippingParagraph.lineBreakMode = .byClipping
    clippingText.addAttribute(.paragraphStyle, value: clippingParagraph,
                             range: NSRange(location: 0, length: clippingText.length))
    clipped.attributedStringValue = clippingText
    clipped.frame = field.bounds
    clipped.lineBreakMode = .byClipping
    let clippedPixels = try fix445Render(clipped)
    #expect(!clippedPixels.contains(fraction, horizontal: 0.5...1))
    #expect(!clippedPixels.contains(ellipsis, horizontal: 0.2...0.75))
    clipped.lineBreakMode = .byTruncatingMiddle
    clipped.attributedStringValue = NSAttributedString(string: filename, attributes: filenameAttributes)
    #expect(!(try fix445Render(clipped)).contains(fraction, horizontal: 0.5...1))
}
