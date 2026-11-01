import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

/// Makes `event` the application's current event, as AppKit does while it dispatches a real key press.
@MainActor private func issue362Dispatching(_ event: NSEvent, _ body: () -> Void) {
    NSApp.postEvent(event, atStart: true)
    _ = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)
    #expect(NSApp.currentEvent?.type == .keyDown)
    #expect(NSApp.currentEvent?.keyCode == event.keyCode)
    body()
}

/// Later tests must not see a stale key press as the current event.
@MainActor private func issue362ClearCurrentEvent() {
    guard let idle = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) else { return }
    NSApp.postEvent(idle, atStart: true)
    _ = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true)
}

@MainActor private func issue362Key(_ window: NSWindow, keyCode: UInt16, characters: String,
                                    modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: characters,
        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
}

@MainActor private func issue362Descendants(_ view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(issue362Descendants)
}

@MainActor private func issue362MenuItem(_ id: CommandID, in menu: NSMenu?) -> NSMenuItem? {
    for item in menu?.items ?? [] {
        if item.representedObject as? String == id.rawValue { return item }
        if let found = issue362MenuItem(id, in: item.submenu) { return found }
    }
    return nil
}

/// Opens three files as a File Preview Set and Tabs into the stage, so the ring is showing.
@MainActor private func issue362TabbedIntoStage(_ scene: Issue150Scene) async throws -> CanvasView {
    scene.controller.openInput(scene.files)
    try await scene.waitUntil { scene.controller.session.filePreviewSet != nil }
    let window = scene.window
    let canvas = try #require(issue362Descendants(window.contentView).compactMap { $0 as? CanvasView }.first)
    _ = window.makeFirstResponder(nil)
    issue362Dispatching(try issue362Key(window, keyCode: 48, characters: "\t")) {
        _ = window.makeFirstResponder(canvas)
    }
    #expect(window.firstResponder === canvas)
    #expect(canvas.isShowingKeyboardFocusRing, "Tab into the stage shows the ring")
    return canvas
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue362MenuArrowKeysKeepRingAfterTabIn() async throws {
    let scene = try await Issue150Scene()
    let previousMenu = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(), openWithoutWindow: {},
        openSettings: {}, openDiagnostics: {}, windowController: { scene.controller })
    defer {
        issue362ClearCurrentEvent()
        NSApp.mainMenu = previousMenu
        withExtendedLifetime(menu) {}
        scene.close()
    }
    let canvas = try await issue362TabbedIntoStage(scene)
    let window = scene.window

    // Bare ←/→ are main-menu key equivalents: AppKit invokes the menu item while the arrow is current.
    for (id, keyCode, characters, index) in [(CommandID.next, UInt16(124), "\u{F703}", 1),
                                             (CommandID.previous, UInt16(123), "\u{F702}", 0)] {
        let item = try #require(issue362MenuItem(id, in: NSApp.mainMenu))
        let parent = try #require(item.menu)
        #expect(item.keyEquivalent == id.defaultKey)
        issue362Dispatching(try issue362Key(window, keyCode: keyCode, characters: characters)) {
            parent.performActionForItem(at: parent.index(of: item))
        }
        #expect(scene.controller.session.filePreviewSet?.index == index, "\(id) opened the adjacent file")
        #expect(window.firstResponder === canvas)
        #expect(canvas.isShowingKeyboardFocusRing, "\(id) from the menu keeps the ring")
    }

    // A toolbar or programmatic opening afterwards still hides it.
    issue362ClearCurrentEvent()
    scene.controller.open(scene.files[2])
    #expect(!canvas.isShowingKeyboardFocusRing, "a non-keyboard opening hides the ring")
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue362NoOpArrowLeavesNoRingForLaterOpening() async throws {
    let scene = try await Issue150Scene()
    defer { issue362ClearCurrentEvent(); scene.close() }
    let canvas = try await issue362TabbedIntoStage(scene)
    let window = scene.window

    // The first file has no previous one: the route opens nothing.
    issue362Dispatching(try issue362Key(window, keyCode: 123, characters: "\u{F702}")) {
        _ = scene.controller.route(.previous, from: .key)
    }
    #expect(scene.controller.session.filePreviewSet?.index == 0)
    #expect(canvas.isShowingKeyboardFocusRing)

    issue362ClearCurrentEvent()
    scene.controller.open(scene.files[2])
    #expect(!canvas.isShowingKeyboardFocusRing, "a programmatic opening after a no-op arrow hides the ring")
}

/// Shows the Inspector and puts keyboard focus on its close button.
@MainActor private func issue362FocusInspectorClose(_ scene: Issue150Scene) throws -> NSView {
    scene.controller.session.setInspectorVisible(true)
    scene.window.contentView?.layoutSubtreeIfNeeded()
    let close = try #require(issue362Descendants(scene.window.contentView)
        .first { $0.accessibilityIdentifier() == "inspector.close" })
    #expect(scene.window.makeFirstResponder(close))
    #expect(scene.controller.session.inspectorFocus.focus == .panel)
    return close
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue362CommandIClosingInspectorShowsRing() async throws {
    let scene = try await Issue150Scene()
    defer { issue362ClearCurrentEvent(); scene.close() }
    let canvas = try await issue362TabbedIntoStage(scene)
    let window = scene.window
    _ = try issue362FocusInspectorClose(scene)
    #expect(!canvas.isShowingKeyboardFocusRing)

    let commandI = try issue362Key(window, keyCode: 34, characters: "i", modifiers: .command)
    issue362Dispatching(commandI) { window.sendEvent(commandI) }
    #expect(!scene.controller.session.inspectorFocus.isVisible)
    #expect(window.firstResponder === canvas)
    #expect(canvas.isShowingKeyboardFocusRing, "⌘I moves keyboard focus to the stage with the ring")
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue362EscapeClosingInspectorShowsRingThroughController() async throws {
    let scene = try await Issue150Scene()
    defer { issue362ClearCurrentEvent(); scene.close() }
    let canvas = try await issue362TabbedIntoStage(scene)
    let window = scene.window
    _ = try issue362FocusInspectorClose(scene)

    // The window's own key path: CommandWindow.consumeKey → Inspector Esc policy → route → applyFocus.
    let escape = try issue362Key(window, keyCode: 53, characters: "\u{1b}")
    issue362Dispatching(escape) { window.sendEvent(escape) }
    #expect(window.firstResponder === canvas)
    #expect(canvas.isShowingKeyboardFocusRing, "Esc from the Inspector moves keyboard focus to the stage with the ring")
}
