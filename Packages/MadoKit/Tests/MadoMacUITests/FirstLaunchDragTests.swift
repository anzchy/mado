import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@MainActor private func b4View(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = b4View(id, in: child) { return found }
    }
    return nil
}

@MainActor private final class B4DragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ board: NSPasteboard) { draggingPasteboard = board }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
    func resetSpringLoading() { }
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4DragCallbackTracksAcceptedLifecycle() throws {
    _ = NSApplication.shared
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.writeObjects([URL(fileURLWithPath: "/photos/A.jpg") as NSURL]))
    let info = B4DragInfo(board)
    var events: [Bool] = []
    var dropped = 0
    let view = ViewerDropView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
                              acceptsDrop: { true }, onDrop: { _ in dropped += 1 })
    view.onDragActive = { events.append($0) }
    #expect(view.draggingEntered(info) == .copy)
    #expect(events == [true])
    view.draggingExited(info)
    #expect(events == [true, false])
    #expect(view.draggingEntered(info) == .copy)
    #expect(view.performDragOperation(info))
    #expect(events == [true, false, true, false])
    #expect(dropped == 1)
    #expect(view.draggingEntered(info) == .copy)
    view.draggingEnded(info)
    #expect(events == [true, false, true, false, true, false])
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4AppearanceDragAndAccessibilityPresentation() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    let launch = try #require(scene.state.subviews.compactMap { $0 as? FirstLaunchView }.first)
    launch.layoutSubtreeIfNeeded()
    let heading = try #require(b4View("first-launch.heading", in: scene.state) as? NSTextField)
    let drop = try #require(b4View("first-launch.drop", in: scene.state))
    let outline = try #require(drop.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    launch.themeOverride = .light; scene.state.setFirstLaunchDragActive(true)
    launch.layoutSubtreeIfNeeded()
    #expect(heading.stringValue == "Release to open")
    #expect(outline.lineWidth == 1.5 && !outline.isHidden)
    #expect(outline.lineDashPattern == [6, 4])
    #expect((drop.layer?.backgroundColor?.alpha ?? 0) > 0)
    launch.setDragActive(false)
    #expect(heading.stringValue == "Drop a photo folder here")
    #expect(outline.isHidden)
    #expect((drop.layer?.backgroundColor?.alpha ?? 1) == 0)
    launch.themeOverride = .dark; launch.setDragActive(true)
    launch.reduceMotionOverride = true
    launch.setDragActive(false); launch.setDragActive(true)
    launch.layoutSubtreeIfNeeded()
    let wall = try #require(b4View("first-launch.wall", in: scene.state))
    #expect(heading.stringValue == "Release to open" && !outline.isHidden)
    #expect(abs(wall.alphaValue - 0.4) < 0.001)
    launch.reduceTransparencyOverride = true
    launch.setDragActive(false); launch.setDragActive(true)
    #expect(wall.alphaValue == 0)
    let children = try #require(scene.state.accessibilityChildren() as? [NSView])
    #expect(children.map { $0.accessibilityIdentifier() }.contains("first-launch.heading"))
    #expect(children.map { $0.accessibilityIdentifier() }.contains("state.open"))
    #expect(!children.contains { $0.accessibilityIdentifier().hasPrefix("first-launch.chip.") })
    #expect(!children.contains { $0.accessibilityIdentifier().hasPrefix("first-launch.wall") })
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4RejectedDragNeverHighlights() throws {
    _ = NSApplication.shared
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.writeObjects(["not a file" as NSString]))
    var events: [Bool] = []
    let view = ViewerDropView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
                              acceptsDrop: { true }, onDrop: { _ in Issue.record("unexpected drop") })
    view.onDragActive = { events.append($0) }
    let info = B4DragInfo(board)
    #expect(view.draggingEntered(info) == [])
    #expect(!view.performDragOperation(info))
    #expect(events == [false, false])
}


