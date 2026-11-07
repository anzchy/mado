import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private func issue282StateView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let match = issue282StateView(id, in: child) { return match }
    }
    return nil
}

@MainActor private func issue282Frame(_ id: String, in host: ViewerStateHost) throws -> NSRect {
    let view = try #require(issue282StateView(id, in: host))
    return host.convert(view.bounds, from: view)
}

private func issue282PathEndpoints(_ path: CGPath) -> (start: CGPoint, end: CGPoint)? {
    var start: CGPoint?
    var end: CGPoint?
    path.applyWithBlock { element in
        let point: CGPoint?
        switch element.pointee.type {
        case .moveToPoint, .addLineToPoint:
            point = element.pointee.points[0]
        case .addQuadCurveToPoint:
            point = element.pointee.points[1]
        case .addCurveToPoint:
            point = element.pointee.points[2]
        case .closeSubpath:
            point = nil
        @unknown default:
            point = nil
        }
        guard let point else { return }
        if start == nil { start = point }
        end = point
    }
    guard let start, let end else { return nil }
    return (start, end)
}

@Test @MainActor func issue282ReadingContentMatchesPinnedFramesAndCancelStyle() throws {
    for (appearanceName, designAppearance) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
        let design = try PinnedDesign.page("folder-loading", appearance: designAppearance)
        let scene = StatesScene(width: 1084)
        defer { scene.window.close() }
        scene.state.appearance = NSAppearance(named: appearanceName)
        scene.state.display(.readingFolder)
        // The grid presentation moves the host onto the main frame after display (1084x722 on the pinned page).
        scene.state.frame = NSRect(x: 0, y: 40, width: 1084, height: 722)
        scene.state.layoutSubtreeIfNeeded()
        let progress = try issue282Frame("state.folder-progress", in: scene.state)
        let headingView = try #require(issue282StateView("state.folder-title", in: scene.state) as? NSTextField)
        let heading = try issue282Frame("state.folder-title", in: scene.state)
        let subtitleView = try #require(issue282StateView("state.folder-subtitle", in: scene.state) as? NSTextField)
        let subtitle = try issue282Frame("state.folder-subtitle", in: scene.state)
        let cancel = try #require(issue282StateView("state.cancel-folder", in: scene.state) as? NSButton)
        func fromTop(_ y: CGFloat) -> CGFloat { scene.state.bounds.height - y }

        // folder-loading.html in a 722pt main area (Chrome 1280x800, main top 38): .mock-progress top 269.45,
        // h2 line box 323.45–346.45, p line box 355.45–377.55, .text-button 403.55–438.55 (68 wide).
        #expect(progress.size == NSSize(width: 28, height: 28))
        #expect(abs(fromTop(progress.maxY) - 269.45) <= 1)
        #expect(abs(progress.midX - scene.state.bounds.midX) <= 0.5)
        #expect(headingView.font == .systemFont(ofSize: 16, weight: .medium))
        #expect(headingView.stringValue == "Reading Folder…")
        #expect(abs(fromTop(heading.midY) - (323.45 + 23 / 2)) <= 1)
        #expect(abs(heading.height - ceil(headingView.intrinsicContentSize.height)) <= 1)
        #expect(subtitleView.font?.pointSize == 13)
        #expect(subtitleView.stringValue == "Looking for images to browse. Please wait.")
        #expect(abs(fromTop(subtitle.midY) - (355.45 + 22.1 / 2)) <= 1)
        #expect(abs(subtitle.height - ceil(subtitleView.intrinsicContentSize.height)) <= 1)
        #expect(!cancel.isBordered)
        #expect(abs(fromTop(cancel.frame.maxY) - 403.55) <= 1)
        #expect(abs(cancel.frame.height - 35) <= 1)
        #expect(abs(cancel.frame.midX - scene.state.bounds.midX) <= 1)
        #expect(cancel.acceptsFirstResponder)
        #expect(cancel.accessibilityLabel() == "Cancel Reading")
        var tint: NSColor?
        cancel.effectiveAppearance.performAsCurrentDrawingAppearance {
            tint = cancel.contentTintColor?.usingColorSpace(.sRGB)
        }
        let expected = try design.color(".text-button", "color", viewport: 1280)
        let actual = try #require(tint)
        #expect(abs(actual.redComponent - expected.red) < 0.01)
        #expect(abs(actual.greenComponent - expected.green) < 0.01)
        #expect(abs(actual.blueComponent - expected.blue) < 0.01)

        var restored = 0
        scene.state.onCancelFolderReading = { restored += 1 }
        cancel.performClick(nil)
        #expect(restored == 1)
    }
}

