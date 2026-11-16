import AppKit
import Testing
import MadoApplication

// #687 slice C, WI-3: the bar's 识别文字 button, the shortcut's routing, and the text panel kept out of every Capture.

@MainActor private func button687(_ id: String, in bar: CaptureBarView) throws -> NSButton {
    try #require(bar.subviews.first { $0.accessibilityIdentifier() == id } as? NSButton)
}

@MainActor @Test(.timeLimit(.minutes(3))) func captureBarTextButtonEnabledOnlyWithRecognizeAction() throws {
    let without = CaptureBarView(captureAction: {})
    #expect(!(try button687("capture.text", in: without)).isEnabled)
    let with = CaptureBarView(captureAction: {}, recognizeAction: {})
    let text = try button687("capture.text", in: with)
    #expect(text.isEnabled)
    #expect(text.toolTip == String(localized: "Capture and Recognize Text"))
    with.setShortcuts(["capture.text": "⌃⇧4"])
    #expect(text.toolTip == String(localized: "Capture and Recognize Text") + " ⌃⇧4")
}

@MainActor @Test(.timeLimit(.minutes(3))) func captureBarTextButtonRoutesOnlyToRecognize() throws {
    var calls: [String] = []
    let bar = CaptureBarView(captureAction: { calls.append("screen") },
                             regionAction: { calls.append("region") }, windowAction: { calls.append("window") },
                             recognizeAction: { calls.append("text") })
    for id in ["capture.region", "capture.window", "capture.screen", "capture.text"] {
        try button687(id, in: bar).performClick(nil)
    }
    #expect(calls == ["region", "window", "screen", "text"])
    try button687("capture.text", in: bar).performClick(nil)
    try button687("capture.text", in: bar).performClick(nil)
    #expect(calls == ["region", "window", "screen", "text", "text", "text"])
}

/// Law: every shortcut action maps to exactly one helper command; only 截图并识别文字 selects a region to recognise.
@MainActor @Test(.timeLimit(.minutes(3))) func captureHelperCommandMapsEveryShortcutAction() {
    let expected: [CaptureShortcutAction: CaptureHelperCommand] = [
        .region: .selectRegion(.capture), .window: .selectWindow, .fullScreen: .captureFullScreen,
        .recognizeText: .selectRegion(.recogniseText), .toggleBar: .toggleBar
    ]
    #expect(CaptureShortcutAction.allCases.count == 5)
    for action in CaptureShortcutAction.allCases {
        #expect(CaptureHelperCommand.command(for: action) == expected[action])
    }
    let recognising = CaptureShortcutAction.allCases.filter {
        CaptureHelperCommand.command(for: $0) == .selectRegion(.recogniseText)
    }
    #expect(recognising == [.recognizeText])
}

/// Law: a finished selection is captured or recognised by its purpose; a cancelled one does nothing.
@MainActor @Test(.timeLimit(.minutes(3))) func captureSelectionOutcomeRoutesPurposeAndTarget() {
    let target = CaptureRequest.Target.region(rect: CGRect(x: 0, y: 0, width: 10, height: 10), displayID: 1,
                                              displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2)
    #expect(CaptureSelectionOutcome.route(purpose: .capture, target: target) == .capture)
    #expect(CaptureSelectionOutcome.route(purpose: .recogniseText, target: target) == .recognise)
    #expect(CaptureSelectionOutcome.route(purpose: .capture, target: nil) == .none)
    #expect(CaptureSelectionOutcome.route(purpose: .recogniseText, target: nil) == .none)
}

@MainActor private func shownPresenter687() async throws -> CaptureRecogniseTextPresenter {
    let presenter = CaptureRecogniseTextPresenter(
        recognise: { _ in TextRecognitionResult(text: " ", characterCount: 1, engine: .onDevice, isEmpty: true) },
        pasteboard: NativeTextPasteboard(NSPasteboard(name: .init("mado.test.687c.windows.\(UUID().uuidString)"))),
        scheduleDismiss: { _, _ in }, announce: { _ in })
    let task = presenter.present(png: Data("png".utf8), visibleFrame: NSRect(x: 0, y: 25, width: 1440, height: 875))
    var done = false
    Task { await task.value; done = true }
    let deadline = ContinuousClock.now + .seconds(5)
    while !done, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    #expect(done)
    return presenter
}

private let target687 = CaptureRequest.Target.fullScreen(displayID: 1)

