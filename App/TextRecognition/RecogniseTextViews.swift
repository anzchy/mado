import AppKit
import MadoMacUI

enum RecogniseTextNoticeKind { case success, warning }

/// The 86% panel tint and shadow are native layers over a platform blur.
@MainActor private func floatSurface(_ view: NSView, radius: CGFloat) {
    view.wantsLayer = true
    view.layer?.cornerRadius = radius
    view.layer?.borderWidth = 0.5
    view.layer?.shadowRadius = 12
    view.layer?.shadowOffset = NSSize(width: 0, height: -8)
    let blur = NSVisualEffectView(frame: view.bounds)
    blur.material = .popover
    blur.blendingMode = .withinWindow
    blur.state = .active
    blur.wantsLayer = true
    blur.layer?.cornerRadius = radius
    blur.layer?.masksToBounds = true
    blur.autoresizingMask = [.width, .height]
    view.addSubview(blur, positioned: .below, relativeTo: nil)
    let tint = NSView(frame: view.bounds)
    tint.identifier = NSUserInterfaceItemIdentifier("recognise-text.panel-tint")
    tint.wantsLayer = true
    tint.layer?.cornerRadius = radius
    tint.layer?.masksToBounds = true
    tint.autoresizingMask = [.width, .height]
    view.addSubview(tint, positioned: .above, relativeTo: blur)
    refreshFloatSurface(view)
}

@MainActor private func refreshFloatSurface(_ view: NSView) {
    guard let tint = view.subviews.first(where: { $0.identifier?.rawValue == "recognise-text.panel-tint" }) else { return }
    let isDark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        tint.layer?.backgroundColor = DesignColor.popoverBackground.nsColor.withAlphaComponent(0.86).cgColor
        view.layer?.borderColor = DesignColor.divider.nsColor.cgColor
        view.layer?.shadowColor = (isDark ? NSColor.black : DesignColor.textPrimary.nsColor).cgColor
    }
    view.layer?.shadowOpacity = isDark ? 0.45 : 0.08
}

@MainActor final class RecogniseTextEditor: NSTextView {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) {
        // #687 fix r5 (F5): an Esc no input method took while composing drops the composition, as Pinyin's Esc does;
        // it never closes the panel or commits the half-typed text.
        if hasMarkedText() {
            insertText("", replacementRange: markedRange())
            unmarkText()
            return
        }
        onEscape?()
    }
    // #687 fix r5 (F5/F6): the panel's key routing moves focus on Tab; a Tab that reaches the editor (while composing)
    // is not typed into the recognised text.
    override func insertTab(_ sender: Any?) {}
    override func insertBacktab(_ sender: Any?) {}
    // #687 fix r5 (F7): Edit › 撤销/重做 act on the editor's own stack, which ends with the panel.
    @objc func undo(_ sender: Any?) { undoManager?.undo() }
    @objc func redo(_ sender: Any?) { undoManager?.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == NSSelectorFromString("undo:") { return undoManager?.canUndo == true }
        if item.action == NSSelectorFromString("redo:") { return undoManager?.canRedo == true }
        return super.validateUserInterfaceItem(item)
    }
}

/// #687 fix r5 (F6): 拷贝 and 关闭 take keyboard focus like Mado's other controls.
@MainActor final class RecogniseTextKeyButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}

