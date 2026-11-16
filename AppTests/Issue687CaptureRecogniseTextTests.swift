import AppKit
import Testing
import MadoApplication
import MadoMacUI

// #687 slice C, WI-2: the Capture helper shows #687b's notice and panel at the screen corner after 截图并识别文字.
// Page 38 `capture-thumbnail.html` (bedd1ad6, SHA256 b2ae92f8…bcbdc8): `.corner` / `.panel` right 20, bottom 20.
// Every wait here ends within `capture687Limit`: a stub that never answers fails, it never hangs.

private let capture687Limit = Duration.seconds(5)
private struct Capture687Timeout: Error {}

/// Recognition results the test hands out per PNG; a PNG nobody answers fails after `capture687Limit`.
private actor Capture687Gate {
    private var answers: [Data: Result<String, TextRecognitionError>] = [:]
    private(set) var asked: [Data] = []
    func answer(_ png: Data, _ result: Result<String, TextRecognitionError>) { answers[png] = result }
    func next(_ png: Data) async throws -> String {
        asked.append(png)
        let deadline = ContinuousClock.now + capture687Limit
        while answers[png] == nil {
            guard ContinuousClock.now < deadline else { throw Capture687Timeout() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return try answers[png]!.get()
    }
    var askedCount: Int { asked.count }
}

private func capture687Recognise(_ gate: Capture687Gate) -> CaptureRecogniseTextPresenter.Recognise {
    { png in
        let text = try await gate.next(png)
        return TextRecognitionResult(text: text, characterCount: text.count, engine: .onDevice, isEmpty: text.isEmpty)
    }
}

/// Waits for `condition`, at most `capture687Limit`.
@MainActor private func capture687Eventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + capture687Limit
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A run's task, awaited at most `capture687Limit`.
@MainActor private func capture687Finish(_ task: Task<Void, Never>) async -> Bool {
    var done = false
    Task { await task.value; done = true }
    return await capture687Eventually { done }
}

@MainActor private final class Capture687Harness {
    let gate = Capture687Gate()
    let pasteboard = NSPasteboard(name: .init("mado.test.687c.\(UUID().uuidString)"))
    var dismissals: [(TimeInterval, @MainActor () -> Void)] = []
    var resets: [@MainActor () -> Void] = []
    var announcements: [String] = []
    let presenter: CaptureRecogniseTextPresenter

    init(strings: CaptureRecogniseTextStrings = .localized, recognise: CaptureRecogniseTextPresenter.Recognise? = nil) {
        _ = NSApplication.shared
        weak var weakSelf: Capture687Harness?
        let gate = self.gate
        presenter = CaptureRecogniseTextPresenter(
            recognise: recognise ?? capture687Recognise(gate),
            pasteboard: NativeTextPasteboard(pasteboard),
            strings: strings,
            scheduleDismiss: { interval, action in weakSelf?.dismissals.append((interval, action)) },
            scheduleConfirmationReset: { action in weakSelf?.resets.append(action) },
            announce: { weakSelf?.announcements.append($0) })
        weakSelf = self
    }
    deinit { MainActor.assumeIsolated { presenter.dismiss(); presenter.panel.orderOut(nil); pasteboard.releaseGlobally() } }

    var panel: CaptureRecogniseTextPanel { presenter.panel }
    var notice: RecogniseTextNoticeView? { presenter.overlay.noticeView }
    var textPanel: RecogniseTextPanelView? { presenter.overlay.panelView }

    func seed(_ string: String = "before") {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(string, forType: .string)
        item.setData(Data([1, 2, 3]), forType: .init("io.github.anzchy.mado.test.custom"))
        pasteboard.writeObjects([item])
    }
    /// Every item's types and bytes.
    var snapshot: [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type.rawValue, $0) } })
        }
    }
    /// `surface`'s frame on screen.
    func screenFrame(_ surface: NSView) -> NSRect {
        panel.convertToScreen(surface.convert(surface.bounds, to: nil))
    }
    func click(_ view: NSView) throws {
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
    }
    /// Presents `png`, answers it with `text`, and waits for the run to end.
    @discardableResult func run(_ png: Data, text: String, frame: NSRect = primaryVisible) async throws -> Bool {
        let task = presenter.present(png: png, visibleFrame: frame)
        await gate.answer(png, .success(text))
        return await capture687Finish(task)
    }
}

