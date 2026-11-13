import AppKit
import Testing
@testable import MadoMacUI

@MainActor private func inlineHint(_ root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityIdentifier() == "first-launch.shortcut" { return field }
    for child in root.subviews {
        if let field = inlineHint(child) { return field }
    }
    return nil
}

@MainActor private func shortcutKey(_ root: NSView) -> NSTextField? {
    if let field = root as? NSTextField, field.accessibilityIdentifier() == "first-launch.shortcut-key" { return field }
    for child in root.subviews {
        if let field = shortcutKey(child) { return field }
    }
    return nil
}

@MainActor private func paintedInk(in field: NSTextField) throws -> Int {
    let width = Int(ceil(field.bounds.width))
    let height = Int(ceil(field.bounds.height))
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = field.bounds.size
    field.cacheDisplay(in: field.bounds, to: bitmap)
    var ink = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            if let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
               pixel.alphaComponent > 0.1,
               min(pixel.redComponent, pixel.greenComponent, pixel.blueComponent) < 0.8 { ink += 1 }
        }
    }
    return ink
}

@MainActor private func fullTextReference(for hint: NSTextField, width: CGFloat) -> NSTextField {
    let prefix = hint.stringValue.replacingOccurrences(of: "⌘O", with: "").trimmingCharacters(in: .whitespaces)
    let reference = NSTextField(labelWithString: prefix)
    reference.font = hint.font
    reference.textColor = hint.textColor
    reference.alignment = hint.alignment
    reference.cell?.wraps = true
    reference.cell?.usesSingleLineMode = false
    reference.maximumNumberOfLines = 0
    reference.frame = NSRect(x: 0, y: 0, width: width, height: 400)
    return reference
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue92ShortcutHintPaintsCompleteEnglishSentence() throws {
    let scene = StatesScene(width: 1280)
    defer { scene.window.close() }
    scene.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    scene.window.setContentSize(NSSize(width: 1280, height: 800))
    scene.content.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    scene.state.frame = scene.content.bounds
    scene.window.orderFront(nil)
    scene.state.layoutSubtreeIfNeeded()
    let hint = try #require(inlineHint(scene.state))
    let key = try #require(shortcutKey(scene.state))
    #expect(hint.stringValue == "or press ⌘O")
    let actual = try paintedInk(in: hint)
    let reference = try paintedInk(in: fullTextReference(for: hint, width: 640))
    #expect(reference > 100)
    #expect(actual > 100)
    let keyInk = try paintedInk(in: key)
    #expect(actual >= Int(Double(reference) * 0.95))
    #expect(keyInk > 40)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue92ShortcutHintPaintsChineseAtCompactSize() throws {
    let scene = StatesScene(width: 800)
    defer { scene.window.close() }
    scene.window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
    scene.window.setContentSize(NSSize(width: 800, height: 680))
    scene.content.frame = NSRect(x: 0, y: 0, width: 800, height: 680)
    scene.state.frame = scene.content.bounds
    scene.window.orderFront(nil)
    let hint = try #require(inlineHint(scene.state))
    let key = try #require(shortcutKey(scene.state))
    hint.stringValue = "或按 ⌘O"
    scene.state.needsLayout = true
    scene.state.layoutSubtreeIfNeeded()
    let chinese = try paintedInk(in: hint)
    let chineseReference = try paintedInk(in: fullTextReference(for: hint, width: 640))
    #expect(chineseReference > 100)
    #expect(chinese > 100)
    let keyInk = try paintedInk(in: key)
    #expect(chinese >= Int(Double(chineseReference) * 0.95))
    #expect(keyInk > 40)

    scene.window.setContentSize(NSSize(width: 360, height: 680))
    scene.content.frame = NSRect(x: 0, y: 0, width: 360, height: 680)
    scene.state.frame = scene.content.bounds
    scene.state.needsLayout = true
    scene.state.layoutSubtreeIfNeeded()
    let compact = try paintedInk(in: hint)
    #expect(compact >= Int(Double(chineseReference) * 0.95))
}