@MainActor final class RecogniseTextNoticeView: NSView {
    let iconView = NSImageView(frame: .zero)
    let messageLabel = NSTextField(labelWithString: "")
    let engineTag = NSTextField(labelWithString: "")
    let kind: RecogniseTextNoticeKind
    var onOpen: (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    /// #687 fix r5b (F9): keyboard focus (`false` argument: accessibility) arrived or left.
    var onFocusChange: ((_ keyboard: Bool, _ focused: Bool) -> Void)?
    var compactWidth: CGFloat? { didSet { if oldValue != compactWidth { needsLayout = true } } }
    private var tracking: NSTrackingArea?
    override var acceptsFirstResponder: Bool { kind == .success }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override func isAccessibilityElement() -> Bool { !isHiddenOrHasHiddenAncestor }
    override func accessibilityChildren() -> [Any]? { [] }
    override func setAccessibilityFocused(_ focused: Bool) {
        onFocusChange?(false, focused)
        if focused && kind == .success { _ = window?.makeFirstResponder(self) }
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true, true) }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(true, false) }
        return resigned
    }
    override func responds(to aSelector: Selector!) -> Bool {
        if kind != .success && aSelector == NSSelectorFromString("accessibilityPerformPress") { return false }
        return super.responds(to: aSelector)
    }

    init(message: String, engine: String?, kind: RecogniseTextNoticeKind, onOpen: (() -> Void)?) {
        self.kind = kind
        self.onOpen = onOpen
        super.init(frame: .zero)
        messageLabel.stringValue = message
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = DesignColor.textPrimary.nsColor
        messageLabel.lineBreakMode = .byClipping
        messageLabel.maximumNumberOfLines = 1
        iconView.image = NSImage(systemSymbolName: kind == .success ? "checkmark" : "exclamationmark.triangle",
                                accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = kind == .success
            ? NSColor(srgbRed: 22.0/255, green: 163.0/255, blue: 74.0/255, alpha: 1)
            : DesignColor.textSecondary.nsColor
        engineTag.stringValue = engine ?? ""
        engineTag.font = .systemFont(ofSize: 12)
        engineTag.textColor = DesignColor.textPrimary.nsColor
        engineTag.alignment = .center
        engineTag.wantsLayer = true
        engineTag.layer?.cornerRadius = 9
        engineTag.layer?.backgroundColor = DesignColor.hoverBackground.nsColor.cgColor
        engineTag.isHidden = engine == nil
        floatSurface(self, radius: 17)
        addSubview(iconView); addSubview(messageLabel); addSubview(engineTag)
        refreshInnerAppearance()
        setAccessibilityIdentifier("recognise-text.notice")
        setAccessibilityRole(kind == .success ? .button : .staticText)
        setAccessibilityLabel(message + (engine.map { " · " + $0 } ?? ""))
        frame.size = intrinsicContentSize
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFloatSurface(self)
        refreshInnerAppearance()
    }
    private func refreshInnerAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            engineTag.layer?.backgroundColor = DesignColor.hoverBackground.nsColor.cgColor
            iconView.contentTintColor = kind == .success
                ? NSColor(srgbRed: 22.0/255, green: 163.0/255, blue: 74.0/255, alpha: 1)
                : DesignColor.textSecondary.nsColor
            messageLabel.textColor = DesignColor.textPrimary.nsColor
            engineTag.textColor = DesignColor.textPrimary.nsColor
        }
    }
    override var intrinsicContentSize: NSSize {
        if let compactWidth { return NSSize(width: compactWidth, height: 56) }
        let labelWidth = ceil((messageLabel.stringValue as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width)
        let tagWidth = engineTag.isHidden ? 0 : ceil(engineTag.intrinsicContentSize.width) + 12
        return NSSize(width: 14 + 16 + 8 + labelWidth + (engineTag.isHidden ? 0 : 8 + tagWidth) + 14, height: 34)
    }
    override func layout() {
        super.layout()
        if compactWidth != nil {
            let available = max(0, bounds.width - 52)
            messageLabel.font = .systemFont(ofSize: 11)
            messageLabel.lineBreakMode = engineTag.isHidden ? .byWordWrapping : .byClipping
            messageLabel.maximumNumberOfLines = engineTag.isHidden ? 2 : 1
            iconView.frame = NSRect(x: 14, y: engineTag.isHidden ? 20 : 31, width: 16, height: 16)
            messageLabel.frame = NSRect(x: 38, y: engineTag.isHidden ? 12 : 30,
                                         width: available, height: engineTag.isHidden ? 32 : 16)
            if !engineTag.isHidden {
                engineTag.frame = NSRect(x: 38, y: 8,
                                         width: ceil(engineTag.intrinsicContentSize.width) + 12, height: 18)
            }
            return
        }
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.lineBreakMode = .byClipping
        messageLabel.maximumNumberOfLines = 1
        iconView.frame = NSRect(x: 14, y: 9, width: 16, height: 16)
        messageLabel.frame = NSRect(x: 38, y: 9, width: ceil(messageLabel.intrinsicContentSize.width), height: 16)
        if !engineTag.isHidden {
            engineTag.frame = NSRect(x: messageLabel.frame.maxX + 8, y: 8,
                                     width: ceil(engineTag.intrinsicContentSize.width) + 12, height: 18)
        }
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Use AppKit's coordinate conversion, then make the entire capsule one target.
        super.hitTest(point) == nil ? nil : self
    }
    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    private func activate() { if kind == .success { onOpen?() } }
    override func mouseDown(with event: NSEvent) { activate() }
    override func accessibilityPerformPress() -> Bool {
        guard kind == .success else { return false }
        // #687 fix r5: opening replaces this element with the panel. Removing the AX target inside its own action
        // likely made AXPress report kAXErrorFailure, so the press answers first and opens on the next turn.
        Task { @MainActor [weak self] in self?.activate() }
        return true
    }
    override func keyDown(with event: NSEvent) {
        let character = event.charactersIgnoringModifiers
        if kind == .success,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           (character == " " || character == "\r") {
            activate()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor final class RecogniseTextPanelView: NSView, NSTextViewDelegate {
    let titleLabel = NSTextField(labelWithString: String(localized: "Recognised Text"))
    let engineTag = NSTextField(labelWithString: "")
    let closeButton = RecogniseTextKeyButton(frame: .zero)
    let scrollView = NSScrollView(frame: .zero)
    let textView = RecogniseTextEditor(frame: .zero)
    let footerLabel = NSTextField(labelWithString: String(localized: "You can edit before copying again"))
    let copyButton = RecogniseTextKeyButton(frame: .zero)
    var onEdit: ((String) -> Void)?
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    init(text: String, engine: String, onEdit: ((String) -> Void)?, onCopy: (() -> Void)?, onClose: (() -> Void)?) {
        self.onEdit = onEdit; self.onCopy = onCopy; self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 242))
        floatSurface(self, radius: 10)
        setAccessibilityIdentifier("recognise-text.panel")
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Recognised Text"))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = DesignColor.textPrimary.nsColor
        engineTag.stringValue = engine
        engineTag.font = .systemFont(ofSize: 12)
        engineTag.alignment = .center
        engineTag.wantsLayer = true
        engineTag.layer?.cornerRadius = 9
        engineTag.layer?.backgroundColor = DesignColor.hoverBackground.nsColor.cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 6
        closeButton.target = self; closeButton.action = #selector(closePressed)
        closeButton.setAccessibilityIdentifier("recognise-text.close")
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = DesignColor.inputBackground.nsColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 6
        scrollView.layer?.borderColor = DesignColor.divider.nsColor.cgColor
        scrollView.layer?.borderWidth = 1
        textView.isEditable = true
        textView.isSelectable = true
        // #687 fix r5 (F7): plain recognised text with typing undo, and nothing rewritten behind the user's back.
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = DesignColor.textPrimary.nsColor
        textView.backgroundColor = DesignColor.inputBackground.nsColor
        textView.string = text
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.onClose?() }
        textView.setAccessibilityIdentifier("recognise-text.editor")
        scrollView.documentView = textView
        footerLabel.font = .systemFont(ofSize: 12)
        footerLabel.textColor = DesignColor.textSecondary.nsColor
        copyButton.title = String(localized: "Copy")
        copyButton.font = .systemFont(ofSize: 12)
        copyButton.isBordered = false
        copyButton.wantsLayer = true
        copyButton.layer?.cornerRadius = 6
        copyButton.layer?.backgroundColor = DesignColor.primaryFill.nsColor.cgColor
        copyButton.contentTintColor = DesignColor.onPrimary.nsColor
        copyButton.target = self; copyButton.action = #selector(copyPressed)
        copyButton.setAccessibilityIdentifier("recognise-text.copy")
        for child in [titleLabel, engineTag, closeButton, scrollView, footerLabel, copyButton] { addSubview(child) }
        refreshInnerAppearance()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFloatSurface(self)
        refreshInnerAppearance()
    }
    private func refreshInnerAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            engineTag.layer?.backgroundColor = DesignColor.hoverBackground.nsColor.cgColor
            scrollView.layer?.borderColor = DesignColor.divider.nsColor.cgColor
            scrollView.backgroundColor = DesignColor.inputBackground.nsColor
            textView.backgroundColor = DesignColor.inputBackground.nsColor
            copyButton.layer?.backgroundColor = DesignColor.primaryFill.nsColor.cgColor
            copyButton.contentTintColor = DesignColor.onPrimary.nsColor
            titleLabel.textColor = DesignColor.textPrimary.nsColor
            textView.textColor = DesignColor.textPrimary.nsColor
            footerLabel.textColor = DesignColor.textSecondary.nsColor
        }
    }
    override func layout() {
        super.layout()
        let width = bounds.width
        let narrow = width < 260
        let headY = bounds.height - 12 - 26
        titleLabel.frame = NSRect(x: 12, y: headY + 5, width: ceil(titleLabel.intrinsicContentSize.width), height: 16)
        engineTag.frame = NSRect(x: narrow ? 12 : titleLabel.frame.maxX + 8,
                                 y: narrow ? headY - 26 : headY + 4,
                                 width: ceil(engineTag.intrinsicContentSize.width) + 12, height: 18)
        closeButton.frame = NSRect(x: width - 38, y: headY, width: 26, height: 26)
        scrollView.frame = NSRect(x: 12, y: headY - 8 - (narrow ? 26 : 0) - 150,
                                  width: width - 24, height: 150)
        textView.frame.size.width = scrollView.contentSize.width
        textView.minSize = NSSize(width: scrollView.contentSize.width, height: 150)
        textView.maxSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        let buttonWidth = max(48, ceil(copyButton.intrinsicContentSize.width) + 24)
        copyButton.frame = NSRect(x: width - 12 - buttonWidth, y: 12, width: buttonWidth, height: 26)
        footerLabel.maximumNumberOfLines = narrow ? 2 : 1
        footerLabel.usesSingleLineMode = !narrow
        footerLabel.lineBreakMode = narrow ? .byWordWrapping : .byClipping
        footerLabel.frame = NSRect(x: 12, y: narrow ? 44 : 17,
                                   width: narrow ? width - 24 : ceil(footerLabel.intrinsicContentSize.width),
                                   height: narrow ? 32 : 16)
    }
    @objc private func closePressed() { onClose?() }
    @objc private func copyPressed() { onCopy?() }
    func textDidChange(_ notification: Notification) { onEdit?(textView.string) }
    /// #687 fix r5 (F7): the editor's typing undo lives and ends with this panel.
    private let editorUndo = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { editorUndo.removeAllActions() }
    }
    func showCopiedConfirmation(_ copied: Bool) {
        footerLabel.stringValue = copied
            ? String(localized: "Copied") : String(localized: "You can edit before copying again")
        needsLayout = true
    }
}

