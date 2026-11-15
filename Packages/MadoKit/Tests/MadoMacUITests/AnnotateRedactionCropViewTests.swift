import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #693 slice B (P7-11) WI-3: 遮挡 and 裁剪 on the strip, the redaction options popover and the overlay's redactions
// and crop (tests-20261114-i693b.md U1–U10). Oracle: page 39, design/prototypes/picsee-browser/states/annotate.html
// (sha256 ab9e5e63…) — :15 and :141–142 the strip titles, :86–97 the `.tool-options` CSS, :155–160 its markup,
// :207–209 its placement — and README rows 79–80 (`?tool=redact` [972, 311, 236, 139.6], `&style=solid`
// [972, 332, 236, 97.8]). Frames are top-left points in a 1280×800 window; CSS px = pt.

@MainActor private final class Container: NSView {
    var fill: NSColor?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let fill else { return }
        fill.setFill()
        bounds.fill()
    }
}

@MainActor private func window(_ size: CGSize = CGSize(width: 1280, height: 800), fill: NSColor? = nil,
                               _ appearance: NSAppearance.Name = .aqua) -> (Container, NSWindow) {
    _ = NSApplication.shared
    let container = Container(frame: NSRect(origin: .zero, size: size))
    container.fill = fill
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = container
    container.appearance = NSAppearance(named: appearance)
    return (container, window)
}

/// Page 39's strings (annotate.html:155–160), so the popover is measured as the page lays it out.
private let page39Strings = AnnotateRedactionOptionsView.Strings(
    dialog: "遮挡选项", title: "遮挡", mosaic: "马赛克", solid: "实色块", strength: "强度", strengthLabel: "马赛克强度",
    hint: "强度低的马赛克可能被还原出文字；真正保密的内容请用实色块。", link: "改用实色块", solidLine: "纯黑色块，不可还原。")

@MainActor private func popoverHost(_ style: RedactionStyle, _ appearance: NSAppearance.Name = .aqua)
    -> (AnnotateRedactionOptionsView, AnnotateStripView, NSWindow) {
    let (container, window) = window(CGSize(width: 1280, height: 800), appearance)
    let strip = AnnotateStripView(frame: .zero)
    container.addSubview(strip)
    strip.update(AnnotateStripState(tool: .redact, canUndo: false, canRedo: false, canSave: false, canCopy: false))
    let popover = AnnotateRedactionOptionsView(strings: page39Strings)
    popover.strip = strip
    container.addSubview(popover)
    popover.update(style)
    container.layoutSubtreeIfNeeded()
    return (popover, strip, window)
}

private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 0.5) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance && abs(a.width - b.width) <= tolerance
        && abs(a.height - b.height) <= tolerance
}

private func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 2) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

@MainActor private func render(_ view: NSView) throws -> NSBitmapImageRep {
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width),
        pixelsHigh: Int(view.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = view.bounds.size
    rep.setProperty(.colorSyncProfileData, withValue: try #require(NSColorSpace.sRGB.iccProfileData))
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private func px(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
    var p = [Int](repeating: 0, count: 4)
    rep.getPixel(&p, atX: x, y: y)
    return p
}

@MainActor private func event(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
        clickCount: 1, pressure: 1))
}

@MainActor private func drag(_ view: NSView, _ points: [CGPoint]) throws {
    guard let first = points.first, let last = points.last else { return }
    view.mouseDown(with: try event(view, .leftMouseDown, first))
    for point in points.dropFirst() { view.mouseDragged(with: try event(view, .leftMouseDragged, point)) }
    view.mouseUp(with: try event(view, .leftMouseUp, last))
}

/// Every string a view tree shows.
@MainActor private func texts(_ view: NSView) -> [String] {
    var out: [String] = []
    if let field = view as? NSTextField { out.append(field.stringValue) }
    if let button = view as? NSButton { out.append(button.title) }
    if let text = view as? NSTextView { out.append(text.string) }
    return out + view.subviews.flatMap(texts)
}

// MARK: - Strip (U1)