private let primaryVisible = NSRect(x: 0, y: 25, width: 1440, height: 875)
private let secondaryVisible = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
private func png(_ name: String) -> Data { Data("png-\(name)".utf8) }

/// zh-Hans values from the source catalogue (the App test bundle carries none).
private func capture687Chinese(_ key: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let item = try #require((json["strings"] as? [String: Any])?[key] as? [String: Any])
    let zh = try #require((item["localizations"] as? [String: Any])?["zh-Hans"] as? [String: Any])
    return try #require((zh["stringUnit"] as? [String: Any])?["value"] as? String)
}

private func capture687ChineseStrings() throws -> CaptureRecogniseTextStrings {
    let copied = try capture687Chinese("Copied %lld characters")
    let noText = try capture687Chinese("No text found · Clipboard unchanged")
    let failed = try capture687Chinese("Unable to recognise text")
    let mayHaveChanged = try capture687Chinese("Couldn't copy the text · The clipboard may have changed")
    let onDevice = try capture687Chinese("On-device Recognition")
    return CaptureRecogniseTextStrings(
        copied: { copied.replacingOccurrences(of: "%lld", with: String($0)) }, noText: noText, failed: failed,
        clipboardMayHaveChanged: mayHaveChanged, engine: { _ in onDevice })
}

// MARK: Layout

@MainActor @Test(.timeLimit(.minutes(3))) func captureRecogniseLayoutPrimaryDisplay() {
    #expect(CaptureRecogniseTextLayout.windowFrame(surface: NSSize(width: 220, height: 34), visibleFrame: primaryVisible)
        == NSRect(x: 1180, y: 25, width: 260, height: 74))
}

@MainActor @Test(.timeLimit(.minutes(3))) func captureRecogniseLayoutSecondaryDisplayNegativeOrigin() {
    let frame = CaptureRecogniseTextLayout.windowFrame(surface: NSSize(width: 380, height: 242), visibleFrame: secondaryVisible)
    #expect(frame == NSRect(x: -420, y: 0, width: 420, height: 282))
    #expect(frame.maxX == secondaryVisible.maxX)
}

/// Law: the window's trailing and bottom edges are the visible frame's, 20 pt of room on every side of the surface.
@MainActor @Test(.timeLimit(.minutes(3))) func captureRecogniseLayoutHoldsCornerInvariant() {
    var state: UInt64 = 687
    func next(_ range: ClosedRange<Double>) -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(range.lowerBound + Double(state >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)).rounded()
    }
    for index in 0..<200 {
        let visible = NSRect(x: next(-4000...4000), y: next(-4000...4000), width: next(200...6000), height: next(200...6000))
        let surface = index == 0 ? NSSize.zero : NSSize(width: next(0...380), height: next(0...300))
        let frame = CaptureRecogniseTextLayout.windowFrame(surface: surface, visibleFrame: visible)
        #expect(frame.maxX == visible.maxX)
        #expect(frame.minY == visible.minY)
        #expect(frame.width == surface.width + 40)
        #expect(frame.height == surface.height + 40)
        #expect(frame.contains(NSRect(x: visible.maxX - 20 - surface.width, y: visible.minY + 20,
                                      width: surface.width, height: surface.height)))
    }
}

