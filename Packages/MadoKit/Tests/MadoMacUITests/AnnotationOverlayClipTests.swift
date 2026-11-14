import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #692 fix r1 (opus M2 = gpt M1): the overlay clips its marks to the displayed image, so a text mark or a step near
// the right and bottom edges shows on screen exactly what the Annotated Copy keeps. A 400×300 image at zoom 1, origin
// 50,40, in a 500×400 window: the canvas around the image is grey, the image white.

private let imageRect = CGRect(x: 50, y: 40, width: 400, height: 300)

@MainActor private final class Backdrop: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1).setFill()
        bounds.fill()
        NSColor.white.setFill()
        imageRect.fill()
    }
}

@MainActor private func screen(_ marks: [AnnotationMark]) throws -> (Int, Int) -> [Int] {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 500, height: 400), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let backdrop = Backdrop(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
    window.contentView = backdrop
    backdrop.appearance = NSAppearance(named: .aqua)
    let overlay = AnnotationOverlayView(frame: backdrop.bounds)
    backdrop.addSubview(overlay)
    overlay.transform = CanvasTransform(backingScale: 1, zoom: 1, origin: imageRect.origin)
    overlay.imageSize = imageRect.size
    overlay.isActive = true
    overlay.tool = .select
    overlay.marks = marks
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 400, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = backdrop.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
    return { x, y in
        var p = [Int](repeating: 0, count: 4)
        rep.getPixel(&p, atX: x, y: y)
        return p
    }
}

@MainActor private func copy(_ marks: [AnnotationMark]) throws -> (Int, Int) -> [Int] {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let white = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    white.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    white.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    let flat = try AnnotationFlattener.flatten(try #require(white.makeImage()), orientation: 1, marks: marks)
    var data = [UInt8](repeating: 0, count: 400 * 300 * 4)
    let context = try #require(CGContext(data: &data, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 1600,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(flat, in: CGRect(x: 0, y: 0, width: 400, height: 300))
    let bytes = data
    return { x, y in
        let i = (y * 400 + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]), Int(bytes[i + 3])]
    }
}

private func diff(_ a: [Int], _ b: [Int]) -> Int { zip(a.prefix(3), b.prefix(3)).map { abs($0 - $1) }.max() ?? 0 }

/// A text mark running past the right edge and a step disc over the bottom-right corner.
private func edgeMarks() -> [AnnotationMark] {
    let style = AnnotationStyle(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255, lineWidth: 3)
    return [.text("Mado edge text", origin: CGPoint(x: 320, y: 120),
                  size: AnnotationRenderer.textSize("Mado edge text", fontSize: 18), style: style),
            .step(centre: CGPoint(x: 394, y: 292), style: style),
            .text("Bottom", origin: CGPoint(x: 100, y: 285),
                  size: AnnotationRenderer.textSize("Bottom", fontSize: 18), style: style)]
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692OverlayClipsToTheImageOutsideIsUnchanged() throws {
    let marks = edgeMarks()
    #expect(marks[0].rect.maxX > 400 && marks[1].rect.maxX > 400 && marks[1].rect.maxY > 300 && marks[2].rect.maxY > 300,
            "the marks really cross the edges")
    let bare = try screen([])
    let marked = try screen(marks)
    var changed: [(Int, Int)] = []
    for y in 0..<400 {
        for x in 0..<500 where !imageRect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
            if diff(bare(x, y), marked(x, y)) > 0 { changed.append((x, y)) }
        }
    }
    #expect(changed.isEmpty, "\(changed.count) canvas pixels outside the image changed, first \(changed.prefix(3))")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue692OverlayClipsToTheImageInsideMatchesTheCopy() throws {
    let marks = edgeMarks()
    let marked = try screen(marks)
    let flat = try copy(marks)
    var close = 0, total = 0
    // The edge bands, where the marks are cut: the right 100 columns and the bottom 40 rows.
    for y in 0..<300 {
        for x in 0..<400 where x >= 300 || y >= 260 {
            total += 1
            if diff(marked(x + 50, y + 40), flat(x, y)) <= 16 { close += 1 }
        }
    }
    #expect(Double(close) / Double(total) >= 0.99, "\(close) of \(total) within 16")
    // The disc's cut corner and the text's last column inside the image.
    for (x, y) in [(398, 296), (399, 292), (394, 299)] {
        #expect(diff(marked(x + 50, y + 40), flat(x, y)) <= 16, "(\(x), \(y)): \(marked(x + 50, y + 40)) vs \(flat(x, y))")
    }
}