/// The text panel is kept out like the Capture Thumbnail: excluded whenever ScreenCaptureKit lists it, never required.
@MainActor @Test(.timeLimit(.minutes(3))) func captureHelperWindowsExcludeRecogniseTextPanel() async throws {
    let presenter = try await shownPresenter687()
    defer { presenter.dismiss() }
    let panel = try #require(presenter.windows.first)
    #expect(panel.isVisible)
    let id = try #require(UInt32(exactly: panel.windowNumber))
    #expect(id > 0)
    let thumbnails = CaptureThumbnailPresenter()
    let shown = CaptureHelperWindows.request(target: target687, bar: nil, status: nil, thumbnails: thumbnails,
                                             overlays: [], others: presenter.windows)
    #expect(shown.overlayWindowIDs.contains(id))
    #expect(!shown.barWindowIDs.contains(id))
    #expect(shown.excludedWindowIDs.contains(id))
    presenter.dismiss()
    #expect(!panel.isVisible)
    let hidden = CaptureHelperWindows.request(target: target687, bar: nil, status: nil, thumbnails: thumbnails,
                                              overlays: [], others: presenter.windows)
    #expect(hidden.overlayWindowIDs.contains(id))
    #expect(!hidden.barWindowIDs.contains(id))
    let resolved = CaptureHelperWindows.resolver(target: target687, bar: nil, status: nil, thumbnails: thumbnails,
                                                 overlays: [], others: { presenter.windows })()
    #expect(resolved.overlayWindowIDs == hidden.overlayWindowIDs)
    #expect(resolved.barWindowIDs == hidden.barWindowIDs)
}

/// The resolver reads `others` when the read runs, so a panel created after the selection began is still left out.
@MainActor @Test(.timeLimit(.minutes(3))) func captureHelperWindowsResolverSeesPanelCreatedLater() async throws {
    var presenter: CaptureRecogniseTextPresenter?
    let resolver = CaptureHelperWindows.resolver(target: target687, bar: nil, status: nil,
                                                 thumbnails: CaptureThumbnailPresenter(), overlays: [],
                                                 others: { presenter?.windows ?? [] })
    #expect(resolver().overlayWindowIDs.isEmpty)
    let created = try await shownPresenter687()
    defer { created.dismiss() }
    presenter = created
    let id = try #require(created.windows.first.flatMap { UInt32(exactly: $0.windowNumber) })
    #expect(resolver().excludedWindowIDs.contains(id))
}

/// Law: without `others` a request is exactly today's; with them it only ever excludes more.
@MainActor @Test(.timeLimit(.minutes(3))) func captureHelperWindowsDefaultOthersUnchanged() async throws {
    let bar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless],
                      backing: .buffered, defer: false)
    defer { bar.orderOut(nil) }
    let thumbnails = CaptureThumbnailPresenter()
    let presenter = try await shownPresenter687()
    defer { presenter.dismiss() }
    let targets: [CaptureRequest.Target] = [
        .fullScreen(displayID: 1), .window(windowID: 7),
        .region(rect: CGRect(x: 1, y: 1, width: 5, height: 5), displayID: 1,
                displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 1)
    ]
    for target in targets {
        for barVisible in [true, false] {
            if barVisible { bar.orderFrontRegardless() } else { bar.orderOut(nil) }
            let plain = CaptureHelperWindows.request(target: target, bar: bar, status: nil, thumbnails: thumbnails,
                                                     overlays: [])
            let empty = CaptureHelperWindows.request(target: target, bar: bar, status: nil, thumbnails: thumbnails,
                                                     overlays: [], others: [])
            let today = CaptureRequestFromWindows.make(target: target, bars: [bar], thumbnails: thumbnails.windows,
                                                       overlays: [])
            #expect(plain.barWindowIDs == today.barWindowIDs && plain.overlayWindowIDs == today.overlayWindowIDs)
            #expect(empty.barWindowIDs == today.barWindowIDs && empty.overlayWindowIDs == today.overlayWindowIDs)
            let with = CaptureHelperWindows.request(target: target, bar: bar, status: nil, thumbnails: thumbnails,
                                                    overlays: [], others: presenter.windows)
            #expect(with.excludedWindowIDs.isSuperset(of: plain.excludedWindowIDs))
            #expect(with.barWindowIDs == plain.barWindowIDs)
        }
    }
}
