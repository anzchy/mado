import AppKit
import Foundation
import Testing
import PicseeApplication
@testable import PicseeMacUI

/// #354: the SVG is 32×32/viewBox24, stroke1.3; issue dimensions describe ink.
/// Independent oracle uses CoreGraphics tangent arcs rather than native artwork helpers.
@Test @MainActor func i354RecoveryArtworkMatchesPinnedSVGInk() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    let text = LostAccessStateText(title: "Title", detail: "Detail", waiting: "Waiting…",
                                  reselect: "Reselect…", chooseOther: "Other…")
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL
    let html = try String(contentsOf: root.appendingPathComponent("design/prototypes/picsee-browser/states/permission-denied.html"), encoding: .utf8)
    // Tie the independent geometric oracle to the approved design, not symbol names.
    #expect(html.contains("stroke-dasharray=\"2.5 2\""))
    #expect(html.contains("<rect x=\"9.5\" y=\"12\" width=\"5\" height=\"4\" rx=\"1\" />"))
    #expect(html.contains("<rect x=\"3\" y=\"7\" width=\"18\" height=\"10\" rx=\"2\" />"))
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        window.appearance = NSAppearance(named: appearance)
        var firstMissing: [Bool]?
        for cause: AccessLossCause in [.notFound, .accessExpired, .diskNotConnected, .notFound] {
            view.display(cause: cause, text: text)
            view.layoutSubtreeIfNeeded()
            #expect(view.iconView.frame.size == NSSize(width: 32, height: 32))
            #expect(view.titleLabel.font == NSFont.systemFont(ofSize: 16, weight: .medium))
            #expect(abs(view.iconView.frame.minY - view.titleLabel.frame.maxY - 18) < 0.5)
            let actual = try i354ImageMask(try #require(view.iconView.image))
            let expected = try i354SVGMask(cause)
            let aBounds = try #require(i354InkBounds(actual))
            let eBounds = try #require(i354InkBounds(expected))
            #expect(abs(aBounds.minX - eBounds.minX) <= 1 && abs(aBounds.maxX - eBounds.maxX) <= 1)
            #expect(abs(aBounds.minY - eBounds.minY) <= 1 && abs(aBounds.maxY - eBounds.maxY) <= 1)
            let intersection = zip(actual, expected).filter { $0 && $1 }.count
            let union = zip(actual, expected).filter { $0 || $1 }.count
            #expect(Double(intersection) / Double(max(1, union)) >= 0.90, "\(cause): icon ink differs from pinned SVG")
            if cause == .notFound {
                // Bottom edge has visible dash gaps: a continuous folder cannot pass.
                let row = (0..<128).map { expected[112 * 128 + $0] }
                let runStarts = row.indices.filter { row[$0] && ($0 == 0 || !row[$0 - 1]) }
                #expect(runStarts.count >= 3)
                // Sample interiors, away from antialiased dash boundaries; the whole
                // mask comparison above separately constrains boundary geometry.
                for x in 24..<104 where (x - 2...x + 2).allSatisfy({ row[$0] == row[x] }) {
                    #expect(actual[112 * 128 + x] == row[x])
                }
                if let firstMissing { #expect(actual == firstMissing) } else { firstMissing = actual }
            } else {
                // Fixed design coordinates chosen before native implementation: lock arch/body
                // and drive indicators, plus empty interiors to reject questionmark glyphs.
                let landmarks: [(CGFloat, CGFloat, Bool)] = cause == .accessExpired
                    ? [(12, 9.3, true), (9.5, 14, true), (12, 14, false), (12, 11, false)]
                    : [(7, 13, true), (14, 13, true), (9, 13, false), (12, 10, false)]
                for (x, y, ink) in landmarks {
                    let index = Int((y * 128 / 24).rounded(.down)) * 128 + Int((x * 128 / 24).rounded(.down))
                    #expect(expected[index] == ink, "oracle landmark \(x),\(y)")
                    #expect(actual[index] == ink, "\(cause) landmark \(x),\(y)")
                }
            }
            await Task.yield()
        }
    }
}

@MainActor private func i354ImageMask(_ image: NSImage) throws -> [Bool] {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return i354AlphaMask(rep)
}

