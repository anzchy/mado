import AppKit
import Testing
import MadoMacUI

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignRecogniseNoticeRendersCapsuleAndEngineAtWindowCorner() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    overlay.showNotice(message: "已拷贝 12345 个字符", engine: "本机识别", kind: .success, onOpen: {})
    overlay.layoutSubtreeIfNeeded()
    let notice = try #require(overlay.noticeView)
    #expect(notice.frame.height == 34)
    #expect(notice.frame.maxX == 780)
    #expect(notice.frame.minY == 20)
    #expect(notice.layer?.cornerRadius == 17)
    #expect(notice.iconView.frame.width == 16)
    #expect(notice.messageLabel.frame.minX == 38) // Child frame is parent-local: 14 + icon 16 + gap 8.
    #expect(notice.engineTag.frame.height == 18)
    #expect(notice.engineTag.frame.minX - notice.messageLabel.frame.maxX == 8)
    #expect(notice.engineTag.stringValue == "本机识别")
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignRecognisePanelKeepsTextAreaFixedAndShrinksAtMinimumWidth() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    overlay.showPanel(text: String(repeating: "中文abc\n", count: 400), engine: "本机识别", onEdit: nil, onCopy: nil, onClose: nil)
    overlay.layoutSubtreeIfNeeded()
    let panel = try #require(overlay.panelView)
    #expect(panel.frame.width == 380)
    #expect(panel.frame.maxX == 780)
    #expect(panel.frame.minY == 20)
    #expect(panel.layer?.cornerRadius == 10)
    #expect(panel.scrollView.frame.height == 150)
    #expect(panel.scrollView.frame.minX == 12) // Child frame is parent-local.
    #expect(panel.closeButton.frame.size == CGSize(width: 26, height: 26))
    #expect(panel.copyButton.frame.height == 26)
    #expect(panel.copyButton.frame.maxX == panel.frame.width - 12)
    overlay.frame.size.width = 238
    overlay.layoutSubtreeIfNeeded()
    #expect(panel.frame.width == 198)
    #expect(panel.frame.maxX == 218)
    #expect(panel.scrollView.frame.height == 150)
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignWarningHasNoEngineAndNoticeUsesMutedInk() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    overlay.showNotice(message: "未找到文字 · 剪贴板没有改变", engine: nil, kind: .warning, onOpen: nil)
    overlay.layoutSubtreeIfNeeded()
    let notice = try #require(overlay.noticeView)
    #expect(notice.engineTag.isHidden)
    #expect(notice.iconView.contentTintColor == DesignColor.textSecondary.nsColor)
    #expect(notice.onOpen == nil)
    #expect(notice.frame.height == 34)
}

@MainActor @Test(.timeLimit(.minutes(3))) func recogniseNoticeHoverHoldsThenDismissesFiveSecondsAfterExit() throws {
    _ = NSApplication.shared
    var scheduled: [@MainActor () -> Void] = []
    var intervals: [TimeInterval] = []
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 500)) { interval, action in
        intervals.append(interval)
        scheduled.append(action)
    }
    var dismissals = 0
    overlay.onDismiss = { dismissals += 1 }
    overlay.showNotice(message: "copied", engine: "On-device Recognition", kind: .success, onOpen: {})
    let notice = try #require(overlay.noticeView)
    notice.onHoverChange?(true)
    scheduled[0]() // The original deadline has passed while the pointer is over it.
    #expect(overlay.noticeView === notice)
    notice.onHoverChange?(false)
    #expect(intervals == [5, 5])
    scheduled[1]()
    #expect(overlay.noticeView == nil)
    #expect(dismissals == 1)
}

