import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #690 (P7-11) WI-5: page 39 (annotate.html, sha256 ab9e5e63…) — the vertical tool strip, rows B2–B6 and B8.
// Frames are top-left points in the window's content; CSS px = pt.

@MainActor private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private func stripHost(_ size: CGSize = CGSize(width: 1280, height: 800),
                                  state: AnnotateStripState = AnnotateStripState(tool: .rectangle, canUndo: true,
                                      canRedo: false, canSave: true, canCopy: true))
    -> (AnnotateStripView, FlippedContainer, NSWindow) {
    _ = NSApplication.shared
    let container = FlippedContainer(frame: NSRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.appearance = NSAppearance(named: .aqua)
    let strip = AnnotateStripView(frame: .zero)
    container.addSubview(strip)
    strip.update(state)
    container.layoutSubtreeIfNeeded()
    return (strip, container, window)
}

private let tools: [AnnotateStripItem] = [.select, .arrow, .rectangle, .text, .highlighter, .pen, .redact, .crop, .step,
                                          .undo, .redo]
private let textItems: [AnnotateStripItem] = [.copy, .save, .done]
private let unimplemented: [AnnotateStripItem] = [.arrow, .text, .highlighter, .pen, .redact, .crop, .step]

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripFrameMatchesPage39() {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    #expect(strip.frame == CGRect(x: 1220, y: 146, width: 48, height: 508))
    #expect(AnnotateStripView.frame(in: CGSize(width: 1280, height: 800)) == CGRect(x: 1220, y: 146, width: 48, height: 508))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripItemOrderAndLabels() throws {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    let all = AnnotateStripItem.allCases
    let byTop = all.sorted { strip.button($0).frame.minY < strip.button($1).frame.minY }
    #expect(byTop == all)
    #expect(all.map { strip.button($0).accessibilityLabel() ?? "" } == ["Select", "Arrow", "Rectangle", "Text",
        "Highlighter", "Pen", "Redact", "Crop", "Step", "Undo", "Redo", "Copy", "Save", "Done"])
    #expect(strip.separators.count == 4)
    // Each separator sits between: Select|Arrow, Step|Undo, Redo|Copy, Save|Done.
    let pairs: [(AnnotateStripItem, AnnotateStripItem)] = [(.select, .arrow), (.step, .undo), (.redo, .copy), (.save, .done)]
    for (separator, pair) in zip(strip.separators.sorted { $0.frame.minY < $1.frame.minY }, pairs) {
        #expect(separator.frame.minY > strip.button(pair.0).frame.maxY && separator.frame.maxY < strip.button(pair.1).frame.minY)
    }
    #expect(strip.accessibilityRole() == .toolbar)
    #expect(strip.accessibilityLabel() == "Annotation Tools")
    #expect(strip.button(.copy).title == "Copy" && strip.button(.save).title == "Save" && strip.button(.done).title == "Done")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripItemGeometry() {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    let toolTops: [CGFloat] = [4, 49, 83, 117, 151, 185, 219, 253, 287, 332, 366]
    for (item, top) in zip(tools, toolTops) {
        #expect(strip.button(item).frame == CGRect(x: 8, y: top, width: 32, height: 32), "\(item)")
    }
    for (item, top) in zip(textItems, [CGFloat(411), 439, 478]) {
        #expect(strip.button(item).frame == CGRect(x: 4, y: top, width: 40, height: 26), "\(item)")
    }
    let separators = strip.separators.map(\.frame).sorted { $0.minY < $1.minY }
    #expect(separators == [42, 325, 404, 471].map { CGRect(x: 12, y: $0, width: 24, height: 1) })
    #expect(strip.scrollView.documentView?.frame.height == 508)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripShortWindowScrolls() throws {
    let (strip, _, window) = stripHost(CGSize(width: 1280, height: 480))
    defer { window.close() }
    #expect(strip.frame == CGRect(x: 1220, y: 12, width: 48, height: 456))
    let document = try #require(strip.scrollView.documentView)
    #expect(document.frame.height == 508)
    #expect(strip.scrollView.contentView.bounds.height == 456)
    let done = strip.button(.done)
    #expect(!strip.scrollView.contentView.bounds.contains(done.frame), "Done starts below the visible part")
    done.scrollToVisible(done.bounds)
    #expect(strip.scrollView.contentView.bounds.contains(done.frame))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripResizesWithItsWindow() {
    let (strip, container, window) = stripHost()
    defer { window.close() }
    container.setFrameSize(NSSize(width: 1440, height: 900))
    #expect(strip.frame == CGRect(x: 1380, y: 196, width: 48, height: 508))
    container.setFrameSize(NSSize(width: 1280, height: 480))
    #expect(strip.frame == CGRect(x: 1220, y: 12, width: 48, height: 456))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripNeverOverlapsImageProperty() {
    for seed in UInt64(1)...200 {
        var random = StripRandom(seed: seed)
        let size = CGSize(width: Double(Int.random(in: 400...2560, using: &random)),
                          height: Double(Int.random(in: 300...1600, using: &random)))
        let source = CGSize(width: Double(Int.random(in: 10...8000, using: &random)),
                            height: Double(Int.random(in: 10...8000, using: &random)))
        let strip = AnnotateStripView.frame(in: size)
        let fit = CanvasTransform.fitted(source: source, viewport: size, backingScale: 1, trailingReserve: 64)
        let imageMaxX = fit.imageToView(CGPoint(x: source.width, y: source.height)).x
        #expect(fit.zoom == 1 || imageMaxX <= strip.minX - 4 + 1e-6, "seed \(seed)")
        #expect(strip.height <= size.height - 24 && strip.width == 48, "seed \(seed)")
        #expect(strip.maxX == size.width - 12, "seed \(seed)")
        if size.height - 24 >= 508 {
            #expect(strip.height == 508 && strip.midY == size.height / 2, "seed \(seed)")
        } else {
            #expect(strip.minY == 12, "seed \(seed)")
        }
    }
}

