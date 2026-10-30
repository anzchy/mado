import AppKit

/// Copy is supplied by the owner (ViewerStateHost) so this surface owns presentation only.
public struct ReadFailedStateText: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let retry: String
    public let chooseOther: String
    public init(title: String, detail: String, retry: String, chooseOther: String) {
        self.title = title; self.detail = detail; self.retry = retry; self.chooseOther = chooseOther
    }
}

@MainActor private final class ReadFailedButton: NSButton {
    var primary = false
    private var hovered = false
    private var hoverTracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }
    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(tracking); hoverTracking = tracking
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshColors() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshColors() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = primary ? (hovered ? DesignColor.primaryFillHover : .primaryFill).nsColor.cgColor : NSColor.clear.cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: (primary ? DesignColor.onPrimary : .selectionText).nsColor])
        }
    }
}

/// Native 「读取失败」 (folder-loading.html `?case=failed`, 24F-A, #238): a read stopped while its Access Root is
/// still readable. The owner decides what Retry and Choose Another Folder do.
public final class ReadFailedStateView: NSView {
    public let iconView = NSImageView()
    public let titleLabel = NSTextField(labelWithString: "")
    public let detailLabel = NSTextField(wrappingLabelWithString: "")
    public let retryButton: NSButton = ReadFailedButton(title: "", target: nil, action: nil)
    public let chooseOtherButton: NSButton = ReadFailedButton(title: "", target: nil, action: nil)
    public var buttons: [NSButton] { [retryButton, chooseOtherButton] }
    public var onRetry: (() -> Void)?
    public var onChooseOtherFolder: (() -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("state.read-failed")
        setAccessibilityRole(.group)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = DesignColor.textPrimary.nsColor
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 0
        titleLabel.cell?.wraps = true
        titleLabel.setAccessibilityIdentifier("state.heading")
        detailLabel.font = NSFont.systemFont(ofSize: 13)
        detailLabel.textColor = DesignColor.textSecondary.nsColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.cell?.wraps = true
        detailLabel.setAccessibilityIdentifier("state.description")
        iconView.image = Self.folderAlertImage
        iconView.contentTintColor = DesignColor.textSecondary.nsColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        for (button, id) in [(retryButton, "state.retry-folder"), (chooseOtherButton, "state.choose-other-folder")] {
            button.font = NSFont.systemFont(ofSize: 13)
            button.isBordered = false
            button.focusRingType = .exterior
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.setAccessibilityIdentifier(id)
            button.target = self; button.action = #selector(activate(_:))
        }
        (retryButton as? ReadFailedButton)?.primary = true
        retryButton.nextKeyView = chooseOtherButton
        chooseOtherButton.nextKeyView = retryButton
        [iconView, titleLabel, detailLabel, retryButton, chooseOtherButton].forEach { addSubview($0) }
        setAccessibilityChildren([titleLabel, detailLabel, retryButton, chooseOtherButton])
    }
    public required init?(coder: NSCoder) { nil }