@MainActor @Test(.timeLimit(.minutes(3))) func recognisePanelEditingCopyCloseAndCanvasHitPassThrough() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    var edits: [String] = []
    var copies = 0
    var closes = 0
    overlay.showPanel(text: "initial", engine: "本机识别", onEdit: { edits.append($0) },
                      onCopy: { copies += 1 }, onClose: { closes += 1 })
    overlay.layoutSubtreeIfNeeded()
    let panel = try #require(overlay.panelView)
    panel.textView.string = "edited"
    panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
    panel.copyButton.performClick(nil)
    panel.closeButton.performClick(nil)
    #expect(edits == ["edited"])
    #expect(copies == 1)
    #expect(closes == 1)
    #expect(overlay.hitTest(NSPoint(x: 40, y: 40)) == nil)
    #expect(overlay.hitTest(NSPoint(x: 760, y: 40)) != nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignMaterialTintTracksBothAppearancesAboveBlur() throws {
    _ = NSApplication.shared
    for (appearance, expectedRGB) in [
        (NSAppearance.Name.aqua, [1.0, 1.0, 1.0]),
        (NSAppearance.Name.darkAqua, [20.0/255, 24.0/255, 33.0/255])
    ] {
        let notice = RecogniseTextNoticeView(message: "copied", engine: "On-device", kind: .success, onOpen: {})
        notice.appearance = try #require(NSAppearance(named: appearance))
        let blurIndex = try #require(notice.subviews.firstIndex(where: { $0 is NSVisualEffectView }))
        let tintIndex = try #require(notice.subviews.firstIndex(where: {
            $0.identifier?.rawValue == "recognise-text.panel-tint"
        }))
        #expect(blurIndex < tintIndex)
        let tint = notice.subviews[tintIndex]
        let color = try #require(tint.layer?.backgroundColor)
        let components = try #require(NSColor(cgColor: color)?.usingColorSpace(.deviceRGB))
        #expect(abs(components.redComponent - expectedRGB[0]) < 0.01)
        #expect(abs(components.greenComponent - expectedRGB[1]) < 0.01)
        #expect(abs(components.blueComponent - expectedRGB[2]) < 0.01)
        #expect(abs(components.alphaComponent - 0.86) < 0.01)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignFloatingControlsRefreshInnerColorsAcrossAppearanceChanges() throws {
    _ = NSApplication.shared
    let notice = RecogniseTextNoticeView(message: "copied", engine: "On-device", kind: .success, onOpen: {})
    let panel = RecogniseTextPanelView(text: "text", engine: "On-device", onEdit: nil, onCopy: nil, onClose: nil)
    for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
        let appearance = try #require(NSAppearance(named: name))
        notice.appearance = appearance
        panel.appearance = appearance
        var expectedHover: [CGFloat]?
        var expectedPrimary: [CGFloat]?
        var expectedBorder: [CGFloat]?
        appearance.performAsCurrentDrawingAppearance {
            expectedHover = DesignColor.hoverBackground.nsColor.cgColor.components
            expectedPrimary = DesignColor.primaryFill.nsColor.cgColor.components
            expectedBorder = DesignColor.divider.nsColor.cgColor.components
        }
        #expect(notice.engineTag.layer?.backgroundColor?.components == expectedHover)
        #expect(panel.engineTag.layer?.backgroundColor?.components == expectedHover)
        #expect(panel.copyButton.layer?.backgroundColor?.components == expectedPrimary)
        #expect(panel.scrollView.layer?.borderColor?.components == expectedBorder)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignLongTextScrollsWithinFixedEditorAndFiveDigitNoticeStaysOneLine() throws {
    _ = NSApplication.shared
    let notice = RecogniseTextNoticeView(message: "已拷贝 12345 个字符", engine: "本机识别", kind: .success, onOpen: {})
    notice.layoutSubtreeIfNeeded()
    #expect(notice.messageLabel.maximumNumberOfLines == 1)
    #expect(notice.messageLabel.frame.width >= ceil(notice.messageLabel.intrinsicContentSize.width))

    let panel = RecogniseTextPanelView(text: String(repeating: "中文 abc\n", count: 400),
                                      engine: "本机识别", onEdit: nil, onCopy: nil, onClose: nil)
    panel.layoutSubtreeIfNeeded()
    let container = try #require(panel.textView.textContainer)
    let manager = try #require(panel.textView.layoutManager)
    manager.ensureLayout(for: container)
    let usedHeight = manager.usedRect(for: container).height
    #expect(panel.scrollView.frame.height == 150)
    #expect(usedHeight > 150)
    #expect((panel.scrollView.documentView?.frame.height ?? 0) >= usedHeight)
}

