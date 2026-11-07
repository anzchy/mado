import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI
import MadoCore

@MainActor private final class Issue114Fix1MotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// A grid window with the Inspector visible, as in the #136 combo-2 Tab fixture.
@MainActor private struct Issue114Fix1Scene {
    let controller: CanvasWindowController
    let window: CommandWindow
    let shell: GridShellView
    let grid: GridBrowserView
    init() throws {
        _ = NSApplication.shared
        let unavailable = Task<AccessServices, Error> { throw CancellationError() }
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
            motionPolicy: MotionPolicy(source: Issue114Fix1MotionSource()))
        window = try #require(controller.window as? CommandWindow)
        shell = try #require(window.contentView?.subviews.compactMap { $0 as? GridShellView }.first)
        grid = try #require(shell.mainContent.subviews.compactMap { $0 as? GridBrowserView }.first)
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: URL(fileURLWithPath: "/tmp/issue114-fix1"))
        let item = FolderEntry(url: root.url.appendingPathComponent("cat.jpg"), root: root)
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: root.url, generation: 1),
            entries: [item], isComplete: true), selectedItemID: item.itemID)
        controller.session.beginBrowsing(items: [item.itemID], sourceVersion: .init(1), scrollAnchor: nil)
        controller.session.focus(item.itemID)
        controller.showGrid()
        #expect(controller.route(.inspector, from: .key))
        #expect(controller.session.inspectorFocus.isVisible)
        window.contentView?.layoutSubtreeIfNeeded()
    }
    func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
    func mouse(_ type: NSEvent.EventType, on view: NSView) throws -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114Fix1EscapeClosesPanelBeforeInspectorRule() throws {
    let scene = try Issue114Fix1Scene()
    defer { scene.window.close() }
    let escape = try scene.key(53, "\u{1b}")
    for focus in [scene.shell.displayPanel.sizeSlider, scene.grid.collectionView] as [NSView] {
        scene.shell.setDisplayPanelOpen(true)
        #expect(scene.window.makeFirstResponder(focus))
        scene.window.sendEvent(escape)
        #expect(!scene.shell.isDisplayPanelOpen, "first Esc closes the panel (focus \(focus))")
        #expect(scene.window.firstResponder === scene.shell.displayButton)
        #expect(scene.controller.session.inspectorFocus.isVisible, "the Inspector stays open")
    }
    // With the panel closed the next Esc reaches the existing Inspector rule: focus leaves the tools for the canvas.
    #expect(scene.window.consumeKey?(escape) == true)
    #expect(scene.controller.session.inspectorFocus.focus == .canvas)
    #expect(!scene.shell.isDisplayPanelOpen)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114Fix1TabStaysInPanelWithInspectorVisible() throws {
    let scene = try Issue114Fix1Scene()
    defer { scene.window.close() }
    let panel = scene.shell.displayPanel
    // A real Shift-Tab key-down carries the back-tab character (U+0019); AppKit's key loop reads the character.
    let tab = try scene.key(48, "\t"), backTab = try scene.key(48, "\u{19}", .shift)
    scene.shell.setDisplayPanelOpen(true)
    #expect(scene.window.firstResponder === panel.sizeSlider)
    for expected in [panel.namesCheckbox, panel.fitPopup, panel.closeButton, panel.sizeSlider] as [NSView] {
        scene.window.sendEvent(tab)
        #expect(scene.window.firstResponder === expected)
    }
    scene.window.sendEvent(backTab)
    #expect(scene.window.firstResponder === panel.closeButton)
    #expect(scene.shell.isDisplayPanelOpen)
    #expect(scene.controller.session.inspectorFocus.isVisible)
    #expect((scene.window.firstResponder as? NSView)?.accessibilityIdentifier() != "inspector.close")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue114Fix1OutsideClickClosesPanelThroughWindow() throws {
    let scene = try Issue114Fix1Scene()
    defer { scene.window.close() }
    let panel = scene.shell.displayPanel
    scene.shell.setDisplayPanelOpen(true)
    scene.window.sendEvent(try scene.mouse(.leftMouseDown, on: panel.titleLabel))
    scene.window.sendEvent(try scene.mouse(.leftMouseUp, on: panel.titleLabel))
    #expect(scene.shell.isDisplayPanelOpen, "a click inside the panel keeps it open")
    // A click on the grid closes the panel and still lands: the grid takes focus. The window router sees the
    // mouse-down (and cannot swallow it); AppKit does not hit-test clicks into this never-shown window, so the same
    // event then goes to the collection view directly, as GridMultiSelectionTests deliver grid clicks.
    scene.window.layoutIfNeeded()
    let cell = try #require(scene.grid.collectionView.item(at: IndexPath(item: 0, section: 0))?.view)
    let down = try scene.mouse(.leftMouseDown, on: cell)
    scene.window.sendEvent(down)
    scene.grid.collectionView.mouseDown(with: down)
    #expect(!scene.shell.isDisplayPanelOpen)
    #expect(scene.window.firstResponder === scene.grid.collectionView)
    #expect(scene.shell.displayButton.state == .off)
}