/// #687 fix r5b (F8): where the floating surface may sit, in the overlay's coordinates. `trailingEdge` is the
/// right edge it keeps 20 pt from (nil: the overlay's own); `obstacles` are the viewer controls it must not cover.
struct RecogniseTextPlacement {
    var trailingEdge: CGFloat?
    var obstacles: [NSRect]
}

/// Transparent across the content except for the active floating surface.
@MainActor final class RecogniseTextOverlay: NSView {
    private(set) var noticeView: RecogniseTextNoticeView?
    private(set) var panelView: RecogniseTextPanelView?
    var onDismiss: (() -> Void)?
    var onNoticeChange: (() -> Void)?
    /// #687 fix r5: runs a removal that takes the first responder with it, so the owner can hand focus on.
    var handOffFocus: ((_ removal: () -> Void) -> Void)?
    private let scheduleDismiss: (TimeInterval, @escaping @MainActor () -> Void) -> Void
    private var dismissalGeneration = UUID()
    /// #687 fix r5b (F9): what holds the notice: the pointer over it, keyboard focus, VoiceOver focus. While any
    /// holds, no dismissal runs; when the last lets go, the 5 s count starts again.
    private enum Hold { case hover, keyboard, accessibility }
    private var holds: Set<Hold> = []
    /// #687 fix r5b (F8): the viewer's controls to keep clear of; nil keeps the plain 20 pt corner.
    var placement: (() -> RecogniseTextPlacement)?
    /// The gap above an obstacle: the design system's 8 pt spacing step.
    static let obstacleGap = CGFloat(DesignMetrics.spacing[1])