@Test(.timeLimit(.minutes(2))) @MainActor func issue693StripEnablesRedactAndCrop() {
    let (container, window) = window()
    defer { window.close() }
    let strip = AnnotateStripView(frame: .zero)
    container.addSubview(strip)
    strip.update(AnnotateStripState(tool: .redact, canUndo: false, canRedo: false, canSave: false, canCopy: false))
    // annotate.html:15 order 选择 | 箭头 矩形 文字 荧光笔 画笔 遮挡 裁剪 序号 | 撤销 重做 | 拷贝 存储 | 完成.
    #expect(AnnotateStripItem.allCases == [.select, .arrow, .rectangle, .text, .highlighter, .pen, .redact, .crop, .step,
                                           .undo, .redo, .copy, .save, .done])
    #expect(strip.button(.redact).isEnabled && strip.button(.crop).isEnabled)
    // annotate.html:141–142 titles 「遮挡 M」「裁剪 C」 (English keys in package tests).
    #expect(strip.button(.redact).toolTip == "Redact M")
    #expect(strip.button(.crop).toolTip == "Crop C")
    #expect(strip.button(.redact).state == .on)
    for item in AnnotateStripItem.allCases where item != .redact { #expect(strip.button(item).state == .off, "\(item)") }
    strip.update(AnnotateStripState(tool: .crop, canUndo: false, canRedo: false, canSave: false, canCopy: false))
    #expect(strip.button(.crop).state == .on && strip.button(.redact).state == .off)
    var log: [AnnotateStripAction] = []
    strip.onAction = { log.append($0) }
    strip.button(.redact).performClick(nil)
    strip.button(.crop).performClick(nil)
    #expect(log == [.tool(.redact), .tool(.crop)])
    // The 遮挡 tool's centre, for the popover's nub: strip top 146 + item y 219 + 16.
    #expect(abs(strip.centreY(of: .redact) - 235) < 0.01)
}

// MARK: - Popover (U2–U6)

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionOptionsFrameMatchesPage39Mosaic() throws {
    let (popover, strip, window) = popoverHost(.mosaic(strength: 24))
    defer { window.close() }
    // README row 79: [972, 311, 236, 139.6]; right edge = strip minX − 12 (annotate.html:86 `right: 72px`).
    #expect(near(popover.frame, CGRect(x: 972, y: 311, width: 236, height: 139.6)), "\(popover.frame)")
    #expect(abs(popover.frame.maxX - (strip.frame.minX - 12)) < 0.01)
    // annotate.html:207–209: the nub sits at the 遮挡 tool's centre (window y 381).
    #expect(abs(popover.nubY - (381 - 311)) < 0.6, "\(popover.nubY)")
    #expect(popover.accessibilityRole() == .popover && popover.accessibilityLabel() == "遮挡选项")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionOptionsFrameMatchesPage39Solid() {
    let (popover, _, window) = popoverHost(.solid)
    defer { window.close() }
    // README row 80: [972, 332, 236, 97.8].
    #expect(near(popover.frame, CGRect(x: 972, y: 332, width: 236, height: 97.8)), "\(popover.frame)")
    #expect(abs(popover.nubY - (381 - 332)) < 0.6)
    // Switching back re-docks at the mosaic frame.
    popover.update(.mosaic(strength: 24))
    #expect(near(popover.frame, CGRect(x: 972, y: 311, width: 236, height: 139.6)), "\(popover.frame)")
}