/// Device parity-281-282-10301650 FAIL-4b: the ring drew 21pt left of the centred heading. The spin must pivot on the
/// ring's centre after the late frame changes (host moved onto the main frame, window resized, sidebar toggled).
/// Reduce Motion is pinned per case; the machine's setting must not decide the result (the PR #304 CI
/// runner reported no spin, the path taken only when Reduce Motion reads as on).
@Test(arguments: [false, true]) @MainActor
func issue282ReadingRingSpinsAroundTheHeadingCentreAfterLateFrames(reduceMotion: Bool) throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    window.contentView = host
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let state = ViewerStateHost(frame: host.bounds, session: ViewerSession())
    let canvas = NSView(), chrome = NSView(), grid = NSView()
    host.addSubview(canvas)
    host.addSubview(shell)
    host.addSubview(state, positioned: .above, relativeTo: shell)
    host.addSubview(chrome, positioned: .above, relativeTo: state)
    let presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state,
        grid: grid, inspector: NSView(), shell: shell)
    presentation.showGrid(reading: false)
    #expect(presentation.showReadingOverGrid(true))
    state.display(.readingFolder)
    window.displayIfNeeded()
    let ring = try #require(issue282StateView("state.folder-progress", in: state) as? ReadingProgressView)
    let heading = try #require(issue282StateView("state.folder-title", in: state) as? NSTextField)
    ring.reduceMotion = { reduceMotion }
    ring.start()

    func expectCentred(_ step: String) throws {
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let spin = try #require(ring.rotationLayer)
        let base = try #require(ring.layer)
        let pivot = CGPoint(x: spin.bounds.minX + spin.anchorPoint.x * spin.bounds.width,
                            y: spin.bounds.minY + spin.anchorPoint.y * spin.bounds.height)
        let pivotInWindow = ring.convert(spin.convert(pivot, to: base), to: nil)
        let ringCentre = ring.convert(NSPoint(x: ring.bounds.midX, y: ring.bounds.midY), to: nil)
        let headingCentre = heading.convert(NSPoint(x: heading.bounds.midX, y: heading.bounds.midY), to: nil)
        #expect(abs(ringCentre.x - headingCentre.x) <= 1, "\(step): ring frame centre")
        #expect(abs(pivotInWindow.x - headingCentre.x) <= 1, "\(step): spin pivot x \(pivotInWindow.x) vs \(headingCentre.x)")
        #expect(abs(pivotInWindow.y - ringCentre.y) <= 1, "\(step): spin pivot y \(pivotInWindow.y) vs \(ringCentre.y)")
        #expect((spin.animation(forKey: "mado.reading.rotation") != nil) == !reduceMotion,
                "\(step): ring spins unless Reduce Motion is on")
    }
    try expectCentred("display")
    window.setContentSize(NSSize(width: 1100, height: 760))
    presentation.layoutInspector(visible: false)
    try expectCentred("window resize")
    shell.toggleSidebar()
    try expectCentred("sidebar hidden")
    shell.toggleSidebar()
    shell.resizeSidebar(to: 280)
    try expectCentred("sidebar shown and resized")
}

@Test @MainActor func issue282ReadingProgressViewIsNotDecodable() {
    #expect(ReadingProgressView(coder: NSCoder()) == nil)
}