@MainActor @Test(.timeLimit(.minutes(3))) func recogniseNoticeRealHitTargetOpensFromItsWholeCapsule() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    overlay.showNotice(message: "Copied 12345 characters", engine: "On-device Recognition",
                       kind: .success, onOpen: {})
    overlay.layoutSubtreeIfNeeded()
    let notice = try #require(overlay.noticeView)
    for x in [notice.frame.minX + 4, notice.frame.midX, notice.frame.maxX - 4] {
        #expect(overlay.hitTest(NSPoint(x: x, y: notice.frame.midY)) === notice)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func recogniseNoticeAccessibilityAndKeyboardActivateEditablePanel() throws {
    _ = NSApplication.shared
    var opens = 0
    let notice = RecogniseTextNoticeView(message: "Copied", engine: "On-device Recognition",
        kind: .success, onOpen: { opens += 1 })
    #expect(notice.acceptsFirstResponder)
    #expect(notice.accessibilityPerformPress())
    #expect(opens == 1)
    for (character, code) in [(" ", UInt16(49)), ("\r", UInt16(36))] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code))
        notice.keyDown(with: event)
    }
    #expect(opens == 3)
    let warning = RecogniseTextNoticeView(message: "No text", engine: nil, kind: .warning, onOpen: nil)
    #expect(!warning.acceptsFirstResponder)
    #expect(!warning.accessibilityPerformPress())
}

@MainActor @Test(.timeLimit(.minutes(3))) func PinnedDesignNarrowPanelKeepsHeaderAndFooterControlsApart() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 238, height: 340))
    overlay.showPanel(text: "text", engine: "本机识别", onEdit: nil, onCopy: nil, onClose: nil)
    overlay.layoutSubtreeIfNeeded()
    let panel = try #require(overlay.panelView)
    #expect(panel.frame.size == CGSize(width: 198, height: 300))
    #expect(!panel.titleLabel.frame.intersects(panel.engineTag.frame))
    #expect(!panel.engineTag.frame.intersects(panel.closeButton.frame))
    #expect(!panel.engineTag.frame.intersects(panel.scrollView.frame))
    #expect(!panel.footerLabel.frame.intersects(panel.copyButton.frame))
    #expect(!panel.footerLabel.frame.intersects(panel.scrollView.frame))
    panel.footerLabel.stringValue = "You can edit before copying again"
    panel.layoutSubtreeIfNeeded()
    #expect((panel.footerLabel.cell?.cellSize(forBounds: panel.footerLabel.bounds).height ?? 100) <= 32)
}

@MainActor @Test(.timeLimit(.minutes(3))) func recogniseNoticeStaysInsideMinimumWindowForLongEnglishAndNoText() throws {
    _ = NSApplication.shared
    let overlay = RecogniseTextOverlay(frame: NSRect(x: 0, y: 0, width: 238, height: 340))
    overlay.showNotice(message: "Copied 12345 characters", engine: "On-device Recognition", kind: .success, onOpen: {})
    overlay.layoutSubtreeIfNeeded()
    let copied = try #require(overlay.noticeView)
    #expect(copied.frame == NSRect(x: 20, y: 20, width: 198, height: 56))
    #expect(copied.messageLabel.frame.maxX <= copied.bounds.maxX - 14)
    #expect(copied.engineTag.frame.maxX <= copied.bounds.maxX - 14)
    #expect(copied.messageLabel.intrinsicContentSize.width <= copied.messageLabel.frame.width)
    overlay.showNotice(message: "No text found · Clipboard unchanged", engine: nil, kind: .warning, onOpen: nil)
    overlay.layoutSubtreeIfNeeded()
    let noText = try #require(overlay.noticeView)
    #expect(noText.frame == NSRect(x: 20, y: 20, width: 198, height: 56))
    #expect(noText.messageLabel.maximumNumberOfLines == 2)
    #expect((noText.messageLabel.cell?.cellSize(forBounds: noText.messageLabel.bounds).height ?? 100) <= 32)
}