@Test(.timeLimit(.minutes(2))) @MainActor func p316B4LiveAccessibilityChangeRefreshesVisibleScreen() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    let launch = try #require(scene.state.subviews.compactMap { $0 as? FirstLaunchView }.first)
    let drop = try #require(b4View("first-launch.drop", in: scene.state))
    let wall = try #require(b4View("first-launch.wall", in: scene.state))
    scene.state.setFirstLaunchDragActive(true)
    launch.layoutSubtreeIfNeeded()
    launch.reduceMotionOverride = true
    launch.reduceTransparencyOverride = true
    // #441 removed the chip this test used as its witness. Leave a stale look the overrides alone would not repair,
    // so only the live notification can bring back Reduce Transparency's opaque drop and hidden wall.
    drop.layer?.backgroundColor = NSColor.clear.cgColor
    wall.alphaValue = 1
    NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    launch.layoutSubtreeIfNeeded()
    #expect((drop.layer?.backgroundColor?.alpha ?? 0) == 1)
    #expect(wall.alphaValue == 0)
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4PhotosDoNotInterceptFileDrags() throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    let wall = try #require(b4View("first-launch.wall", in: scene.state))
    for image in [wall] + wall.subviews {
        #expect(!(image.registeredDraggedTypes ?? []).contains(.fileURL))
        #expect(!(image.registeredDraggedTypes ?? []).contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")))
    }
    let drop = ViewerDropView(frame: scene.state.bounds, acceptsDrop: { true }, onDrop: { _ in })
    #expect((drop.registeredDraggedTypes ?? []).contains(.fileURL))
}

@Test(.timeLimit(.minutes(2))) @MainActor func p316B4AppearanceResolvesLayerColours() throws {
    let fixtureRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("B4PinnedDesign")
    let source = fixtureRoot.appendingPathComponent("a/b/c/d/source.swift").path
    let light = try PinnedDesign.page("b4-first-launch", source: source)
    let dark = try PinnedDesign.page("b4-first-launch", source: source, appearance: "dark")
    func colour(_ cg: CGColor?) throws -> PinnedDesign.Color {
        let input = try #require(cg)
        let resolved = try #require(NSColor(cgColor: input)?.usingColorSpace(.deviceRGB))
        return .init(red: resolved.redComponent, green: resolved.greenComponent,
                     blue: resolved.blueComponent, alpha: resolved.alphaComponent)
    }
    let scene = StatesScene()
    defer { scene.window.close() }
    let launch = try #require(scene.state.subviews.compactMap { $0 as? FirstLaunchView }.first)
    let drop = try #require(b4View("first-launch.drop", in: scene.state))
    launch.appearance = NSAppearance(named: .aqua)
    launch.setDragActive(true)
    try light.assertColor(colour(drop.layer?.backgroundColor), ".theme-light", "--color-accent-soft", viewport: 960)
    launch.appearance = NSAppearance(named: .darkAqua)
    launch.setDragActive(false); launch.setDragActive(true)
    try dark.assertColor(colour(drop.layer?.backgroundColor), ".theme-dark", "--color-accent-soft", viewport: 960)
    launch.reduceTransparencyOverride = true
    launch.setDragActive(false); launch.setDragActive(true)
    try dark.assertColor(colour(drop.layer?.backgroundColor), ".rt.over .drop", "background", viewport: 960)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue314OverrideRestylesFirstLaunchImmediately() throws {
    _ = NSApplication.shared
    let launch = FirstLaunchView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
        openButton: ViewerStateButton(frame: .zero))
    launch.appearance = NSAppearance(named: .aqua)
    // #441 removed the chip witness; Reduce Transparency shows on the Home only during a drag.
    let drop = try #require(b4View("first-launch.drop", in: launch))
    let wall = try #require(b4View("first-launch.wall", in: launch))
    launch.setDragActive(true)
    launch.reduceTransparencyOverride = true
    let opaque = drop.layer?.backgroundColor
    #expect(opaque?.alpha == 1)
    #expect(wall.alphaValue == 0)
    launch.reduceTransparencyOverride = false
    #expect((drop.layer?.backgroundColor?.alpha ?? 1) < 1)
    #expect(abs(wall.alphaValue - 0.4) < 0.001)
    launch.reduceTransparencyOverride = true
    #expect(drop.layer?.backgroundColor == opaque)
    #expect(wall.alphaValue == 0)
}