@Test(.timeLimit(.minutes(2)), arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor func issue693RedactionOptionsHintTextAndColour(_ appearance: NSAppearance.Name) throws {
    let (popover, _, window) = popoverHost(.mosaic(strength: 24), appearance)
    defer { window.close() }
    let hint = popover.hintView
    #expect(!hint.isHidden && popover.solidLine.isHidden)
    #expect(hint.string == "强度低的马赛克可能被还原出文字；真正保密的内容请用实色块。 改用实色块")
    let storage = try #require(hint.textStorage)
    let linkRange = (hint.string as NSString).range(of: "改用实色块")
    try #require(linkRange.location != NSNotFound, "the link is in the hint")
    #expect(storage.attribute(.link, at: linkRange.location, effectiveRange: nil) != nil)
    #expect(storage.attribute(.link, at: 0, effectiveRange: nil) == nil)
    // annotate.html:95: color-mix(banner-unsaved #f59e0b 75%, text 25%); text #1a1a1a light, #e5e7eb dark.
    let dark = appearance == .darkAqua
    let expected: [Double] = dark ? [241, 176.25, 67] : [190.25, 125, 14.75]
    var colour: [Double] = []
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        let c = (storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB)
        colour = [c?.redComponent ?? -1, c?.greenComponent ?? -1, c?.blueComponent ?? -1].map { $0 * 255 }
    }
    #expect(zip(colour, expected).allSatisfy { abs($0 - $1) < 0.6 }, "\(colour)")
    // annotate.html:96 `.link { color: var(--color-accent-text) }`.
    var link: [Double] = []
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        let c = (hint.linkTextAttributes?[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
        link = [c?.redComponent ?? -1, c?.greenComponent ?? -1, c?.blueComponent ?? -1].map { $0 * 255 }
    }
    let accentText = DesignColor.selectionText.components(dark ? .dark : .light).prefix(3)
    // Test fix (WI-3 green): DesignColor components are 0–1, so compare the link's 0–1 components, strictly.
    link = link.map { $0 / 255 }
    #expect(zip(link, accentText).allSatisfy { abs($0 - $1) < 0.003 }, "\(link)")
    #expect(zip(link, accentText).allSatisfy { abs($0 - $1) < 0.6 }, "\(link)")
    // Solid: 「纯黑色块，不可还原。」 in --color-muted (annotate.html:97, :159); no hint.
    popover.update(.solid)
    #expect(popover.hintView.isHidden && !popover.solidLine.isHidden && popover.slider.isHidden)
    #expect(popover.solidLine.stringValue == "纯黑色块，不可还原。")
    var muted: [Double] = []
    NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
        let c = popover.solidLine.textColor?.usingColorSpace(.sRGB)
        muted = [c?.redComponent ?? -1, c?.greenComponent ?? -1, c?.blueComponent ?? -1].map { $0 * 255 }
    }
    let secondary = DesignColor.textSecondary.components(dark ? .dark : .light).prefix(3)
    // Test fix (WI-3 green), as for the link: 0–1 components, strictly.
    muted = muted.map { $0 / 255 }
    #expect(zip(muted, secondary).allSatisfy { abs($0 - $1) < 0.003 }, "\(muted)")
    #expect(zip(muted, secondary).allSatisfy { abs($0 - $1) < 0.6 }, "\(muted)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionSliderHasNoNumbers() {
    let (popover, _, window) = popoverHost(.mosaic(strength: 24))
    defer { window.close() }
    let slider = popover.slider
    #expect(slider.minValue == 16 && slider.maxValue == 64 && slider.integerValue == 24)
    #expect(!slider.isContinuous, "one release, one undo step")
    #expect(slider.numberOfTickMarks == 0)
    #expect(slider.accessibilityLabel() == "马赛克强度")
    // Decision 5.3: no numeric range or value label anywhere.
    #expect(!texts(popover).joined().contains { $0.isNumber }, "\(texts(popover))")
    #expect(texts(popover).contains("强度") && texts(popover).contains("遮挡"))
    #expect(texts(popover).contains("马赛克") && texts(popover).contains("实色块"))
    popover.update(.mosaic(strength: 40))
    #expect(slider.integerValue == 40)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionOptionsReportStyleChanges() throws {
    let (popover, _, window) = popoverHost(.mosaic(strength: 30))
    defer { window.close() }
    var log: [RedactionStyle] = []
    popover.onChange = { log.append($0) }
    popover.update(.solid)
    popover.update(.mosaic(strength: 30))
    #expect(log.isEmpty, "update shows a style without reporting it")
    popover.solidButton.performClick(nil)
    #expect(log == [.solid])
    #expect(popover.solidButton.state == .on && popover.mosaicButton.state == .off)
    popover.mosaicButton.performClick(nil)
    #expect(log.last == .mosaic(strength: 30), "the mosaic comes back at the slider's strength")
    popover.slider.integerValue = 40
    NSApp.sendAction(try #require(popover.slider.action), to: popover.slider.target, from: popover.slider)
    #expect(log.last == .mosaic(strength: 40))
    // 改用实色块.
    let hint = popover.hintView
    let range = (hint.string as NSString).range(of: "改用实色块")
    try #require(range.location != NSNotFound, "the link is in the hint")
    let link = hint.textStorage?.attribute(.link, at: range.location, effectiveRange: nil)
    #expect(hint.delegate?.textView?(hint, clickedOnLink: link as Any, at: range.location) == true)
    #expect(log.last == .solid)
    #expect(log.count == 4)
}

// MARK: - Overlay (U7–U10)

private let page39 = CanvasTransform(backingScale: 1, zoom: 0.32, origin: CGPoint(x: 352, y: 16))
private let actual = CanvasTransform(backingScale: 1, zoom: 1, origin: .zero)

@MainActor private func overlay(_ transform: CanvasTransform = page39, imageSize: CGSize = CGSize(width: 1600, height: 2400),
                                size: CGSize = CGSize(width: 1280, height: 800), fill: NSColor? = nil)
    -> (AnnotationOverlayView, Container, NSWindow) {
    let (container, window) = window(size, fill: fill)
    let overlay = AnnotationOverlayView(frame: container.bounds)
    container.addSubview(overlay)
    overlay.transform = transform
    overlay.imageSize = imageSize
    overlay.isActive = true
    overlay.tool = .select
    return (overlay, container, window)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayDrawsARedactionWithTheToolStyle() throws {
    let (view, _, window) = overlay()
    defer { window.close() }
    var added: [AnnotationMark] = []
    view.onAddMark = { added.append($0) }
    view.tool = .redact
    #expect(view.redactionStyle == .mosaic(strength: 24))
    view.redactionStyle = .solid
    try drag(view, [CGPoint(x: 400, y: 200), CGPoint(x: 450, y: 250), CGPoint(x: 500, y: 300)])
    let rect = try #require(AnnotationGeometry.rect(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300),
                                                    transform: page39, imageSize: CGSize(width: 1600, height: 2400)))
    #expect(added == [.redaction(rect: rect, style: .solid)])
    view.redactionStyle = .mosaic(strength: 40)
    try drag(view, [CGPoint(x: 600, y: 200), CGPoint(x: 700, y: 300)])
    #expect(added.last?.redaction == .mosaic(strength: 40))
    try drag(view, [CGPoint(x: 600, y: 400), CGPoint(x: 602, y: 402)])
    #expect(added.count == 2, "a drag under 4 points adds nothing")
}