// MARK: Pinned design (page 38)

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignCaptureRecogniseNoticeAtScreenCorner() async throws {
    let strings = try capture687ChineseStrings()
    let harness = Capture687Harness(strings: strings)
    let text = "会议纪要 abc"
    #expect(try await harness.run(png("a"), text: text))
    let notice = try #require(harness.notice)
    let onScreen = harness.screenFrame(notice)
    #expect(onScreen.maxX == primaryVisible.maxX - 20)
    #expect(onScreen.minY == primaryVisible.minY + 20)
    #expect(notice.frame.height == 34)
    #expect(notice.layer?.cornerRadius == 17)
    #expect(notice.iconView.frame.width == 16)
    #expect(notice.messageLabel.stringValue == "已拷贝 \(text.count) 个字符")
    #expect(notice.engineTag.stringValue == "本机识别")
    #expect(!notice.engineTag.isHidden)
    #expect(notice.engineTag.frame.height == 18)
    #expect(notice.engineTag.frame.minX - notice.messageLabel.frame.maxX == 8)
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignCaptureRecognisePanelAtScreenCorner() async throws {
    let harness = Capture687Harness(strings: try capture687ChineseStrings())
    #expect(try await harness.run(png("b"), text: "会议纪要\nline 2", frame: secondaryVisible))
    try harness.click(try #require(harness.notice))
    #expect(harness.notice == nil)
    let panel = try #require(harness.textPanel)
    #expect(panel.frame.width == 380)
    #expect(panel.scrollView.frame.height == 150)
    #expect(panel.titleLabel.stringValue == String(localized: "Recognised Text"))
    #expect(try capture687Chinese("Recognised Text") == "识别出的文字")
    #expect(panel.engineTag.stringValue == "本机识别")
    #expect(panel.closeButton.accessibilityIdentifier() == "recognise-text.close")
    #expect(panel.closeButton.frame.size == CGSize(width: 26, height: 26))
    #expect(panel.copyButton.frame.height == 26)
    #expect(try capture687Chinese("Copy") == "拷贝")
    let onScreen = harness.screenFrame(panel)
    #expect(onScreen.maxX == secondaryVisible.maxX - 20)
    #expect(onScreen.minY == secondaryVisible.minY + 20)
    #expect(harness.panel.frame.width == 420)
    #expect(harness.panel.canBecomeKey)
    #expect((harness.panel.firstResponder as? NSView)?.accessibilityIdentifier() == "recognise-text.editor")
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignCaptureRecogniseNoTextHasNoEngineAndDoesNotOpen() async throws {
    let harness = Capture687Harness(strings: try capture687ChineseStrings())
    #expect(try await harness.run(png("c"), text: " \n\t "))
    let notice = try #require(harness.notice)
    #expect(notice.messageLabel.stringValue == "未找到文字 · 剪贴板没有改变")
    #expect(notice.iconView.contentTintColor == DesignColor.textSecondary.nsColor)
    #expect(notice.engineTag.isHidden)
    #expect(notice.onOpen == nil)
    #expect(notice.frame.height == 34)
    try harness.click(notice)
    #expect(harness.textPanel == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignCaptureRecogniseEngineTagBothAppearances() async throws {
    var seen: [NSAppearance.Name: CGColor] = [:]
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        let harness = Capture687Harness()
        harness.panel.appearance = appearance
        #expect(try await harness.run(png("d-\(name.rawValue)"), text: "abc"))
        let notice = try #require(harness.notice)
        var hover: CGColor?
        var ink: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            hover = DesignColor.hoverBackground.nsColor.cgColor
            ink = DesignColor.textPrimary.nsColor.usingColorSpace(.sRGB)
        }
        #expect(notice.engineTag.layer?.backgroundColor == hover)
        var label: NSColor?
        appearance.performAsCurrentDrawingAppearance { label = notice.messageLabel.textColor?.usingColorSpace(.sRGB) }
        #expect(label == ink)
        seen[name] = notice.engineTag.layer?.backgroundColor
    }
    #expect(seen[.aqua] != seen[.darkAqua])
}

// MARK: Clipboard

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterCopiesPlainTextOnly() async throws {
    let harness = Capture687Harness()
    harness.seed()
    let text = "Hello 世界\nline 2"
    #expect(try await harness.run(png("e"), text: text))
    // Plain text only: AppKit lists the legacy `NSStringPboardType` alias beside `.string`; never `.png`.
    #expect(harness.pasteboard.types?.allSatisfy { [.string, .init("NSStringPboardType")].contains($0) } == true)
    #expect(harness.pasteboard.types?.contains(.png) == false)
    #expect(harness.pasteboard.string(forType: .string) == text)
    let notice = try #require(harness.notice)
    #expect(notice.messageLabel.stringValue == String(localized: "Copied \(Int64(text.count)) characters"))
    #expect(notice.engineTag.stringValue == String(localized: "On-device Recognition"))
    #expect(!notice.engineTag.isHidden)
}

/// Law: no text leaves every item, type and byte on the clipboard as it was.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterNoTextLeavesClipboardByteIdentical() async throws {
    let harness = Capture687Harness()
    harness.seed()
    let before = harness.snapshot
    let changes = harness.pasteboard.changeCount
    #expect(try await harness.run(png("f"), text: " \n\t "))
    #expect(harness.snapshot == before)
    #expect(harness.pasteboard.changeCount == changes)
    let notice = try #require(harness.notice)
    #expect(notice.messageLabel.stringValue == String(localized: "No text found · Clipboard unchanged"))
    #expect(notice.engineTag.isHidden)
    #expect(notice.onOpen == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterVisionFailureLeavesClipboard() async throws {
    let harness = Capture687Harness()
    harness.seed()
    let before = harness.snapshot
    let changes = harness.pasteboard.changeCount
    let task = harness.presenter.present(png: png("g"), visibleFrame: primaryVisible)
    await harness.gate.answer(png("g"), .failure(.recognitionFailed(domain: "test", code: 1)))
    #expect(await capture687Finish(task))
    #expect(harness.snapshot == before)
    #expect(harness.pasteboard.changeCount == changes)
    let notice = try #require(harness.notice)
    #expect(notice.messageLabel.stringValue == String(localized: "Unable to recognise text"))
    #expect(notice.engineTag.isHidden)
}

