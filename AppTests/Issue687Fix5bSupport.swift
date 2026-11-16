import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoMacUI

/// #687 fix r5b (owner decisions, amendment 3): a hosted viewer window with the recognition stubbed, the notice's
/// dismissal clock captured, and VoiceOver announcements recorded. Shared by the placement (F8) and focus-hold (F9)
/// tests, which live in their own files so each RED receipt fingerprints only its own test.
@MainActor final class Fix5bHarness {
    let context: Issue690Context
    let controller: CanvasWindowController
    let window: NSWindow
    var pendingDismissals: [@MainActor () -> Void] = []
    var announcements: [String] = []
    var text = "Hello"

    init() async throws {
        context = try await Issue690Context()
        controller = try await context.open()
        window = try #require(controller.window)
        controller.recogniseTextAdapter.pasteboard = context.pasteboard
        controller.recogniseTextAdapter.recognise = { [weak self] _, _ in
            let text = await MainActor.run { self?.text ?? "" }
            return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: text.isEmpty)
        }
        controller.recogniseTextAdapter.scheduleNoticeDismiss = { [weak self] _, action in self?.pendingDismissals.append(action) }
        controller.recogniseTextAdapter.announce = { [weak self] message in self?.announcements.append(message) }
    }
    func close() { context.close() }

    var overlay: RecogniseTextOverlay? { window.contentView?.subviews.compactMap { $0 as? RecogniseTextOverlay }.first }
    var chrome: ViewerChromeOverlay { controller.chromeOverlay }

    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
    private var eventNumber = 0
    /// A primary click at `point` (window coordinates), delivered to `view` as AppKit delivers to the hit view.
    func press(_ view: NSView, at point: NSPoint) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            eventNumber += 1
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }
    func reset(inspector visible: Bool) async throws {
        controller.recogniseTextAdapter.leaveForAnnotate()
        pendingDismissals.removeAll()
        controller.session.setInspectorVisible(visible)
        controller.showInspector(visible)
        controller.session.updateFocus(.canvas)
        _ = window.makeFirstResponder(controller.canvas)
    }
    /// View › 识别文字 through menu validation.
    func recognise() async throws {
        #expect(try context.enabled("viewer.recognise-text.menu"), "识别文字 is available")
        try context.perform("viewer.recognise-text.menu")
        try await waitUntil("recognition finished") { self.controller.recogniseTextAdapter.model?.isRunning == false }
        overlay?.layoutSubtreeIfNeeded()
    }
    func fireDismissals() {
        let actions = pendingDismissals
        pendingDismissals.removeAll()
        for action in actions { action() }
    }
    /// A view's frame in window coordinates.
    func windowFrame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
    /// The viewer's chrome pods (zoom, navigation, sidebar), in window coordinates.
    var podFrames: [NSRect] { chrome.groups.map(windowFrame) }
    var zoomPod: NSView { chrome.groups[2] }
}

extension Fix5bHarness {
    /// The Inspector column, in window coordinates (its close button's host).
    var inspectorClose: NSView? {
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == "inspector.close" { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return window.contentView.flatMap(find)
    }
    var inspectorColumn: NSRect? {
        guard controller.inspectorVisible, var view = inspectorClose else { return nil }
        while let parent = view.superview, parent !== window.contentView { view = parent }
        return view.isHiddenOrHasHiddenAncestor ? nil : windowFrame(view)
    }
    /// Opens the panel with Space on the focused notice.
    func openPanel() throws -> RecogniseTextPanelView {
        let notice = try #require(overlay?.noticeView)
        _ = window.makeFirstResponder(notice)
        try key(" ", code: 49)
        overlay?.layoutSubtreeIfNeeded()
        return try #require(overlay?.panelView)
    }
}
