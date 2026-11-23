import AppKit
import Testing
import MadoApplication
import MadoMacUI

// Issue 839 fix1: the notice's first-responder exception lasts exactly as long as a left mouse-down is in delivery.
// A nested left mouse-down (a tracking loop calling sendEvent) must not close it for the outer delivery; after a
// click it is closed again; and a warning notice's click opens nothing. Events go through the panel's sendEvent.

private let issue839f1Limit = Duration.seconds(5)

@MainActor private func issue839f1Eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + issue839f1Limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor private final class Issue839f1Harness {
    let pasteboard = NSPasteboard(name: .init("mado.test.839f1.\(UUID().uuidString)"))
    let presenter: CaptureRecogniseTextPresenter
    private var eventNumber = 0

    init(text: String = "Hello 839") {
        _ = NSApplication.shared
        presenter = CaptureRecogniseTextPresenter(
            recognise: { _ in TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice,
                                                    isEmpty: text.isEmpty) },
            pasteboard: NativeTextPasteboard(pasteboard),
            scheduleDismiss: { _, _ in },
            scheduleConfirmationReset: { _ in },
            announce: { _ in })
    }
    deinit { MainActor.assumeIsolated { presenter.dismiss(); presenter.panel.orderOut(nil); pasteboard.releaseGlobally() } }

    var panel: CaptureRecogniseTextPanel { presenter.panel }

    func showNotice() async throws -> RecogniseTextNoticeView {
        let visible = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        await presenter.present(png: Data("png-839f1-\(UUID().uuidString)".utf8), visibleFrame: visible).value
        return try #require(presenter.overlay.noticeView)
    }

    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
        eventNumber += 1
        return try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
    }

    func click(_ view: NSView) throws {
        let centre = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        panel.sendEvent(try event(.leftMouseDown, at: centre))
        panel.sendEvent(try event(.leftMouseUp, at: centre))
    }
}

/// A view whose mouse-down delivers a nested left mouse-down through the same panel (as a tracking loop would), then,
/// still inside the outer delivery, asks the panel to focus the notice.
@MainActor private final class Issue839f1NestingView: NSView {
    var nested: (() throws -> Void)?
    var afterNested: (() -> Void)?
    private var depth = 0
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        depth += 1
        defer { depth -= 1 }
        guard depth == 1 else { return }
        try? nested?()
        afterNested?()
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue839f1NestedMouseDownKeepsTheOuterDeliveryException() async throws {
    let harness = Issue839f1Harness()
    let notice = try await harness.showNotice()
    let nesting = Issue839f1NestingView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    harness.presenter.overlay.addSubview(nesting)
    defer { nesting.removeFromSuperview() }
    let point = nesting.convert(NSPoint(x: 5, y: 5), to: nil)
    var focusedInOuterDelivery: Bool?
    nesting.nested = { harness.panel.sendEvent(try harness.event(.leftMouseDown, at: point)) }
    nesting.afterNested = { focusedInOuterDelivery = harness.panel.makeFirstResponder(notice) }

    harness.panel.sendEvent(try harness.event(.leftMouseDown, at: point))
    harness.panel.sendEvent(try harness.event(.leftMouseUp, at: point))

    #expect(focusedInOuterDelivery == true, "the outer left mouse-down is still in delivery after the nested one")
    #expect(harness.panel.makeFirstResponder(notice) == false, "outside any mouse-down the notice refuses focus again")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue839f1ExceptionClosesAfterAClick() async throws {
    let harness = Issue839f1Harness()
    let first = try await harness.showNotice()
    #expect(harness.panel.makeFirstResponder(first) == false, "a new notice refuses focus")
    try harness.click(first)
    #expect(await issue839f1Eventually { harness.presenter.overlay.panelView != nil }, "the click opens the panel")

    harness.presenter.dismiss()
    let fresh = try await harness.showNotice()
    #expect(fresh !== first)
    #expect(harness.panel.makeFirstResponder(fresh) == false, "after a click the exception is closed again")
    #expect(harness.panel.firstResponder !== fresh)
    #expect(!harness.panel.isKeyWindow, "the frontmost app keeps its focus while the fresh notice shows")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue839f1ClickOnAWarningNoticeOpensNothing() async throws {
    let harness = Issue839f1Harness(text: "")
    let notice = try await harness.showNotice()
    #expect(notice.kind == .warning)
    try harness.click(notice)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(harness.presenter.overlay.panelView == nil, "a warning notice has no panel to open")
    #expect(harness.presenter.overlay.noticeView === notice)
    #expect(harness.panel.firstResponder !== notice)
}