/// Law: whichever run answers first, only the newest present's text reaches the clipboard and the notice.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterStaleRunNeverCopies() async throws {
    var finals: [Data] = []
    for newestFirst in [true, false] {
        let harness = Capture687Harness()
        harness.seed()
        let first = harness.presenter.present(png: png("alpha"), visibleFrame: primaryVisible)
        let second = harness.presenter.present(png: png("bravo"), visibleFrame: primaryVisible)
        if newestFirst {
            await harness.gate.answer(png("bravo"), .success("bravo"))
            #expect(await capture687Finish(second))
            let afterNewest = harness.pasteboard.changeCount
            await harness.gate.answer(png("alpha"), .success("alpha"))
            #expect(await capture687Finish(first))
            #expect(harness.pasteboard.changeCount == afterNewest)
        } else {
            await harness.gate.answer(png("alpha"), .success("alpha"))
            #expect(await capture687Finish(first))
            await harness.gate.answer(png("bravo"), .success("bravo"))
            #expect(await capture687Finish(second))
        }
        #expect(harness.pasteboard.string(forType: .string) == "bravo")
        #expect(harness.notice?.messageLabel.stringValue == String(localized: "Copied \(Int64(5)) characters"))
        #expect(harness.presenter.windows.count == 1)
        finals.append(harness.pasteboard.data(forType: .string) ?? Data())
    }
    #expect(finals.count == 2 && finals[0] == finals[1])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterDismissWhilePendingNeverCopiesOrShows() async throws {
    let harness = Capture687Harness()
    harness.seed()
    let changes = harness.pasteboard.changeCount
    let task = harness.presenter.present(png: png("h"), visibleFrame: primaryVisible)
    harness.presenter.dismiss()
    await harness.gate.answer(png("h"), .success("alpha"))
    #expect(await capture687Finish(task))
    #expect(harness.pasteboard.string(forType: .string) == "before")
    #expect(harness.pasteboard.changeCount == changes)
    #expect(!harness.panel.isVisible)
    #expect(harness.notice == nil)
    #expect(harness.announcements.isEmpty)
}