    init(frame: NSRect = .zero,
         scheduleDismiss: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { interval, action in
             Task { try? await Task.sleep(for: .seconds(interval)); action() }
         }) {
        self.scheduleDismiss = scheduleDismiss
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func accessibilityChildren() -> [Any]? {
        if let noticeView { return [noticeView] }
        if let panelView { return [panelView] }
        return []
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
    override func layout() {
        super.layout()
        let place = placement?()
        let trailing = place?.trailingEdge ?? bounds.maxX
        if let noticeView {
            noticeView.compactWidth = nil
            let available = max(0, trailing - bounds.minX - 40)
            if noticeView.intrinsicContentSize.width > available { noticeView.compactWidth = available }
            noticeView.frame = surfaceFrame(size: noticeView.intrinsicContentSize, trailing: trailing, place: place)
        }
        if let panelView { panelView.frame = plannedPanelFrame(place: place) }
    }
    /// The panel's frame in the current bounds: up to 380 wide, taller when narrow.
    func plannedPanelFrame() -> NSRect { plannedPanelFrame(place: placement?()) }
    private func plannedPanelFrame(place: RecogniseTextPlacement?) -> NSRect {
        let trailing = place?.trailingEdge ?? bounds.maxX
        let width = max(0, min(380, trailing - bounds.minX - 40))
        return surfaceFrame(size: NSSize(width: width, height: width < 260 ? 300 : 242), trailing: trailing, place: place)
    }
    /// 20 pt from the trailing edge; the bottom edge 20 pt up, or `obstacleGap` above the highest control under it.
    private func surfaceFrame(size: NSSize, trailing: CGFloat, place: RecogniseTextPlacement?) -> NSRect {
        let minX = trailing - 20 - size.width
        let clearTop = (place?.obstacles ?? [])
            .filter { $0.maxX > minX && $0.minX < minX + size.width }
            .map { $0.maxY + Self.obstacleGap }
            .max() ?? 0
        return NSRect(x: minX, y: max(20, clearTop), width: size.width, height: size.height)
    }
    func showNotice(message: String, engine: String?, kind: RecogniseTextNoticeKind, onOpen: (() -> Void)?) {
        clear()
        let view = RecogniseTextNoticeView(message: message, engine: engine, kind: kind, onOpen: onOpen)
        view.onHoverChange = { [weak self] inside in self?.setHold(.hover, inside) }
        view.onFocusChange = { [weak self] keyboard, focused in self?.setHold(keyboard ? .keyboard : .accessibility, focused) }
        addSubview(view)
        noticeView = view
        needsLayout = true
        onNoticeChange?()
        armDismissal()
    }
    func showPanel(text: String, engine: String, onEdit: ((String) -> Void)?, onCopy: (() -> Void)?, onClose: (() -> Void)?) {
        // Notice → panel: the editor takes focus next, so there is no handoff to the canvas in between.
        clear(handingOffFocus: false)
        let view = RecogniseTextPanelView(text: text, engine: engine, onEdit: onEdit, onCopy: onCopy, onClose: onClose)
        addSubview(view)
        panelView = view
        needsLayout = true
        onNoticeChange?()
    }
    func clear() { clear(handingOffFocus: true) }
    private func clear(handingOffFocus: Bool) {
        dismissalGeneration = UUID()
        holds = []
        noticeView?.onHoverChange = nil
        noticeView?.onFocusChange = nil
        let removal = {
            self.noticeView?.removeFromSuperview(); self.noticeView = nil
            self.panelView?.removeFromSuperview(); self.panelView = nil
        }
        if handingOffFocus, holdsFirstResponder, let handOffFocus { handOffFocus(removal) } else { removal() }
        onNoticeChange?()
    }
    /// The first responder is the notice, the panel, or inside one of them (the editor).
    private var holdsFirstResponder: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return [noticeView as NSView?, panelView].contains { $0.map { responder === $0 || responder.isDescendant(of: $0) } ?? false }
    }
    private func setHold(_ hold: Hold, _ on: Bool) {
        guard noticeView != nil, holds.contains(hold) != on else { return }
        if on { holds.insert(hold) } else { holds.remove(hold) }
        dismissalGeneration = UUID()
        if holds.isEmpty { armDismissal() }
    }
    private func armDismissal() {
        let token = dismissalGeneration
        scheduleDismiss(5) { [weak self] in
            guard let self, self.dismissalGeneration == token, self.holds.isEmpty, self.noticeView != nil else { return }
            self.clear()
            self.onDismiss?()
        }
    }
}