/// Seeded noise, sRGB 8-bit.
private func noise(width: Int, height: Int) -> CGImage {
    var state: UInt64 = 11
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        for c in 0..<3 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i * 4 + c] = UInt8(truncatingIfNeeded: state >> 56)
        }
    }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)!
}

/// Top-left sRGB bytes of a CGImage.
private func bytes(_ image: CGImage, _ x: Int, _ y: Int) -> [Int] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    let i = (y * image.width + x) * 4
    return (0..<4).map { Int(data[i + $0]) }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayShowsTheRedactionPatchOrBlack() throws {
    let source = noise(width: 96, height: 64)
    let (view, container, window) = overlay(actual, imageSize: CGSize(width: 96, height: 64),
                                            size: CGSize(width: 96, height: 64), fill: .white)
    defer { window.close() }
    let red = AnnotationMark(rect: CGRect(x: 4, y: 4, width: 30, height: 20),
                             style: AnnotationStyle(red: 1, green: 0, blue: 0, lineWidth: 4))
    let mosaic = AnnotationMark.redaction(rect: CGRect(x: 8, y: 8, width: 48, height: 32), style: .mosaic(strength: 16))
    view.marks = [red, mosaic]
    // Without the source a redaction is opaque black: it never shows what it hides.
    var rep = try render(container)
    for (x, y) in [(8, 8), (30, 20), (55, 39)] { #expect(near(px(rep, x, y), [0, 0, 0, 255]), "\(x),\(y)") }
    #expect(near(px(rep, 70, 50), [255, 255, 255, 255]), "outside is the container")
    // With it, the copy's pixels.
    view.redactionSource = AnnotationOverlayView.RedactionSource(image: source, orientation: 1)
    rep = try render(container)
    var patch = try #require(try AnnotationFlattener.redactionPatch(source, orientation: 1, marks: view.marks, index: 1))
    for (x, y) in [(8, 8), (30, 20), (55, 39), (24, 24)] {
        let expected = bytes(patch.image, x - Int(patch.area.minX), y - Int(patch.area.minY))
        #expect(near(px(rep, x, y), expected), "\(x),\(y): \(px(rep, x, y)) vs \(expected)")
    }
    #expect(near(px(rep, 70, 50), [255, 255, 255, 255]), "outside the redaction the overlay draws no source")
    // A mark under the mosaic moves: the patch follows.
    let before = px(rep, 12, 12)
    view.marks = [AnnotationGeometry.translate(red, by: CGVector(dx: 40, dy: 30), imageSize: CGSize(width: 96, height: 64)),
                  mosaic]
    rep = try render(container)
    patch = try #require(try AnnotationFlattener.redactionPatch(source, orientation: 1, marks: view.marks, index: 1))
    #expect(near(px(rep, 12, 12), bytes(patch.image, 4, 4)))
    #expect(!near(px(rep, 12, 12), before, 0), "the cell under the moved rectangle changed")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayCropDragAndHandles() throws {
    let size = CGSize(width: 1600, height: 2400)
    let (view, container, window) = overlay(fill: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    defer { window.close() }
    var crops: [CGRect] = []
    view.onCropChange = { crops.append($0) }
    view.tool = .crop
    try drag(view, [CGPoint(x: 400.3, y: 100.6), CGPoint(x: 450, y: 200), CGPoint(x: 500.2, y: 300.1)])
    let first = try #require(AnnotationGeometry.cropRect(from: CGPoint(x: 400.3, y: 100.6), to: CGPoint(x: 500.2, y: 300.1),
                                                         transform: page39, imageSize: size))
    #expect(crops == [first])
    view.pendingCrop = first
    // The bottom-right handle, dragged 20 points out.
    let corner = page39.imageToView(CGPoint(x: first.maxX, y: first.maxY))
    try drag(view, [corner, CGPoint(x: corner.x + 20.1, y: corner.y + 20.3)])
    let resized = try #require(crops.last)
    #expect(crops.count == 2)
    #expect(resized.origin == first.origin && resized.width > first.width && resized.height > first.height)
    #expect(resized == resized.integral, "pixel-aligned")
    view.pendingCrop = resized
    // A drag inside moves it, whole pixels, inside the image.
    let inside = page39.imageToView(CGPoint(x: resized.midX, y: resized.midY))
    try drag(view, [inside, CGPoint(x: inside.x - 5000, y: inside.y + 7.7)])
    let moved = try #require(crops.last)
    #expect(moved.size == resized.size && moved.minX == 0 && moved == moved.integral)
    #expect(moved.minY > resized.minY)
    view.pendingCrop = moved
    // Outside the crop 25% black over the image; a 1 pt white border; inside undimmed.
    let rep = try render(container)
    let box = CGRect(origin: page39.imageToView(moved.origin),
                     size: CGSize(width: moved.width * 0.32, height: moved.height * 0.32))
    let outside = px(rep, Int(box.maxX) + 20, Int(box.midY))
    let within = px(rep, Int(box.midX), Int(box.midY))
    #expect(near(within, [128, 128, 128, 255], 3), "\(within)")
    #expect(near(outside, [96, 96, 96, 255], 3), "\(outside)")
    let border = px(rep, Int(box.maxX.rounded(.down)), Int(box.midY))
    #expect(border[0] > 200 && border[1] > 200 && border[2] > 200, "\(border)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayDimsOutsideAnAppliedCrop() throws {
    let (view, container, window) = overlay(fill: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    defer { window.close() }
    let plain = try render(container)
    view.crop = CGRect(x: 100, y: 100, width: 500, height: 500)
    let cropped = try render(container)
    // View box: (352 + 32, 16 + 32) to (352 + 192, 16 + 192).
    let outside = px(cropped, 600, 400), inside = px(cropped, 460, 120)
    #expect(near(px(plain, 600, 400), [128, 128, 128, 255], 3))
    #expect(near(outside, [96, 96, 96, 255], 3), "\(outside)")
    #expect(near(inside, px(plain, 460, 120), 1), "\(inside)")
    #expect(near(px(cropped, 1250, 400), px(plain, 1250, 400), 0), "beyond the image nothing is dimmed")
    view.crop = nil
    #expect(near(px(try render(container), 600, 400), px(plain, 600, 400), 0))
}

// MARK: - Coverage (coverage phase): strings, archiving, re-docking, drawing, a new crop beside one, the cached patch

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionOptionsUseTheCatalogKeysAndAreNotArchivable() {
    let strings = AnnotateRedactionOptionsView.Strings.localized
    #expect([strings.dialog, strings.title, strings.mosaic, strings.solid, strings.strength, strings.strengthLabel,
             strings.hint, strings.link, strings.solidLine] == ["Redaction Options", "Redact", "Mosaic", "Solid", "Strength",
        "Mosaic Strength", "A weak mosaic can be reversed to reveal text; use a solid box for anything truly secret.",
        "Use Solid Box", "Solid black box; cannot be reversed."])
    #expect(AnnotateRedactionOptionsView(coder: NSKeyedArchiver(requiringSecureCoding: false)) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionOptionsRedockWhenTheWindowResizes() throws {
    let (popover, strip, window) = popoverHost(.mosaic(strength: 24))
    defer { window.close() }
    let container = try #require(popover.superview)
    for size in [CGSize(width: 1000, height: 600), CGSize(width: 1400, height: 900)] {
        container.setFrameSize(size)
        let stripFrame = AnnotateStripView.frame(in: size)
        let expected = AnnotateRedactionOptionsView.placement(height: popover.frame.height, stripFrame: stripFrame,
            toolCentreY: stripFrame.minY + strip.centreY(of: .redact), containerHeight: size.height)
        #expect(near(popover.frame, expected.frame), "\(size): \(popover.frame) vs \(expected.frame)")
        #expect(popover.nubY == expected.nubY)
    }
}