/// One pixel's sRGB bytes 0…255 and alpha 0…1, read raw: `colorAt` labels these sRGB bytes Generic RGB.
@MainActor func srgbPixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Double] {
    var p = [Int](repeating: 0, count: 4)
    rep.getPixel(&p, atX: x, y: y)
    let alpha = rep.hasAlpha ? Double(p[3]) / 255 : 1
    let premultiplied = rep.hasAlpha && !rep.bitmapFormat.contains(.alphaNonpremultiplied)
    let rgb = p.prefix(3).map { premultiplied && alpha > 0 ? Double($0) / alpha : Double($0) }
    return rgb + [alpha]
}

private struct StripRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripToolStates() {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    #expect(strip.button(.rectangle).state == .on && strip.button(.select).state == .off)
    #expect(strip.button(.select).isEnabled && strip.button(.rectangle).isEnabled)
    for item in unimplemented { #expect(!strip.button(item).isEnabled, "\(item)") }
    #expect(strip.button(.undo).isEnabled && !strip.button(.redo).isEnabled)
    #expect(strip.button(.save).isEnabled && strip.button(.copy).isEnabled && strip.button(.done).isEnabled)
    strip.update(AnnotateStripState(tool: .select, canUndo: false, canRedo: true, canSave: false, canCopy: false))
    #expect(strip.button(.select).state == .on && strip.button(.rectangle).state == .off)
    #expect(!strip.button(.undo).isEnabled && strip.button(.redo).isEnabled)
    #expect(!strip.button(.save).isEnabled && !strip.button(.copy).isEnabled && strip.button(.done).isEnabled)
    for item in unimplemented { #expect(!strip.button(item).isEnabled, "\(item)") }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripDisabledToolsIgnoreClicks() {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    var log: [AnnotateStripAction] = []
    strip.onAction = { log.append($0) }
    for item in unimplemented { strip.button(item).performClick(nil) }
    #expect(log == [])
    strip.button(.rectangle).performClick(nil)
    strip.button(.select).performClick(nil)
    strip.button(.undo).performClick(nil)
    strip.button(.copy).performClick(nil)
    strip.button(.save).performClick(nil)
    strip.button(.done).performClick(nil)
    #expect(log == [.tool(.rectangle), .tool(.select), .undo, .copy, .save, .done])
    strip.update(AnnotateStripState(tool: .rectangle, canUndo: true, canRedo: true, canSave: true, canCopy: true))
    strip.button(.redo).performClick(nil)
    #expect(log.last == .redo)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripTooltips() throws {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    #expect(strip.button(.select).toolTip == "Select V")
    #expect(strip.button(.rectangle).toolTip == "Rectangle R")
    #expect(strip.button(.undo).toolTip == "Undo ⌘Z" && strip.button(.redo).toolTip == "Redo ⇧⌘Z")
    #expect(strip.button(.copy).toolTip == "Copy ⌘C" && strip.button(.save).toolTip == "Save ⌘S")
    #expect(strip.button(.done).toolTip == "Done Esc")
    let letter = try Regex(" [A-Z]$")
    for item in unimplemented {
        let tip = strip.button(item).toolTip ?? ""
        #expect(tip == strip.button(item).accessibilityLabel(), "\(item): the bare name")
        #expect(tip.firstMatch(of: letter) == nil && !tip.contains("Coming Soon") && !tip.contains("即将推出"), "\(item)")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue690StripSaveIsAccentFilled() throws {
    let (strip, _, window) = stripHost()
    defer { window.close() }
    let rep = try #require(strip.bitmapImageRepForCachingDisplay(in: strip.bounds))
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    strip.cacheDisplay(in: strip.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / strip.bounds.width
    func pixel(_ x: CGFloat, _ y: CGFloat) throws -> [Double] {
        srgbPixel(rep, Int(x * scale), Int(y * scale)).prefix(3).map { $0.rounded() }
    }
    let accent = DesignColor.primaryFill.components(.light).prefix(3).map { ($0 * 255).rounded() }
    let save = try pixel(8, 439 + 13)
    #expect(zip(save, accent).allSatisfy { abs($0 - $1) <= 2 }, "\(save)")
    let copy = try pixel(8, 411 + 13)
    #expect(!zip(copy, accent).allSatisfy { abs($0 - $1) <= 2 }, "\(copy)")
    let rectangle = try pixel(10, 83 + 4)
    #expect(zip(rectangle, accent).allSatisfy { abs($0 - $1) <= 2 }, "the pressed tool is accent-filled: \(rectangle)")
}
