import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

/// #114 fix round 1 (audits on ea21245f): the open Display panel gets first refusal of window keys and closes on a
/// click outside it, like the prototype's `viewer-options.js` outside-click handler.
@MainActor private final class Issue114Fix1Scene {
    let shell: GridShellView
    let grid: GridBrowserView
    let window: NSWindow
    init() {
        _ = NSApplication.shared
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              preferencesStore: InMemoryDisplayPreferencesStore())
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1280, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        shell.layoutSubtreeIfNeeded()
    }
    /// Detaches the views, so nothing in this window outlives the test (#316 f89a0cab).
    func close() {
        window.contentView = nil
        window.close()
    }
    func key(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    var escape: NSEvent { key(53, "\u{1b}") }
    var tab: NSEvent { key(48, "\t") }
    var backTab: NSEvent { key(48, "\t", .shift) }
    func route(_ event: NSEvent) -> Bool? { shell.routeDisplayPanelKey(event, firstResponder: window.firstResponder) }
    /// A left mouse-down at the centre of `view`, in this window or `other`'s.
    func mouseDown(on view: NSView, in other: NSWindow? = nil) -> NSEvent {
        let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        return NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                  windowNumber: (other ?? window).windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114Fix1EscapeClosesOpenPanelFromAnyFocus() throws {
    let scene = Issue114Fix1Scene()
    defer { scene.close() }
    let shell = scene.shell
    let focusTargets: [NSView] = [shell.displayPanel.sizeSlider, shell.displayPanel.fitPopup,
                                  scene.grid.collectionView, shell.sortButton, shell.displayButton]
    for target in focusTargets {
        shell.setDisplayPanelOpen(true)
        #expect(scene.window.makeFirstResponder(target), "\(target)")
        #expect(scene.route(scene.escape) == true, "Esc consumed with focus on \(target)")
        #expect(!shell.isDisplayPanelOpen, "\(target)")
        #expect(scene.window.firstResponder === shell.displayButton, "\(target)")
        #expect(shell.displayButton.state == .off)
    }
    // Closed: Esc is not the panel's, so the existing Inspector/grid rules still see it.
    #expect(scene.route(scene.escape) == nil)
    shell.setDisplayPanelOpen(true)
    #expect(scene.route(scene.key(53, "\u{1b}", .command)) == nil)
    #expect(shell.isDisplayPanelOpen)
    shell.isHidden = true
    #expect(scene.route(scene.escape) == nil)
    #expect(shell.isDisplayPanelOpen)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114Fix1TabInsidePanelFollowsPanelLoop() throws {
    let scene = Issue114Fix1Scene()
    defer { scene.close() }
    let shell = scene.shell
    let panel = shell.displayPanel
    shell.setDisplayPanelOpen(true)
    for control in [panel.closeButton, panel.sizeSlider, panel.namesCheckbox, panel.fitPopup] as [NSView] {
        #expect(scene.window.makeFirstResponder(control))
        // `false`: the window router leaves Tab to AppKit, which walks the panel's own key loop.
        #expect(scene.route(scene.tab) == false, "\(control)")
        #expect(scene.route(scene.backTab) == false, "\(control)")
        #expect(shell.isDisplayPanelOpen)
    }
    #expect(scene.window.makeFirstResponder(panel.sizeSlider))
    scene.window.selectNextKeyView(nil)
    #expect(scene.window.firstResponder === panel.namesCheckbox)
    scene.window.selectNextKeyView(nil)
    #expect(scene.window.firstResponder === panel.fitPopup)
    scene.window.selectNextKeyView(nil)
    #expect(scene.window.firstResponder === panel.closeButton)
    scene.window.selectPreviousKeyView(nil)
    #expect(scene.window.firstResponder === panel.fitPopup)
    // Focus outside the panel keeps the existing footer/Inspector Tab route.
    #expect(scene.window.makeFirstResponder(shell.sortButton))
    #expect(scene.route(scene.tab) == nil)
    #expect(scene.route(scene.key(48, "\t", .control)) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114Fix1OutsideClickClosesPanelAndClickStillLands() throws {
    let scene = Issue114Fix1Scene()
    defer { scene.close() }
    let shell = scene.shell
    let panel = shell.displayPanel
    // Inside the panel and on the Display button (which toggles by itself) the panel stays open.
    shell.setDisplayPanelOpen(true)
    for inside in [panel.sizeSlider, panel.rows[1], panel.titleLabel, shell.displayButton] as [NSView] {
        shell.dismissDisplayPanel(forMouseDown: scene.mouseDown(on: inside))
        #expect(shell.isDisplayPanelOpen, "\(inside)")
    }
    // Grid, sidebar and other footer controls close it.
    for outside in [scene.grid, shell.sidebar, shell.sortButton, shell.toggleButton] as [NSView] {
        shell.setDisplayPanelOpen(true)
        #expect(scene.window.makeFirstResponder(panel.sizeSlider))
        shell.dismissDisplayPanel(forMouseDown: scene.mouseDown(on: outside))
        #expect(!shell.isDisplayPanelOpen, "\(outside)")
        #expect(shell.displayButton.state == .off)
        // Focus does not stay in the removed panel; the click's own target may take it next.
        let responder = scene.window.firstResponder as? NSView
        #expect(responder.map { !$0.isDescendant(of: panel) } ?? true, "\(outside)")
    }
    // Focus already outside the panel is left alone for the click to move.
    shell.setDisplayPanelOpen(true)
    #expect(scene.window.makeFirstResponder(scene.grid.collectionView))
    shell.dismissDisplayPanel(forMouseDown: scene.mouseDown(on: shell.sidebar))
    #expect(!shell.isDisplayPanelOpen)
    #expect(scene.window.firstResponder === scene.grid.collectionView)
    // A click in another window, or with the panel closed, changes nothing.
    let other = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300),
                         styleMask: [.titled], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    defer { other.close() }
    shell.setDisplayPanelOpen(true)
    shell.dismissDisplayPanel(forMouseDown: scene.mouseDown(on: scene.grid, in: other))
    #expect(shell.isDisplayPanelOpen)
    shell.setDisplayPanelOpen(false)
    shell.dismissDisplayPanel(forMouseDown: scene.mouseDown(on: scene.grid))
    #expect(!shell.isDisplayPanelOpen)
}
