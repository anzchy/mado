import AppKit
import Testing
@testable import MadoMacUI

@MainActor private func issue437Control(_ id: String, in root: NSView) -> NSButton? {
    if root.accessibilityIdentifier() == id { return root as? NSButton }
    return root.subviews.lazy.compactMap { issue437Control(id, in: $0) }.first
}

@MainActor private func issue437Pixels(_ button: NSButton) throws -> NSBitmapImageRep {
    let context = try #require(CGContext(data: nil, width: Int(button.bounds.width), height: Int(button.bounds.height),
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    button.effectiveAppearance.performAsCurrentDrawingAppearance { button.draw(button.bounds) }
    NSGraphicsContext.restoreGraphicsState()
    return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
}

@MainActor private func issue437ExpectColour(_ pixels: NSBitmapImageRep, in rect: NSRect,
    expected: PinnedDesign.Color, label: String, minimumAlpha: Double = 0.2) {
    var matching = 0
    for y in max(0, Int(rect.minY))..<min(pixels.pixelsHigh, Int(ceil(rect.maxY))) {
        for x in max(0, Int(rect.minX))..<min(pixels.pixelsWide, Int(ceil(rect.maxX))) {
            guard let p = pixels.colorAt(x: x, y: y), p.alphaComponent > minimumAlpha else { continue }
            if abs(p.redComponent - expected.red) < 0.025,
               abs(p.greenComponent - expected.green) < 0.025,
               abs(p.blueComponent - expected.blue) < 0.025 { matching += 1 }
        }
    }
    #expect(matching > 3, "\(label) paints the resolved muted token, rather than disabled text")
}

@MainActor private func issue437ExpectPlus(_ pixels: NSBitmapImageRep, box: NSRect) throws {
    // Both pinned pages use viewBox 0 0 24 24, M12 5v14M5 12h14, stroke-width 1.75.
    // Render that independent SVG oracle into the same sRGB raster. Comparing alpha proves
    // both arms really paint at full opacity; an assigned NSImage or token cannot satisfy it.
    let context = try #require(CGContext(data: nil, width: pixels.pixelsWide, height: pixels.pixelsHigh,
        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(box.width * 1.75 / 24)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: box.midX, y: box.minY + box.height * 5 / 24))
    context.addLine(to: CGPoint(x: box.midX, y: box.minY + box.height * 19 / 24))
    context.move(to: CGPoint(x: box.minX + box.width * 5 / 24, y: box.midY))
    context.addLine(to: CGPoint(x: box.minX + box.width * 19 / 24, y: box.midY))
    context.strokePath()
    let mask = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    var mismatches = 0
    for y in Int(box.minY)..<Int(ceil(box.maxY)) {
        for x in Int(box.minX)..<Int(ceil(box.maxX)) {
            let expected = mask.colorAt(x: x, y: y)!.alphaComponent
            let actual = pixels.colorAt(x: x, y: y)!.alphaComponent
            if abs(expected - actual) > 0.04 { mismatches += 1 }
        }
    }
    #expect(mismatches == 0, "visible plus matches both pinned SVG arms at full opacity")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue437SidebarPaintsPinnedGlyphsAndColoursAcrossAppearanceChanges() throws {
    _ = NSApplication.shared
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    tree.viewportWidth = 1280
    tree.show(current: GridSidebarFolder(url: URL(fileURLWithPath: "/tmp/Images")), parent: nil, children: [])
    tree.layoutSubtreeIfNeeded()
    let add = try #require(issue437Control("grid.sidebar.add-folder", in: tree))
    let header = try #require(issue437Control("grid.sidebar.add-folder-plus", in: tree))
    for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
        let dark = name == .darkAqua
        tree.appearance = NSAppearance(named: name)
        tree.viewDidChangeEffectiveAppearance()
        tree.layoutSubtreeIfNeeded()
        for page in [dark ? "grid-dark" : "grid-light", "folder-loading"] {
            let pin = try PinnedDesign.page(page, appearance: dark ? "dark" : "light")
            let expected = try pin.color(":root", "--color-muted", viewport: 1280)
            #expect(try pin.length(".add-folder", "font-size", viewport: 1280) == 12)
            #expect(try pin.length(".add-folder", "gap", viewport: 1280) == 7)
            #expect(try pin.length(".tiny-button", "padding", viewport: 1280) == 2)
            #expect(add.font?.pointSize == 12)
            #expect(add.font?.fontDescriptor.symbolicTraits.contains(.bold) == false)
            #expect(add.frame == NSRect(x: 16, y: add.frame.minY, width: 163, height: 30))
            // Sidebar CSS content ends at195; padding12 + heading padding10 + control18.
            let headerFrame = tree.convert(header.bounds, from: header)
            #expect(abs(headerFrame.minX - 155) <= 1)
            #expect(headerFrame.width == 18)
            #expect(abs(headerFrame.minX + 2 - 157) <= 1)
            let headerPixels = try issue437Pixels(header)
            let headerBox = NSRect(x: 2, y: 2, width: 14, height: 14)
            try issue437ExpectPlus(headerPixels, box: headerBox)
            issue437ExpectColour(headerPixels, in: headerBox, expected: expected, label: "heading plus \(page) \(name)")
            for title in ["Add Folder", "添加文件夹"] {
                add.title = title
                let font = NSFont.systemFont(ofSize: 12, weight: .regular)
                let textWidth = NSAttributedString(string: title, attributes: [.font: font]).size().width
                let glyphX = (add.bounds.width - 15 - 7 - textWidth) / 2
                let glyphBox = NSRect(x: glyphX, y: 7.5, width: 15, height: 15)
                let pixels = try issue437Pixels(add)
                try issue437ExpectPlus(pixels, box: glyphBox)
                issue437ExpectColour(pixels, in: glyphBox, expected: expected, label: "add plus \(page) \(name)")
                let labelBox = NSRect(x: glyphBox.maxX + 7, y: 5, width: textWidth, height: 20)
                issue437ExpectColour(pixels, in: labelBox, expected: expected, label: "label \(page) \(title) \(name)", minimumAlpha: 0.85)
            }
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue437SidebarControlsKeepDisabledAccessibilityAndFocus() throws {
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    for id in ["grid.sidebar.add-folder", "grid.sidebar.add-folder-plus"] {
        let button = try #require(issue437Control(id, in: tree))
        #expect(!button.isEnabled)
        #expect(button.refusesFirstResponder)
        #expect(!button.canBecomeKeyView)
        #expect(button.accessibilityLabel() == "Add Folder · Coming Soon")
        #expect(button.action == nil)
        #expect(button.keyEquivalent.isEmpty)
        #expect(button.subviews.allSatisfy { !$0.isAccessibilityElement() })
        button.performClick(nil)
        #expect(!button.isEnabled)
    }
}