    /// The pinned folder-with-alert glyph (24 × 24 viewBox, stroke 1.3), drawn as a template for the muted tint.
    static let folderAlertImage: NSImage = {
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { rect in
            let scale = rect.width / 24
            let folder = NSBezierPath()
            folder.move(to: NSPoint(x: 3, y: 7))
            folder.appendArc(from: NSPoint(x: 3, y: 5), to: NSPoint(x: 5, y: 5), radius: 2)
            folder.line(to: NSPoint(x: 9, y: 5)); folder.line(to: NSPoint(x: 11, y: 7)); folder.line(to: NSPoint(x: 19, y: 7))
            folder.appendArc(from: NSPoint(x: 21, y: 7), to: NSPoint(x: 21, y: 9), radius: 2)
            folder.line(to: NSPoint(x: 21, y: 17))
            folder.appendArc(from: NSPoint(x: 21, y: 19), to: NSPoint(x: 19, y: 19), radius: 2)
            folder.line(to: NSPoint(x: 5, y: 19))
            folder.appendArc(from: NSPoint(x: 3, y: 19), to: NSPoint(x: 3, y: 17), radius: 2)
            folder.close()
            folder.move(to: NSPoint(x: 12, y: 10.5)); folder.line(to: NSPoint(x: 12, y: 13.7))
            folder.move(to: NSPoint(x: 12, y: 16.2)); folder.line(to: NSPoint(x: 12.01, y: 16.2))
            folder.transform(using: AffineTransform(scale: scale))
            folder.lineWidth = 1.3 * scale
            folder.lineCapStyle = .round; folder.lineJoinStyle = .round
            NSColor.black.setStroke()
            folder.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()

    public func display(_ text: ReadFailedStateText) {
        titleLabel.stringValue = text.title
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 22.1; paragraph.maximumLineHeight = 22.1
        detailLabel.attributedStringValue = NSAttributedString(string: text.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: DesignColor.textSecondary.nsColor, .paragraphStyle: paragraph])
        retryButton.title = text.retry
        chooseOtherButton.title = text.chooseOther
        for button in buttons {
            button.isHidden = false; button.setAccessibilityHidden(false)
            button.isEnabled = true; button.setAccessibilityEnabled(true)
            button.setAccessibilityLabel(button.title)
        }
        [iconView, titleLabel, detailLabel].forEach { $0.isHidden = false; $0.setAccessibilityHidden(false) }
        retryButton.nextKeyView = chooseOtherButton
        setAccessibilityLabel(text.title)
        setAccessibilityValue(text.detail)
        titleLabel.setAccessibilityLabel(text.title)
        detailLabel.setAccessibilityLabel(text.detail)
        refreshColors()
        needsLayout = true
    }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
        }
        buttons.forEach { ($0 as? ReadFailedButton)?.refreshColors() }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    /// `.failed-state` in `.grid-scroll` matches page 26's box: content centred 19pt above the middle
    /// (scroll padding 16/30, state padding-bottom 48), icon 32 + 18, title + 9, detail ≤ 460 + 18, then the actions.
    public override func layout() {
        super.layout()
        let horizontalInset: CGFloat = (window?.contentView?.bounds.width ?? bounds.width) < 1050 ? 40 : 48
        let availableWidth = max(0, bounds.width - horizontalInset * 2)
        let detailWidth = min(460, availableWidth)
        // These programmatically constructed text fields always retain their constructor-created cells.
        let titleHeight = ceil(titleLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: availableWidth, height: 10_000)).height)
        let detailHeight = ceil(detailLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: detailWidth, height: 10_000)).height)
        let font = NSFont.systemFont(ofSize: 13)
        let buttonHeight = ceil(font.ascender - font.descender) + 16
        // `.mock-primary` pads 16 a side; the text button pads `--radius-inner` (4).
        let widths = buttons.map { ceil(($0.title as NSString).size(withAttributes: [.font: font]).width) + ($0 === retryButton ? 32 : 8) }
        let rowWidth = widths.reduce(0, +) + 16
        let height = 32 + 18 + titleHeight + 9 + detailHeight + 18 + buttonHeight
        var top = bounds.midY + 19 + height / 2
        iconView.frame = NSRect(x: bounds.midX - 16, y: top - 32, width: 32, height: 32)
        top = iconView.frame.minY - 18
        titleLabel.frame = NSRect(x: bounds.midX - availableWidth / 2, y: top - titleHeight, width: availableWidth, height: titleHeight)
        top = titleLabel.frame.minY - 9
        detailLabel.frame = NSRect(x: bounds.midX - detailWidth / 2, y: top - detailHeight, width: detailWidth, height: detailHeight)
        let rowY = detailLabel.frame.minY - 18 - buttonHeight
        var left = bounds.midX - rowWidth / 2
        for (button, width) in zip(buttons, widths) {
            button.frame = NSRect(x: left, y: rowY, width: width, height: buttonHeight)
            left += width + 16
        }
        refreshColors()
    }
    @objc private func activate(_ sender: NSButton) {
        guard sender.isEnabled, !isHiddenOrHasHiddenAncestor else { return }
        if sender === retryButton { onRetry?() } else { onChooseOtherFolder?() }
    }
}