@Test @MainActor func issue282ReadingRingUsesAccentSegmentAndStopsForReduceMotion() throws {
    for (page, appearanceName) in [("folder-loading", NSAppearance.Name.aqua), ("folder-loading", .darkAqua)] {
        let design = try PinnedDesign.page(page, appearance: appearanceName == .aqua ? "light" : "dark")
        let view = ReadingProgressView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        view.appearance = NSAppearance(named: appearanceName)
        view.reduceMotion = { false }
        view.start()
        // folder-loading.html: one 28x28 border box, 2px stroke, with its top quarter in accent.
        #expect(view.dividerLayer.lineWidth == 2)
        #expect(view.accentLayer.lineWidth == 2)
        #expect(view.accentLayer.lineCap == .butt)
        let dividerPath = try #require(view.dividerLayer.path)
        let accentPath = try #require(view.accentLayer.path)
        let dividerBounds = dividerPath.boundingBoxOfPath
        #expect(dividerBounds == CGRect(x: 1, y: 1, width: 26, height: 26))
        let center = CGPoint(x: dividerBounds.midX, y: dividerBounds.midY)
        #expect(center == CGPoint(x: 14, y: 14))
        let accentEndpoints = try #require(issue282PathEndpoints(accentPath))
        let expectedStart = CGPoint(x: center.x + 13 * cos(CGFloat.pi / 4),
                                    y: center.y + 13 * sin(CGFloat.pi / 4))
        let expectedEnd = CGPoint(x: center.x + 13 * cos(3 * CGFloat.pi / 4),
                                  y: center.y + 13 * sin(3 * CGFloat.pi / 4))
        #expect(abs(accentEndpoints.start.x - expectedStart.x) < 0.0001)
        #expect(abs(accentEndpoints.start.y - expectedStart.y) < 0.0001)
        #expect(abs(accentEndpoints.end.x - expectedEnd.x) < 0.0001)
        #expect(abs(accentEndpoints.end.y - expectedEnd.y) < 0.0001)
        #expect(abs(hypot(accentEndpoints.start.x - center.x, accentEndpoints.start.y - center.y) - 13) < 0.0001)
        #expect(abs(hypot(accentEndpoints.end.x - center.x, accentEndpoints.end.y - center.y) - 13) < 0.0001)
        let dividerColor = try #require(view.dividerLayer.strokeColor)
        let divider = try #require(NSColor(cgColor: dividerColor)?.usingColorSpace(.sRGB))
        let expectedDivider = try design.color(":root", "--color-border", viewport: 1280)
        #expect(abs(divider.redComponent - expectedDivider.red) < 0.01)
        #expect(abs(divider.greenComponent - expectedDivider.green) < 0.01)
        #expect(abs(divider.blueComponent - expectedDivider.blue) < 0.01)
        let accentColor = try #require(view.accentLayer.strokeColor)
        let accent = try #require(NSColor(cgColor: accentColor)?.usingColorSpace(.sRGB))
        let expectedAccent = try design.color(":root", "--color-accent", viewport: 1280)
        #expect(abs(accent.redComponent - expectedAccent.red) < 0.01)
        #expect(abs(accent.greenComponent - expectedAccent.green) < 0.01)
        #expect(abs(accent.blueComponent - expectedAccent.blue) < 0.01)
        #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") != nil)
        view.reduceMotion = { true }
        view.start()
        #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") == nil)
        #expect(view.accessibilityRole() == .progressIndicator)
    }
}

@Test @MainActor func issue282ReadingRingUpdatesRotationWhenReduceMotionChanges() {
    let view = ReadingProgressView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
    #expect(view.notificationCenter === NSWorkspace.shared.notificationCenter)
    var reduceMotion = false
    view.reduceMotion = { reduceMotion }
    view.start()
    #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") != nil)

    reduceMotion = true
    NotificationCenter.default.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                    object: NSWorkspace.shared)
    #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") != nil)
    view.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                 object: NSWorkspace.shared)
    #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") == nil)

    reduceMotion = false
    NotificationCenter.default.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                    object: NSWorkspace.shared)
    #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") == nil)
    view.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                 object: NSWorkspace.shared)
    #expect(view.rotationLayer?.animation(forKey: "mado.reading.rotation") != nil)
}
