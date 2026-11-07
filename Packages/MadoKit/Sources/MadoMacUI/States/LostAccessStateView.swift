import AppKit
import QuartzCore
import MadoApplication

/// Copy is supplied by the application so this native surface owns presentation only.
public struct LostAccessStateText: Equatable, Sendable {
    public let title: String
    public let detail: String
    public let waiting: String
    public let reselect: String
    public let chooseOther: String
    public init(title: String, detail: String, waiting: String, reselect: String, chooseOther: String) {
        self.title = title; self.detail = detail; self.waiting = waiting
        self.reselect = reselect; self.chooseOther = chooseOther
    }
}

@MainActor private final class LostAccessButton: NSButton {
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

/// Native page 26 recovery surface. The owning window decides when and where to recover.
public final class LostAccessStateView: NSView {
    public let iconView = NSImageView()
    public let titleLabel = NSTextField(labelWithString: "")
    public let detailLabel = NSTextField(wrappingLabelWithString: "")
    public let waitingLabel = NSTextField(labelWithString: "")
    public let waitingDot = NSView()
    public let reselectButton: NSButton = LostAccessButton(title: "", target: nil, action: nil)
    public let chooseOtherButton: NSButton = LostAccessButton(title: "", target: nil, action: nil)
    public private(set) var buttons: [NSButton] = []
    public var mainButton: NSButton? { buttons.first }
    public var onReselectFolder: (() -> Void)?
    public var onChooseAnotherFolder: (() -> Void)?
    public var reduceMotion = false {
        didSet { if reduceMotion != oldValue { refreshWaitingAnimation() } }
    }
    private var cause: AccessLossCause = .unknown
    private let waitingAnimationKey = "access.waiting.pulse"

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityIdentifier("access.lost.state")
        setAccessibilityElement(false)
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        titleLabel.textColor = DesignColor.textPrimary.nsColor
        titleLabel.alignment = .center
        titleLabel.maximumNumberOfLines = 0
        titleLabel.cell?.wraps = true
        detailLabel.font = NSFont.systemFont(ofSize: 13)
        detailLabel.textColor = DesignColor.textSecondary.nsColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 0
        detailLabel.cell?.wraps = true
        waitingLabel.font = NSFont.systemFont(ofSize: 12)
        waitingLabel.textColor = DesignColor.textSecondary.nsColor
        waitingDot.wantsLayer = true
        waitingDot.layer?.cornerRadius = 3.5
        waitingDot.setAccessibilityElement(false)
        iconView.contentTintColor = DesignColor.textSecondary.nsColor
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        for (button, id) in [(reselectButton, "access.lost.reselect"), (chooseOtherButton, "access.lost.chooseOther")] {
            button.font = NSFont.systemFont(ofSize: 13)
            button.isBordered = false
            button.focusRingType = .exterior
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.setAccessibilityIdentifier(id)
            button.target = self; button.action = #selector(activate(_:))
        }
        (reselectButton as? LostAccessButton)?.primary = true
    }
    public required init?(coder: NSCoder) { nil }