// MARK: Panel

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterPanelIsKeyWithEditorFirstResponder() async throws {
    let harness = Capture687Harness()
    let text = "editable 文字"
    #expect(try await harness.run(png("i"), text: text))
    #expect(!harness.panel.canBecomeKey)
    try harness.click(try #require(harness.notice))
    let panel = try #require(harness.textPanel)
    #expect(harness.panel.canBecomeKey)
    #expect(!harness.panel.canBecomeMain)
    #expect(!harness.panel.isMainWindow)
    #expect(harness.panel.firstResponder === panel.textView)
    #expect(panel.textView.string == text)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterPanelCopiesEditedText() async throws {
    let harness = Capture687Harness()
    #expect(try await harness.run(png("j"), text: "original"))
    try harness.click(try #require(harness.notice))
    let panel = try #require(harness.textPanel)
    panel.textView.string = "edited 改"
    panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
    panel.copyButton.performClick(nil)
    #expect(harness.pasteboard.string(forType: .string) == "edited 改")
    // Plain text only: AppKit lists the legacy `NSStringPboardType` alias beside `.string`; never `.png`.
    #expect(harness.pasteboard.types?.allSatisfy { [.string, .init("NSStringPboardType")].contains($0) } == true)
    #expect(harness.pasteboard.types?.contains(.png) == false)
    #expect(panel.footerLabel.stringValue == String(localized: "Copied"))
    #expect(harness.panel.isVisible)
    #expect(harness.panel.canBecomeKey)
    #expect(harness.resets.count == 1)
    harness.resets.first?()
    #expect(panel.footerLabel.stringValue == String(localized: "You can edit before copying again"))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterEscAndCloseOrderOut() async throws {
    for useEscape in [false, true] {
        let harness = Capture687Harness()
        #expect(try await harness.run(png("k"), text: "kept"))
        try harness.click(try #require(harness.notice))
        let panel = try #require(harness.textPanel)
        if useEscape { panel.textView.cancelOperation(nil) } else { panel.closeButton.performClick(nil) }
        #expect(!harness.panel.isVisible)
        #expect(!harness.panel.canBecomeKey)
        #expect(harness.textPanel == nil)
        #expect(harness.pasteboard.string(forType: .string) == "kept")
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterNoticeDismissalOrdersOut() async throws {
    let harness = Capture687Harness()
    #expect(try await harness.run(png("l"), text: "abc"))
    #expect(harness.panel.isVisible)
    #expect(harness.dismissals.map(\.0) == [5])
    harness.dismissals.first?.1()
    #expect(harness.notice == nil)
    #expect(!harness.panel.isVisible)
}

/// The helper panel is never key while the notice shows, so the notice never holds keyboard focus there: a focus hold
/// would keep the 5 s dismissal from ever running.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureNoticeNeverTakesKeyboardFocusInHelper() async throws {
    let harness = Capture687Harness()
    for index in 0..<2 {
        #expect(try await harness.run(png("w\(index)"), text: "abc"))
        let notice = try #require(harness.notice)
        #expect(harness.panel.firstResponder !== notice)
        #expect(!harness.panel.makeFirstResponder(notice))
        #expect(harness.panel.firstResponder !== notice)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterPendingNoticeDismissalSparesPanel() async throws {
    let harness = Capture687Harness()
    #expect(try await harness.run(png("m"), text: "abc"))
    try harness.click(try #require(harness.notice))
    let panel = try #require(harness.textPanel)
    let scheduled = harness.dismissals.count
    for (_, action) in harness.dismissals { action() }
    #expect(harness.textPanel === panel)
    #expect(harness.panel.isVisible)
    #expect(harness.panel.canBecomeKey)
    #expect(harness.panel.firstResponder === panel.textView)
    #expect(harness.dismissals.count == scheduled)
}

/// Law: the window is visible exactly while a surface shows, and always framed around it.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterWindowTracksSurface() async throws {
    let harness = Capture687Harness()
    #expect(!harness.panel.isVisible)
    #expect(try await harness.run(png("n"), text: "abc", frame: secondaryVisible))
    let notice = try #require(harness.notice)
    #expect(harness.panel.isVisible)
    #expect(harness.panel.frame == CaptureRecogniseTextLayout.windowFrame(surface: notice.frame.size, visibleFrame: secondaryVisible))
    #expect(!harness.panel.canBecomeKey)
    try harness.click(notice)
    let panel = try #require(harness.textPanel)
    #expect(harness.notice == nil)
    #expect(harness.panel.isVisible)
    #expect(harness.panel.frame.width == 420)
    #expect(harness.panel.frame.height == panel.frame.height + 40)
    #expect(harness.panel.frame.maxX == secondaryVisible.maxX)
    panel.closeButton.performClick(nil)
    #expect(!harness.panel.isVisible)
    #expect(!harness.panel.canBecomeKey)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterReplacingOrDismissingOpenPanelDropsKey() async throws {
    for replace in [true, false] {
        let harness = Capture687Harness()
        #expect(try await harness.run(png("o"), text: "first"))
        try harness.click(try #require(harness.notice))
        let editor = try #require(harness.textPanel?.textView)
        #expect(harness.panel.canBecomeKey)
        if replace {
            #expect(try await harness.run(png("p"), text: "second"))
            #expect(harness.notice != nil)
        } else {
            harness.presenter.dismiss()
        }
        #expect(harness.textPanel == nil)
        #expect(!harness.panel.canBecomeKey)
        #expect(!harness.panel.isKeyWindow)
        #expect(harness.panel.firstResponder !== editor)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterSecondPresentReplacesFirstWindowState() async throws {
    let harness = Capture687Harness()
    #expect(try await harness.run(png("q"), text: "first"))
    #expect(harness.notice != nil)
    let task = harness.presenter.present(png: png("r"), visibleFrame: primaryVisible)
    #expect(harness.notice == nil)
    #expect(harness.presenter.windows.count == 1)
    #expect(!harness.panel.isVisible)
    await harness.gate.answer(png("r"), .success("second!"))
    #expect(await capture687Finish(task))
    #expect(harness.notice?.messageLabel.stringValue == String(localized: "Copied \(Int64(7)) characters"))
}

// MARK: Window and announcements

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureHostPanelProperties() async throws {
    let harness = Capture687Harness()
    let thumbnail = CaptureThumbnailController(
        model: CaptureThumbnailModel(state: CaptureThumbnailState(png: Data(), savedURL: nil, clipboard: .notCopied,
                                                                  folderDisplay: "~"),
                                     session: CaptureSession(screen: Capture687Screen(), files: Capture687Files()),
                                     clipboard: PasteboardCaptureClipboard(name: .init("mado.test.687c.thumb")),
                                     trash: FileManagerCaptureTrash { _ in }),
        visibleFrame: primaryVisible, startsTimer: false)
    #expect(try await harness.run(png("s"), text: "abc"))
    let panel = harness.panel
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.styleMask.contains(.borderless))
    #expect(panel.backgroundColor == .clear)
    #expect(!panel.isOpaque)
    #expect(panel.level == .screenSaver)
    #expect(panel.collectionBehavior == thumbnail.panel.collectionBehavior)
    #expect(!panel.canBecomeMain)
    #expect(!panel.canBecomeKey)
}

private struct Capture687Screen: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { png("current") }
    func capturePNG(request: CaptureRequest) async throws -> Data {
        switch request.target {
        case let .region(_, id, _, _): png("region-\(id)")
        case let .window(id): png("window-\(id)")
        case let .fullScreen(id): png("screen-\(id)")
        }
    }
}

private actor Capture687Files: CaptureFilePort {
    private(set) var writes = 0
    private(set) var folderDisplayCalls = 0
    func writeNewPNG(_ data: Data, named: String) async throws -> URL { writes += 1; return URL(fileURLWithPath: "/C/\(named)") }
    func folderDisplay() async -> String? { folderDisplayCalls += 1; return "~/C" }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureNoticeAcceptsFirstMouseOnlyInHelper() async throws {
    let harness = Capture687Harness()
    #expect(try await harness.run(png("t"), text: "abc"))
    #expect(try #require(harness.notice).acceptsFirstMouse(for: nil))
    let bare = RecogniseTextNoticeView(message: "x", engine: nil, kind: .success, onOpen: {})
    #expect(!bare.acceptsFirstMouse(for: nil))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureTextNeverCreatesThumbnail() async throws {
    let harness = Capture687Harness()
    #expect(try await harness.run(png("u"), text: "abc"))
    #expect(!NSApp.windows.contains { $0 is CaptureThumbnailPanel && $0.isVisible })
    #expect(harness.presenter.windows.count == 1)
    #expect(harness.presenter.windows.first === harness.panel)
    harness.presenter.dismiss()
    #expect(harness.presenter.windows.allSatisfy { !$0.isVisible })
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterCreatesItsPanelEagerly() {
    let harness = Capture687Harness()
    #expect(harness.presenter.windows.count == 1)
    #expect(harness.presenter.windows.first is CaptureRecogniseTextPanel)
    #expect(!harness.panel.isVisible)
}

/// Law: one announcement per present, whatever happens to the notice and panel afterwards.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CapturePresenterAnnouncesOncePerPresent() async throws {
    let harness = Capture687Harness()
    var expected: [String] = []
    for (index, text) in ["a", "bb", " "].enumerated() {
        #expect(try await harness.run(png("v\(index)"), text: text))
        expected.append(try #require(harness.notice?.accessibilityLabel()))
    }
    #expect(harness.announcements == expected)
    #expect(expected[0] == String(localized: "Copied \(Int64(1)) characters") + " · " + String(localized: "On-device Recognition"))
    #expect(expected[2] == String(localized: "No text found · Clipboard unchanged"))
    #expect(try await harness.run(png("v3"), text: "ccc"))
    let count = harness.announcements.count
    try harness.click(try #require(harness.notice))
    try #require(harness.textPanel).closeButton.performClick(nil)
    #expect(harness.announcements.count == count)
}

@MainActor @Test(.timeLimit(.minutes(4))) func issue687CapturePresenterDefaultRecogniserIsRealOnDeviceVision() async throws {
    let harness = Capture687Harness(recognise: CaptureRecogniseTextPresenter.onDevice)
    harness.seed()
    let image = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    for x in 0..<64 { for y in 0..<64 { image.setColor(.white, atX: x, y: y) } }
    let data = try #require(image.representation(using: .png, properties: [:]))
    let task = harness.presenter.present(png: data, visibleFrame: primaryVisible)
    var done = false
    Task { await task.value; done = true }
    let deadline = ContinuousClock.now + .seconds(60)
    while !done, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    #expect(done)
    #expect(harness.notice?.messageLabel.stringValue == String(localized: "No text found · Clipboard unchanged"))
    #expect(harness.pasteboard.string(forType: .string) == "before")
}

// MARK: Flow

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFlowRegionUsesItsDisplayAndWritesNothing() async throws {
    let files = Capture687Files()
    let session = CaptureSession(screen: Capture687Screen(), files: files)
    let screens: [CaptureThumbnailPlacement.Screen] = [(id: 1, frame: primaryVisible, visible: primaryVisible),
                                                       (id: 2, frame: secondaryVisible, visible: secondaryVisible)]
    let request = CaptureRequest(target: .region(rect: CGRect(x: -1000, y: 100, width: 50, height: 40), displayID: 2,
                                                 displayFrame: secondaryVisible, scale: 2),
                                 barWindowIDs: [], overlayWindowIDs: [])
    let result = try await CaptureRecogniseTextFlow.capture(request: { request }, selectedDisplay: 1, session: session,
                                                           screens: { screens })
    #expect(result.png == png("region-2"))
    #expect(result.visibleFrame == secondaryVisible)
    #expect(await files.writes == 0)
    #expect(await files.folderDisplayCalls == 0)
}

/// Law: the text notice lands on the display a thumbnail would, for every kind of target.
@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFlowDisplayRuleTable() async throws {
    let session = CaptureSession(screen: Capture687Screen(), files: Capture687Files())
    let screens: [CaptureThumbnailPlacement.Screen] = [(id: 1, frame: primaryVisible, visible: primaryVisible),
                                                       (id: 2, frame: secondaryVisible, visible: secondaryVisible)]
    let rows: [(CaptureRequest.Target, UInt32?, NSRect)] = [
        (.window(windowID: 40), 1, primaryVisible), (.window(windowID: 41), 2, secondaryVisible),
        (.window(windowID: 42), nil, primaryVisible), (.window(windowID: 43), 9, primaryVisible),
        (.fullScreen(displayID: 2), nil, secondaryVisible)
    ]
    for (target, selected, expected) in rows {
        let request = CaptureRequest(target: target, barWindowIDs: [], overlayWindowIDs: [])
        let result = try await CaptureRecogniseTextFlow.capture(request: { request }, selectedDisplay: selected,
                                                               session: session, screens: { screens })
        #expect(result.visibleFrame == expected)
        let thumbnailDisplay = CaptureThumbnailPlacement.displayID(for: target, selectedDisplay: selected)
        #expect(result.visibleFrame == CaptureThumbnailPlacement.visibleFrame(displayID: thumbnailDisplay, screens: screens))
    }
}

private actor Capture687HeldFiles: CaptureFilePort {
    private var finished = false
    private(set) var arrived = false
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        arrived = true
        let deadline = ContinuousClock.now + capture687Limit
        while !finished {
            guard ContinuousClock.now < deadline else { throw Capture687Timeout() }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return URL(fileURLWithPath: "/C/\(named)")
    }
    func finish() { finished = true }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687CaptureFlowPropagatesBusy() async throws {
    let files = Capture687HeldFiles()
    let session = CaptureSession(screen: Capture687Screen(), files: files)
    let request = CaptureRequest(target: .fullScreen(displayID: 1), barWindowIDs: [], overlayWindowIDs: [])
    let held = Task { try await session.capture(request: request) }
    var arrived = false
    let deadline = ContinuousClock.now + capture687Limit
    while !arrived, ContinuousClock.now < deadline {
        arrived = await files.arrived
        try? await Task.sleep(for: .milliseconds(5))
    }
    #expect(arrived)
    var screenReads = 0
    await #expect(throws: CaptureSessionError.busy) {
        _ = try await CaptureRecogniseTextFlow.capture(request: { request }, selectedDisplay: nil, session: session,
                                                      screens: { screenReads += 1; return [] })
    }
    #expect(screenReads == 0)
    await files.finish()
    _ = try await held.value
}