@Test(.timeLimit(.minutes(2)), arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor func issue693RedactionOptionsDrawThePanelAndThePressedSegment(_ appearance: NSAppearance.Name) throws {
    let (popover, _, window) = popoverHost(.mosaic(strength: 24), appearance)
    defer { window.close() }
    let rep = try render(popover)
    let panel = px(rep, Int(popover.bounds.midX), 4)
    let theme: DesignTheme = appearance == .darkAqua ? .dark : .light
    let expected = DesignColor.popoverBackground.components(theme).prefix(3).map { Int(($0 * 255).rounded()) } + [255]
    #expect(near(panel, expected, 3), "panel \(panel) vs \(expected)")
    // The pressed segment (马赛克) is panel-filled; the other shows the track.
    let pressed = popover.mosaicButton.convert(popover.mosaicButton.bounds, to: popover)
    let other = popover.solidButton.convert(popover.solidButton.bounds, to: popover)
    let on = px(rep, Int(pressed.minX) + 3, Int(pressed.midY)), off = px(rep, Int(other.maxX) - 3, Int(other.midY))
    #expect(near(on, panel, 3), "pressed \(on) vs panel \(panel)")
    #expect(!near(off, panel, 1), "the track \(off) differs from the panel \(panel)")
    // Switching to 实色块 moves the fill.
    popover.update(.solid)
    let solid = try render(popover)
    #expect(near(px(solid, Int(other.maxX) - 3, Int(other.midY)), panel, 3))
    #expect(!near(px(solid, Int(pressed.minX) + 3, Int(pressed.midY)), panel, 1))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayDragOutsideAShownCropStartsANewOne() throws {
    let size = CGSize(width: 1600, height: 2400)
    let (view, _, window) = overlay()
    defer { window.close() }
    var crops: [CGRect] = []
    view.onCropChange = { crops.append($0) }
    view.tool = .crop
    view.pendingCrop = CGRect(x: 100, y: 100, width: 200, height: 200)
    try drag(view, [CGPoint(x: 600, y: 400), CGPoint(x: 650, y: 450), CGPoint(x: 700, y: 500)])
    let expected = try #require(AnnotationGeometry.cropRect(from: CGPoint(x: 600, y: 400), to: CGPoint(x: 700, y: 500),
                                                            transform: page39, imageSize: size))
    #expect(crops == [expected])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayKeepsTheLastPatchWhileAMarkBeforeItIsDragged() throws {
    let source = noise(width: 96, height: 64)
    let (view, container, window) = overlay(actual, imageSize: CGSize(width: 96, height: 64),
                                            size: CGSize(width: 96, height: 64), fill: .white)
    defer { window.close() }
    let red = AnnotationMark(rect: CGRect(x: 4, y: 4, width: 30, height: 20),
                             style: AnnotationStyle(red: 1, green: 0, blue: 0, lineWidth: 4))
    let mosaic = AnnotationMark.redaction(rect: CGRect(x: 8, y: 8, width: 48, height: 32), style: .mosaic(strength: 16))
    view.marks = [red, mosaic]
    view.redactionSource = AnnotationOverlayView.RedactionSource(image: source, orientation: 1)
    let shown = try render(container)
    let patch = try #require(try AnnotationFlattener.redactionPatch(source, orientation: 1, marks: view.marks, index: 1))
    #expect(near(px(shown, 12, 12), bytes(patch.image, 4, 4)))
    // Drag the rectangle (held): the mosaic keeps its last patch instead of recomputing on every move.
    view.tool = .select
    view.selectedMark = 0
    view.mouseDown(with: try event(view, .leftMouseDown, CGPoint(x: 5, y: 5)))
    view.mouseDragged(with: try event(view, .leftMouseDragged, CGPoint(x: 45, y: 35)))
    #expect(view.isDragging)
    let held = try render(container)
    #expect(near(px(held, 12, 12), bytes(patch.image, 4, 4), 0), "the cached patch: \(px(held, 12, 12))")
    #expect(near(px(held, 16, 36), bytes(patch.image, 8, 28), 0))
    view.mouseUp(with: try event(view, .leftMouseUp, CGPoint(x: 45, y: 35)))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693OverlayShowsTheAppliedCropWithTheCropToolAndNothingPending() throws {
    let (view, container, window) = overlay(fill: NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    defer { window.close() }
    view.tool = .crop
    view.crop = CGRect(x: 100, y: 100, width: 500, height: 500)
    let rep = try render(container)
    #expect(near(px(rep, 600, 400), [96, 96, 96, 255], 3), "outside the applied crop is dimmed")
    #expect(near(px(rep, 460, 120), [128, 128, 128, 255], 3), "inside it is not")
    // A pending crop replaces it on screen while the crop tool is chosen.
    view.pendingCrop = CGRect(x: 1000, y: 1000, width: 400, height: 400)
    #expect(near(px(try render(container), 460, 120), [96, 96, 96, 255], 3))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue693RedactionOptionsFollowAutoresizingWithoutNotifications() throws {
    let (popover, strip, window) = popoverHost(.mosaic(strength: 24))
    defer { window.close() }
    let container = try #require(popover.superview)
    container.postsFrameChangedNotifications = false
    container.autoresizesSubviews = false
    let old = container.frame.size
    let before = popover.frame
    let size = CGSize(width: 1440, height: 900)
    container.setFrameSize(size)
    #expect(popover.frame == before, "nothing moved yet")
    popover.resize(withOldSuperviewSize: old)
    let stripFrame = AnnotateStripView.frame(in: size)
    let expected = AnnotateRedactionOptionsView.placement(height: popover.frame.height, stripFrame: stripFrame,
        toolCentreY: stripFrame.minY + strip.centreY(of: .redact), containerHeight: size.height)
    #expect(near(popover.frame, expected.frame), "\(popover.frame) vs \(expected.frame)")
}