private func i354AlphaMask(_ rep: NSBitmapImageRep) -> [Bool] {
    (0..<128).flatMap { y in (0..<128).map { x in (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.25 } }
}

private func i354InkBounds(_ mask: [Bool]) -> NSRect? {
    let indices = mask.indices.filter { mask[$0] }
    guard !indices.isEmpty else { return nil }
    let xs = indices.map { $0 % 128 }, ys = indices.map { $0 / 128 }
    return NSRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + 1, height: ys.max()! - ys.min()! + 1)
}

private func i354SVGMask(_ cause: AccessLossCause) throws -> [Bool] {
    let context = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
        bytesPerRow: 128 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.translateBy(x: 0, y: 128)
    context.scaleBy(x: 128 / 24, y: -128 / 24)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(1.3)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    if cause == .diskNotConnected {
        context.addPath(CGPath(roundedRect: CGRect(x: 3, y: 7, width: 18, height: 10), cornerWidth: 2, cornerHeight: 2, transform: nil))
        context.strokePath()
        context.move(to: CGPoint(x: 7, y: 13)); context.addLine(to: CGPoint(x: 7.01, y: 13))
        context.move(to: CGPoint(x: 11, y: 13)); context.addLine(to: CGPoint(x: 17, y: 13))
        context.strokePath()
    } else {
        let folder = CGMutablePath()
        folder.move(to: CGPoint(x: 3, y: 7)); folder.addLine(to: CGPoint(x: 3, y: 5))
        folder.addArc(tangent1End: CGPoint(x: 3, y: 3), tangent2End: CGPoint(x: 5, y: 3), radius: 2)
        folder.addLine(to: CGPoint(x: 10, y: 3)); folder.addLine(to: CGPoint(x: 12, y: 6))
        folder.addLine(to: CGPoint(x: 19, y: 6))
        folder.addArc(tangent1End: CGPoint(x: 21, y: 6), tangent2End: CGPoint(x: 21, y: 8), radius: 2)
        folder.addLine(to: CGPoint(x: 21, y: 19))
        folder.addArc(tangent1End: CGPoint(x: 21, y: 21), tangent2End: CGPoint(x: 19, y: 21), radius: 2)
        folder.addLine(to: CGPoint(x: 5, y: 21))
        folder.addArc(tangent1End: CGPoint(x: 3, y: 21), tangent2End: CGPoint(x: 3, y: 19), radius: 2)
        folder.closeSubpath()
        if cause == .notFound { context.setLineDash(phase: 0, lengths: [2.5, 2]) }
        context.addPath(folder); context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
        if cause == .accessExpired {
            context.addPath(CGPath(roundedRect: CGRect(x: 9.5, y: 12, width: 5, height: 4), cornerWidth: 1, cornerHeight: 1, transform: nil))
            context.strokePath()
            context.move(to: CGPoint(x: 10.5, y: 12)); context.addLine(to: CGPoint(x: 10.5, y: 10.8))
            context.addArc(center: CGPoint(x: 12, y: 10.8), radius: 1.5, startAngle: .pi, endAngle: 0, clockwise: false)
            context.addLine(to: CGPoint(x: 13.5, y: 12)); context.strokePath()
        }
    }
    return i354AlphaMask(NSBitmapImageRep(cgImage: try #require(context.makeImage())))
}

/// #354 fix1 M1: unlike the alpha oracle above, this renders the actual image view's tint.
/// The optional mutation is test-owned and is explicitly reported as mutant RED evidence.
@Test @MainActor func i354RecoveryIconViewRendersPinnedTemplateTint() async throws {
    _ = NSApplication.shared
    let mutant = ProcessInfo.processInfo.environment["PICSEE_I354_TINT_NEGATIVE_CONTROL"] == "1"
    print("i354 tint evidence mode=\(mutant ? "mutant-RED non-template black-tint" : "normal baseline/restored production")")
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    window.contentView = view
    let text = LostAccessStateText(title: "Title", detail: "Detail", waiting: "Waiting…",
                                  reselect: "Reselect…", chooseOther: "Other…")
    var firstLight: [[Double]] = []
    for (appearanceIndex, theme) in [DesignTheme.light, .dark, .light].enumerated() {
        window.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        let page = try PinnedDesign.page("permission-denied", appearance: theme == .light ? "light" : "dark")
        let css = try page.color(".recovery-state>svg", "color", viewport: 1280)
        let expected = [css.red, css.green, css.blue]
        let semantic = Array(DesignColor.textSecondary.components(theme).prefix(3))
        // A real CSS/semantic mismatch is a stop condition, not a reason to change tint here.
        try #require(zip(expected, semantic).allSatisfy { abs($0 - $1) < 0.000_001 })
        for (causeIndex, cause) in [AccessLossCause.notFound, .accessExpired, .diskNotConnected].enumerated() {
            view.display(cause: cause, text: text)
            view.layoutSubtreeIfNeeded()
            let image = try #require(view.iconView.image)
            if mutant {
                // display() supplied a new test-owned image; no production source is mutated.
                image.isTemplate = false
                view.iconView.contentTintColor = .black
            }
            #expect(image.isTemplate, "\(theme) \(cause): recovery image must be a template")
            let pixels = try i354TintedViewPixels(view.iconView)
            // Native thin strokes are antialiased even inside these geometric cores.
            // Use every independent position; do not select by actual alpha or RGB.
            let samples = i354StrokeInteriors(try i354SVGMask(cause))
            try #require(samples.count >= 8, "Independent SVG must supply at least eight distinct sample positions")
            var opacity: Double = 0
            var maximumPremultipliedError: Double = 0
            var weightedRGB = [Double](repeating: 0, count: 3)
            for index in samples {
                let color = try #require(pixels.colorAt(x: index % 128, y: index / 128))
                // colorAt loses the source profile label; read its encoded components directly.
                // The actual target image's sRGB profile is required by the rendering helper.
                let channels = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
                let alpha = Double(color.alphaComponent)
                opacity += alpha
                for channel in 0..<3 {
                    maximumPremultipliedError = max(maximumPremultipliedError, abs(channels[channel] * alpha - expected[channel] * alpha))
                    weightedRGB[channel] += channels[channel] * alpha
                }
            }
            try #require(opacity >= 8, "Each glyph/theme must supply at least eight opacity-equivalent pixels")
            let mean = weightedRGB.map { $0 / opacity }
            let maximumTintError = zip(mean, expected).map { abs($0 - $1) }.max() ?? .infinity
            #expect(maximumPremultipliedError <= 3.0 / 255, "\(theme) \(cause): per-pixel premultiplied RGB error \(maximumPremultipliedError)")
            #expect(maximumTintError <= 3.0 / 255, "\(theme) \(cause): alpha-weighted rendered tint \(mean), pinned \(expected), max error \(maximumTintError)")
            if appearanceIndex == 0 { firstLight.append(mean) }
            if appearanceIndex == 2 {
                #expect(zip(mean, firstLight[causeIndex]).allSatisfy { abs($0 - $1) <= 3.0 / 255 }, "Light tint must return after dark")
            }
            await Task.yield()
        }
    }
}

@MainActor private func i354TintedViewPixels(_ view: NSImageView) throws -> NSBitmapImageRep {
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let target = try #require(CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8,
        bytesPerRow: 128 * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let pixels = NSBitmapImageRep(cgImage: try #require(target.makeImage()))
    pixels.size = view.bounds.size
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        view.cacheDisplay(in: view.bounds, to: pixels)
    }
    let rendered = try #require(pixels.cgImage)
    #expect(rendered.colorSpace?.name == CGColorSpace.sRGB)
    #expect(rendered.width == 128 && rendered.height == 128)
    return pixels
}

/// Erode the independent SVG alpha mask by two pixels; never select by actual RGB.
private func i354StrokeInteriors(_ mask: [Bool]) -> [Int] {
    (2..<126).flatMap { y in
        (2..<126).compactMap { x in
            let interior = (-2...2).allSatisfy { dy in
                (-2...2).allSatisfy { dx in mask[(y + dy) * 128 + x + dx] }
            }
            return interior ? y * 128 + x : nil
        }
    }
}