    public func display(cause: AccessLossCause, text: LostAccessStateText) {
        let previouslyFocused = window?.firstResponder as? NSView
        self.cause = cause
        for button in [reselectButton, chooseOtherButton] { button.isEnabled = false; button.nextKeyView = nil }
        subviews.forEach { $0.removeFromSuperview() }
        titleLabel.stringValue = text.title
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.minimumLineHeight = 22.1; paragraph.maximumLineHeight = 22.1
        detailLabel.attributedStringValue = NSAttributedString(string: text.detail, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: DesignColor.textSecondary.nsColor, .paragraphStyle: paragraph])
        waitingLabel.stringValue = text.waiting
        reselectButton.title = text.reselect
        chooseOtherButton.title = text.chooseOther
        iconView.image = Self.recoveryImage(for: cause)
        buttons = cause == .diskNotConnected ? [chooseOtherButton]
            : cause == .accessExpired ? [reselectButton] : [reselectButton, chooseOtherButton]
        [iconView, titleLabel, detailLabel].forEach { addSubview($0) }
        if cause == .diskNotConnected { addSubview(waitingDot); addSubview(waitingLabel) }
        for button in buttons {
            button.isEnabled = true
            (button as? LostAccessButton)?.refreshColors()
            addSubview(button)
        }
        for (index, button) in buttons.enumerated() { button.nextKeyView = buttons[(index + 1) % buttons.count] }
        let accessibilityContent: [NSView] = [titleLabel, detailLabel] + (cause == .diskNotConnected ? [waitingLabel] : []) + buttons
        setAccessibilityChildren(accessibilityContent)
        if let previouslyFocused, (previouslyFocused === reselectButton || previouslyFocused === chooseOtherButton),
           !buttons.contains(where: { $0 === previouslyFocused }) {
            window?.makeFirstResponder(buttons.first)
        }
        refreshColors()
        refreshWaitingAnimation()
        needsLayout = true
    }
    /// Page 26 uses the pinned 24-unit SVG paths inside a 32-point template image.
    /// Keep the outer canvas: the approximately 26-point bounds describe the ink.
    private static func recoveryImage(for cause: AccessLossCause) -> NSImage? {
        guard cause != .unknown else {
            return NSImage(systemSymbolName: "folder.badge.questionmark", accessibilityDescription: nil)
        }
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: true) { rect in
            let scale = rect.width / 24
            func stroke(_ path: NSBezierPath, dashed: Bool = false) {
                path.transform(using: AffineTransform(scale: scale))
                path.lineWidth = 1.3 * scale
                path.lineCapStyle = .round; path.lineJoinStyle = .round
                if dashed { path.setLineDash([2.5 * scale, 2 * scale], count: 2, phase: 0) }
                NSColor.black.setStroke()
                path.stroke()
            }
            if cause == .diskNotConnected {
                stroke(NSBezierPath(roundedRect: NSRect(x: 3, y: 7, width: 18, height: 10), xRadius: 2, yRadius: 2))
                let indicators = NSBezierPath()
                indicators.move(to: NSPoint(x: 7, y: 13)); indicators.line(to: NSPoint(x: 7.01, y: 13))
                indicators.move(to: NSPoint(x: 11, y: 13)); indicators.line(to: NSPoint(x: 17, y: 13))
                stroke(indicators)
            } else {
                // SVG circular arcs expressed as cubic quarter circles.
                let arc: CGFloat = 0.5522847498307936
                let folder = NSBezierPath()
                folder.move(to: NSPoint(x: 3, y: 7)); folder.line(to: NSPoint(x: 3, y: 5))
                folder.curve(to: NSPoint(x: 5, y: 3), controlPoint1: NSPoint(x: 3, y: 5 - 2 * arc), controlPoint2: NSPoint(x: 5 - 2 * arc, y: 3))
                folder.line(to: NSPoint(x: 10, y: 3)); folder.line(to: NSPoint(x: 12, y: 6))
                folder.line(to: NSPoint(x: 19, y: 6))
                folder.curve(to: NSPoint(x: 21, y: 8), controlPoint1: NSPoint(x: 19 + 2 * arc, y: 6), controlPoint2: NSPoint(x: 21, y: 8 - 2 * arc))
                folder.line(to: NSPoint(x: 21, y: 19))
                folder.curve(to: NSPoint(x: 19, y: 21), controlPoint1: NSPoint(x: 21, y: 19 + 2 * arc), controlPoint2: NSPoint(x: 19 + 2 * arc, y: 21))
                folder.line(to: NSPoint(x: 5, y: 21))
                folder.curve(to: NSPoint(x: 3, y: 19), controlPoint1: NSPoint(x: 5 - 2 * arc, y: 21), controlPoint2: NSPoint(x: 3, y: 19 + 2 * arc))
                folder.close()
                stroke(folder, dashed: cause == .notFound)
                if cause == .accessExpired {
                    stroke(NSBezierPath(roundedRect: NSRect(x: 9.5, y: 12, width: 5, height: 4), xRadius: 1, yRadius: 1))
                    let shackle = NSBezierPath()
                    shackle.move(to: NSPoint(x: 10.5, y: 12)); shackle.line(to: NSPoint(x: 10.5, y: 10.8))
                    shackle.curve(to: NSPoint(x: 12, y: 9.3), controlPoint1: NSPoint(x: 10.5, y: 10.8 - 1.5 * arc), controlPoint2: NSPoint(x: 12 - 1.5 * arc, y: 9.3))
                    shackle.curve(to: NSPoint(x: 13.5, y: 10.8), controlPoint1: NSPoint(x: 12 + 1.5 * arc, y: 9.3), controlPoint2: NSPoint(x: 13.5, y: 10.8 - 1.5 * arc))
                    shackle.line(to: NSPoint(x: 13.5, y: 12))
                    stroke(shackle)
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }
    private func refreshWaitingAnimation() {
        guard let layer = waitingDot.layer else { return }
        let shouldPulse = cause == .diskNotConnected && waitingDot.superview === self &&
            window != nil && !isHiddenOrHasHiddenAncestor && !reduceMotion
        guard shouldPulse else {
            layer.removeAnimation(forKey: waitingAnimationKey)
            layer.opacity = 1
            return
        }
        guard layer.animation(forKey: waitingAnimationKey) == nil else { return }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [NSNumber(value: 1.0), NSNumber(value: 0.3), NSNumber(value: 1.0)]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 1.6
        pulse.timingFunctions = [CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        pulse.repeatCount = .infinity
        pulse.beginTime = CACurrentMediaTime()
        layer.add(pulse, forKey: waitingAnimationKey)
    }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); refreshWaitingAnimation() }
    public override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); refreshWaitingAnimation() }
    public override func viewDidHide() { super.viewDidHide(); refreshWaitingAnimation() }
    public override func viewDidUnhide() { super.viewDidUnhide(); refreshWaitingAnimation() }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = DesignColor.canvasBackground.nsColor.cgColor
            waitingDot.layer?.backgroundColor = DesignColor.waitingIndicator.nsColor.cgColor
        }
        buttons.forEach { ($0 as? LostAccessButton)?.refreshColors() }
    }
    public override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    public override func layout() {
        super.layout()
        guard !buttons.isEmpty else { return }
        let horizontalInset: CGFloat = (window?.contentView?.bounds.width ?? bounds.width) < 1050 ? 40 : 48
        let availableWidth = max(0, bounds.width - horizontalInset * 2)
        let detailWidth = min(460, availableWidth)
        // These programmatically constructed text fields always retain their constructor-created cells.
        let titleHeight = ceil(titleLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: availableWidth, height: 10_000)).height)
        let detailHeight = ceil(detailLabel.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: detailWidth, height: 10_000)).height)
        let font = NSFont.systemFont(ofSize: 13)
        let buttonHeight = ceil(font.ascender - font.descender) + 16
        let buttonWidths = buttons.map { button in ceil((button.title as NSString).size(withAttributes: [.font: font]).width) + (button === reselectButton ? 32 : 8) }
        let waitingWidth = ceil((waitingLabel.stringValue as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        let rowWidth = cause == .diskNotConnected ? 7 + 6 + waitingWidth + 16 + buttonWidths[0] : buttonWidths.reduce(0, +) + CGFloat(max(0, buttons.count - 1)) * 16
        let height = 32 + 18 + titleHeight + 9 + detailHeight + 18 + buttonHeight
        var top = bounds.midY + 19 + height / 2
        iconView.frame = NSRect(x: bounds.midX - 16, y: top - 32, width: 32, height: 32)
        top = iconView.frame.minY - 18
        titleLabel.frame = NSRect(x: bounds.midX - availableWidth / 2, y: top - titleHeight, width: availableWidth, height: titleHeight)
        top = titleLabel.frame.minY - 9
        detailLabel.frame = NSRect(x: bounds.midX - detailWidth / 2, y: top - detailHeight, width: detailWidth, height: detailHeight)
        let rowY = detailLabel.frame.minY - 18 - buttonHeight
        var left = bounds.midX - rowWidth / 2
        if cause == .diskNotConnected {
            waitingDot.frame = NSRect(x: left, y: rowY + (buttonHeight - 7) / 2, width: 7, height: 7)
            left += 13
            let waitingHeight = ceil(waitingLabel.cell!.cellSize.height)
            waitingLabel.frame = NSRect(x: left, y: rowY + (buttonHeight - waitingHeight) / 2, width: waitingWidth, height: waitingHeight)
            left += waitingWidth + 16
        }
        for (button, width) in zip(buttons, buttonWidths) {
            button.frame = NSRect(x: left, y: rowY, width: width, height: buttonHeight)
            left += width + 16
        }
        refreshColors()
    }
    @objc private func activate(_ sender: NSButton) {
        guard sender.isEnabled, buttons.contains(where: { $0 === sender }) else { return }
        if sender === reselectButton { onReselectFolder?() }
        else { onChooseAnotherFolder?() }
    }
}
