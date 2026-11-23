import AppKit
import Testing
import MadoApplication
import MadoMacUI

// Issue 839 (EXT-05): a real click on the Capture helper's recognise-text notice opens the editable panel. The click
// goes through the panel's own `sendEvent` (mouse down, then up), as the window server delivers it, never by calling
// the view's `mouseDown` or `onOpen`.

private let issue839Limit = Duration.seconds(5)

@MainActor private func issue839Eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + issue839Limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor private final class Issue839Harness {
    let pasteboard = NSPasteboard(name: .init("mado.test.839.\(UUID().uuidString)"))
    var dismissals: [(TimeInterval, @MainActor () -> Void)] = []
    let presenter: CaptureRecogniseTextPresenter
    private var eventNumber = 0

    init() {
        _ = NSApplication.shared
        weak var weakSelf: Issue839Harness?
        presenter = CaptureRecogniseTextPresenter(
            recognise: { _ in TextRecognitionResult(text: "Hello 839", characterCount: 9, engine: .onDevice, isEmpty: false) },
            pasteboard: NativeTextPasteboard(pasteboard),
            scheduleDismiss: { interval, action in weakSelf?.dismissals.append((interval, action)) },
            scheduleConfirmationReset: { _ in },
            announce: { _ in })
        weakSelf = self
    }
    deinit { MainActor.assumeIsolated { presenter.dismiss(); presenter.panel.orderOut(nil); pasteboard.releaseGlobally() } }

    var panel: CaptureRecogniseTextPanel { presenter.panel }

    /// Shows the "Copied" notice at the primary display's corner.
    func showNotice() async throws -> RecogniseTextNoticeView {
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        await presenter.present(png: Data("png-839".utf8), visibleFrame: visible).value
        return try #require(presenter.overlay.noticeView)
    }

    /// One mouse event at `view`'s centre, delivered through the panel's `sendEvent`.
    func mouse(_ type: NSEvent.EventType, on view: NSView) throws {
        eventNumber += 1
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
        panel.sendEvent(event)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue839ClickOnTheNoticeThroughThePanelOpensTheEditablePanel() async throws {
    let harness = Issue839Harness()
    let notice = try await harness.showNotice()
    #expect(harness.panel.isVisible)
    #expect(!harness.panel.isKeyWindow, "the frontmost app keeps its focus while the notice shows")
    #expect(harness.dismissals.map(\.0) == [5], "the notice's 5 s dismissal is armed")
    let centre = notice.convert(NSPoint(x: notice.bounds.midX, y: notice.bounds.midY), to: nil)
    let frameView = try #require(harness.panel.contentView?.superview)
    #expect(frameView.hitTest(frameView.convert(centre, from: nil)) === notice, "the click lands on the notice")

    try harness.mouse(.leftMouseDown, on: notice)
    try harness.mouse(.leftMouseUp, on: notice)

    #expect(await issue839Eventually { harness.presenter.overlay.panelView != nil }, "a click opens the editable panel")
    let editor = try #require(harness.presenter.overlay.panelView?.textView)
    #expect(editor.string == "Hello 839")
    #expect(harness.presenter.overlay.noticeView == nil)
    #expect(harness.panel.isKeyWindow || harness.panel.firstResponder === editor, "the panel takes key for editing")
}
