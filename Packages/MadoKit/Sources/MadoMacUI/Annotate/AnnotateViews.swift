import AppKit
import MadoCore
import MadoApplication

/// #690 page 39: the strip's items, top to bottom.
public enum AnnotateStripItem: CaseIterable, Sendable {
    case select, arrow, rectangle, text, highlighter, pen, redact, crop, step, undo, redo, copy, save, done
}

public enum AnnotateStripAction: Equatable, Sendable {
    case tool(AnnotateTool), undo, redo, copy, save, done
}

public struct AnnotateStripState: Equatable, Sendable {
    public var tool: AnnotateTool?
    public var canUndo: Bool, canRedo: Bool, canSave: Bool, canCopy: Bool
    public init(tool: AnnotateTool?, canUndo: Bool, canRedo: Bool, canSave: Bool, canCopy: Bool) {
        self.tool = tool; self.canUndo = canUndo; self.canRedo = canRedo; self.canSave = canSave; self.canCopy = canCopy
    }
}

/// Fixed paints that are not theme tokens.
public enum AnnotatePaint {
    /// Page 39's annotation red #dc2626, the same in both appearances (#680 r1 Q8).
    public static var mark: NSColor { NSColor(srgbRed: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255, alpha: 1) }
    /// `--color-running-text` #16a34a, the same in both appearances; the ✓ of the save confirmation. Not a
    /// DesignColor token: the registry has no running-text entry yet (#690 Still open).
    public static var confirmationTick: NSColor { NSColor(srgbRed: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255, alpha: 1) }
}

// MARK: - Shared drawing

/// A borderless button that paints page 39's fills itself, so cached and live drawing agree.
@MainActor final class AnnotateButton: NSButton {
    enum Style { case tool, text, bordered, primary, icon }
    let style: Style
    /// Tool buttons and 存储 are accent-filled while pressed or primary.
    var filled = false { didSet { if filled != oldValue { refreshTitle(); needsDisplay = true } } }

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isBordered = false
        bezelStyle = .regularSquare
        refusesFirstResponder = true
        imagePosition = .imageOnly
        filled = style == .primary
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { nil }

    override var title: String { didSet { refreshTitle() } }
    override var isEnabled: Bool { didSet { refreshTitle(); needsDisplay = true } }

    func refreshTitle() {
        guard style != .tool, style != .icon, !title.isEmpty else {
            contentTintColor = filled ? DesignColor.onPrimary.nsColor : DesignColor.textPrimary.nsColor
            return
        }
        imagePosition = .noImage
        let color = filled ? DesignColor.onPrimary.nsColor : DesignColor.textPrimary.nsColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: isEnabled ? color : color.withAlphaComponent(0.35), .paragraphStyle: paragraph])
        if attributedTitle != attributed { attributedTitle = attributed }
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
            if filled {
                DesignColor.primaryFill.nsColor.withAlphaComponent(isEnabled ? 1 : 0.35).setFill()
                shape.fill()
            } else if style == .bordered {
                DesignColor.canvasBackground.nsColor.setFill()
                shape.fill()
                let inset = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5.5, yRadius: 5.5)
                DesignColor.divider.nsColor.setStroke()
                inset.lineWidth = 1
                inset.stroke()
            }
        }
        super.draw(dirtyRect)
    }
}

/// Docks `view` in its superview at `frame`, given in top-left points, whatever the superview's flippedness.
@MainActor private func place(_ view: NSView, topLeft frame: CGRect) {
    guard let superview = view.superview else { return }
    var placed = frame
    if !superview.isFlipped { placed.origin.y = superview.bounds.height - frame.maxY }
    if view.frame != placed { view.frame = placed }
}

/// The docked views re-place themselves whenever their superview's frame changes; AppKit does not call
/// `resize(withOldSuperviewSize:)` for every container (a window's content view under Auto Layout).
@MainActor private func follow(_ view: NSView, _ selector: Selector) {
    guard let superview = view.superview else { return }
    superview.postsFrameChangedNotifications = true
    NotificationCenter.default.addObserver(view, selector: selector, name: NSView.frameDidChangeNotification, object: superview)
}

@MainActor private func stopFollowing(_ view: NSView) {
    NotificationCenter.default.removeObserver(view, name: NSView.frameDidChangeNotification, object: nil)
}

@MainActor private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private func panelBackground(_ view: NSView) {
    view.wantsLayer = true
    view.shadow = {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        return shadow
    }()
}

// MARK: - Strip

/// Page 39's vertical tool strip, docked on the right edge of its superview: 48 wide, 12 from the right, centred
/// vertically, at most 24 shorter than the superview; its content scrolls when the window is short (B2, B8).
@MainActor public final class AnnotateStripView: NSView {
    public var onAction: ((AnnotateStripAction) -> Void)?
    public let scrollView = NSScrollView()
    public private(set) var separators: [NSView] = []
    private var buttons: [AnnotateStripItem: AnnotateButton] = [:]
    private var state = AnnotateStripState(tool: nil, canUndo: false, canRedo: false, canSave: false, canCopy: false)

    static let width: CGFloat = 48
    static let contentHeight: CGFloat = 508
    private static let tools: [AnnotateStripItem] = [.select, .arrow, .rectangle, .text, .highlighter, .pen, .redact,
                                                     .crop, .step, .undo, .redo]
    private static let unimplemented: Set<AnnotateStripItem> = [.arrow, .text, .highlighter, .pen, .redact, .crop, .step]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        panelBackground(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel(String(localized: "Annotation Tools"))
        setAccessibilityIdentifier("annotate.strip")

        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.contentHeight))
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = document
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)

        // 4 padding, then items with 2 between; a separator is 1 tall with 4 above and below (page 39 CSS).
        var y: CGFloat = 4
        func separator() {
            y += 4
            let line = SeparatorView(frame: NSRect(x: 12, y: y, width: 24, height: 1))
            document.addSubview(line)
            separators.append(line)
            y += 1 + 4 + 2
        }
        for item in AnnotateStripItem.allCases {
            let text = [.copy, .save, .done].contains(item)
            let button = AnnotateButton(style: text ? (item == .save ? .primary : .text) : .tool)
            button.frame = text ? NSRect(x: 4, y: y, width: 40, height: 26) : NSRect(x: 8, y: y, width: 32, height: 32)
            y += button.frame.height + 2
            configure(button, item)
            buttons[item] = button
            document.addSubview(button)
            if [.select, .step, .redo, .save].contains(item) { separator() }
        }
        update(state)
    }
    required init?(coder: NSCoder) { nil }

    public func button(_ item: AnnotateStripItem) -> NSButton { buttons[item]! }

    private func configure(_ button: AnnotateButton, _ item: AnnotateStripItem) {
        let name = Self.name(item)
        button.setAccessibilityLabel(name)
        button.toolTip = Self.shortcut(item).map { "\(name) \($0)" } ?? name
        button.target = self
        button.action = #selector(clicked(_:))
        if button.style == .tool {
            button.image = NSImage(systemSymbolName: Self.symbol(item), accessibilityDescription: name)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
            button.image?.isTemplate = true
        } else {
            button.title = name
        }
    }

    static func name(_ item: AnnotateStripItem) -> String {
        switch item {
        case .select: String(localized: "Select")
        case .arrow: String(localized: "Arrow")
        case .rectangle: String(localized: "Rectangle")
        case .text: String(localized: "Text")
        case .highlighter: String(localized: "Highlighter")
        case .pen: String(localized: "Pen")
        case .redact: String(localized: "Redact")
        case .crop: String(localized: "Crop")
        case .step: String(localized: "Step")
        case .undo: String(localized: "Undo")
        case .redo: String(localized: "Redo")
        case .copy: String(localized: "Copy")
        case .save: String(localized: "Save")
        case .done: String(localized: "Done")
        }
    }

    /// Only keys Mado handles get a letter; the tools of #692/#693 show their bare name.
    private static func shortcut(_ item: AnnotateStripItem) -> String? {
        switch item {
        case .select: "V"
        case .rectangle: "R"
        case .undo: "⌘Z"
        case .redo: "⇧⌘Z"
        case .copy: "⌘C"
        case .save: "⌘S"
        case .done: "Esc"
        default: nil
        }
    }

    private static func symbol(_ item: AnnotateStripItem) -> String {
        switch item {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .text: "textformat"
        case .highlighter: "highlighter"
        case .pen: "pencil.tip"
        case .redact: "checkerboard.rectangle"
        case .crop: "crop"
        case .step: "1.circle"
        case .undo: "arrow.uturn.backward"
        default: "arrow.uturn.forward"
        }
    }

    /// Unimplemented tools stay disabled and are not labelled 「即将推出」 (#690 addendum).
    public func update(_ state: AnnotateStripState) {
        self.state = state
        for (item, button) in buttons {
            switch item {
            case .select: button.isEnabled = true; setPressed(button, state.tool == .select)
            case .rectangle: button.isEnabled = true; setPressed(button, state.tool == .rectangle)
            case .undo: button.isEnabled = state.canUndo
            case .redo: button.isEnabled = state.canRedo
            case .copy: button.isEnabled = state.canCopy
            case .save: button.isEnabled = state.canSave
            case .done: button.isEnabled = true
            default: button.isEnabled = false; setPressed(button, false)
            }
        }
    }

    private func setPressed(_ button: AnnotateButton, _ pressed: Bool) {
        button.state = pressed ? .on : .off
        button.filled = pressed
        button.setAccessibilityValue(pressed)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard sender.isEnabled, let item = buttons.first(where: { $0.value === sender })?.key,
              !Self.unimplemented.contains(item) else { return }
        update(state)
        let action: AnnotateStripAction = switch item {
        case .select: .tool(.select)
        case .rectangle: .tool(.rectangle)
        case .undo: .undo
        case .redo: .redo
        case .copy: .copy
        case .save: .save
        default: .done
        }
        onAction?(action)
    }

    /// The strip's frame in a top-left container of `size`.
    public static func frame(in size: CGSize) -> CGRect {
        let height = max(0, min(contentHeight, size.height - 24))
        return CGRect(x: size.width - 12 - width, y: (size.height - height) / 2, width: width, height: height)
    }

    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        stopFollowing(self)
        super.viewWillMove(toSuperview: newSuperview)
    }
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        follow(self, #selector(superviewFrameChanged))
        dock()
    }
    @objc private func superviewFrameChanged() { dock() }
    public override func resize(withOldSuperviewSize oldSize: NSSize) { dock() }

    private func dock() {
        guard let superview else { return }
        place(self, topLeft: Self.frame(in: superview.bounds.size))
    }

    public override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            DesignColor.popoverBackground.nsColor.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
    }

    private final class SeparatorView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                DesignColor.divider.nsColor.setFill()
                bounds.fill()
            }
        }
    }
}

// MARK: - Marks

/// Draws the marks over the canvas and turns drags into rectangles and clicks into selections. View points are
/// top-left; `transform` maps image pixels to them.
@MainActor public final class AnnotationOverlayView: NSView {
    public var isActive = false
    public var marks: [AnnotationMark] = [] { didSet { if marks != oldValue { needsDisplay = true } } }
    public var selectedMark: Int? { didSet { if selectedMark != oldValue { needsDisplay = true } } }
    public var tool: AnnotateTool?
    public var transform: CanvasTransform? { didSet { needsDisplay = true } }
    public var imageSize: CGSize = .zero
    public var onAddMark: ((AnnotationMark) -> Void)?
    public var onSelect: ((Int?) -> Void)?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    /// Inactive, every event passes through to the canvas.
    public override func hitTest(_ point: NSPoint) -> NSView? { isActive ? super.hitTest(point) : nil }

    private var pointsPerImagePixel: Double {
        guard let transform else { return 1 }
        return transform.zoom / transform.backingScale
    }

    private func viewRect(_ rect: CGRect, _ transform: CanvasTransform) -> CGRect {
        let a = transform.imageToView(rect.origin), b = transform.imageToView(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let transform else { return }
        let scale = pointsPerImagePixel
        for mark in marks {
            let path = NSBezierPath(rect: viewRect(mark.rect, transform))
            path.lineWidth = mark.style.lineWidth * scale
            NSColor(srgbRed: mark.style.red, green: mark.style.green, blue: mark.style.blue, alpha: 1).setStroke()
            path.stroke()
        }
        if let selectedMark, marks.indices.contains(selectedMark) {
            let mark = marks[selectedMark]
            let outset = mark.style.lineWidth * scale / 2 + 2
            let path = NSBezierPath(rect: viewRect(mark.rect, transform).insetBy(dx: -outset, dy: -outset))
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            effectiveAppearance.performAsCurrentDrawingAppearance { DesignColor.accent.nsColor.setStroke() }
            path.stroke()
        }
        if tool == .rectangle, let dragStart, let dragCurrent,
           let rect = AnnotationGeometry.rect(from: dragStart, to: dragCurrent, transform: transform, imageSize: imageSize) {
            let path = NSBezierPath(rect: viewRect(rect, transform))
            path.lineWidth = AnnotationStyle.screenLineWidth
            AnnotatePaint.mark.setStroke()
            path.stroke()
        }
    }

    public override func mouseDown(with event: NSEvent) {
        guard isActive, transform != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragStart = point
        dragCurrent = point
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isActive, dragStart != nil else { return }
        dragCurrent = convert(event.locationInWindow, from: nil)
        if tool == .rectangle { needsDisplay = true }
    }

    public override func mouseUp(with event: NSEvent) {
        guard isActive, let start = dragStart, let transform else { return }
        let end = convert(event.locationInWindow, from: nil)
        dragStart = nil
        dragCurrent = nil
        needsDisplay = true
        switch tool {
        case .rectangle:
            guard let rect = AnnotationGeometry.rect(from: start, to: end, transform: transform, imageSize: imageSize)
            else { return }
            onAddMark?(AnnotationMark(rect: rect, style: .forScreen(pointsPerImagePixel: pointsPerImagePixel)))
        case .select:
            onSelect?(AnnotationGeometry.hitTest(transform.viewToImage(end), marks: marks))
        case nil:
            return
        }
    }
}

// MARK: - ⌘S confirmation

/// 「已存储为 <name>」 with 在访达中显示 and a close button: 36 tall, 12 below the top, centred over the image area
/// (the superview minus the strip's 64) (B9).
@MainActor public final class AnnotateSaveConfirmationView: NSView {
    public let fileName: String
    public let messageField = NSTextField(labelWithString: "")
    public let tick = NSImageView()
    public let revealButton: NSButton = AnnotateButton(style: .bordered)
    public let closeButton: NSButton = AnnotateButton(style: .icon)
    public var onReveal: (() -> Void)?
    public var onClose: (() -> Void)?

    public init(fileName: String) {
        self.fileName = fileName
        super.init(frame: .zero)
        panelBackground(self)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("annotate.saved")
        tick.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        tick.contentTintColor = AnnotatePaint.confirmationTick
        messageField.stringValue = String(format: String(localized: "Saved as %@"), fileName)
        messageField.font = NSFont.systemFont(ofSize: 12)
        messageField.textColor = DesignColor.textPrimary.nsColor
        revealButton.title = String(localized: "Show in Finder")
        revealButton.target = self
        revealButton.action = #selector(reveal)
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        closeButton.setAccessibilityLabel(String(localized: "Close"))
        closeButton.target = self
        closeButton.action = #selector(close)
        (closeButton as? AnnotateButton)?.refreshTitle()
        for view in [tick, messageField, revealButton, closeButton] { addSubview(view) }
        let message = messageField.intrinsicContentSize.width.rounded(.up)
        let reveal = ((revealButton.attributedTitle.size().width) + 24).rounded(.up)
        // padding 6 6 6 12, gap 10 (page 39 CSS).
        tick.frame = NSRect(x: 12, y: 10, width: 16, height: 16)
        messageField.frame = NSRect(x: tick.frame.maxX + 10, y: (36 - messageField.intrinsicContentSize.height) / 2,
                                    width: message, height: messageField.intrinsicContentSize.height)
        revealButton.frame = NSRect(x: messageField.frame.maxX + 10, y: 6, width: reveal, height: 24)
        closeButton.frame = NSRect(x: revealButton.frame.maxX + 10, y: 6, width: 24, height: 24)
        setFrameSize(NSSize(width: closeButton.frame.maxX + 6, height: 36))
    }
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    @objc private func reveal() { onReveal?() }
    @objc private func close() { onClose?() }

    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        stopFollowing(self)
        super.viewWillMove(toSuperview: newSuperview)
    }
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        follow(self, #selector(superviewFrameChanged))
        dock()
    }
    @objc private func superviewFrameChanged() { dock() }
    public override func resize(withOldSuperviewSize oldSize: NSSize) { dock() }

    private func dock() {
        guard let superview else { return }
        let width = frame.width
        let centre = ((superview.bounds.width - 64) / 2).rounded()
        place(self, topLeft: CGRect(x: centre - width / 2, y: 12, width: width, height: 36))
    }

    public override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            DesignColor.popoverBackground.nsColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        }
    }
}

// MARK: - Unsaved-marks sheet

/// The unsaved-marks sheet: a scrim over the whole window and a 400-wide panel attached to the top, centred (B10).
/// The scrim takes every click, so nothing behind the sheet responds while it is up.
@MainActor public final class AnnotateLeaveSheetView: NSView {
    public let scrim: NSView = ScrimView()
    public let panel: NSView = SheetPanelView()
    public let titleField = NSTextField(labelWithString: "")
    public let bodyField = NSTextField(wrappingLabelWithString: "")
    public let discardButton: NSButton = AnnotateButton(style: .bordered)
    public let cancelButton: NSButton = AnnotateButton(style: .bordered)
    public let saveButton: NSButton = AnnotateButton(style: .primary)
    public var onChoice: ((AnnotateLeaveChoice) -> Void)?

    public init(originalName: String, plannedName: String) {
        super.init(frame: .zero)
        setAccessibilityIdentifier("annotate.leave-sheet")
        panelBackground(panel)
        panel.setAccessibilityElement(true)
        panel.setAccessibilityRole(.sheet)
        panel.setAccessibilityLabel(String(format: String(localized: "Save the annotations on “%@”?"), originalName))
        titleField.stringValue = String(format: String(localized: "Save the annotations on “%@”?"), originalName)
        titleField.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleField.textColor = DesignColor.textPrimary.nsColor
        titleField.lineBreakMode = .byTruncatingMiddle
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        bodyField.attributedStringValue = NSAttributedString(
            string: String(format: String(localized: "Save keeps the original unchanged and saves a copy as %@. Don't Save discards these marks."),
                           plannedName),
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DesignColor.textSecondary.nsColor,
                         .paragraphStyle: paragraph])
        discardButton.title = String(localized: "Don't Save")
        cancelButton.title = String(localized: "Cancel")
        saveButton.title = String(localized: "Save")
        cancelButton.keyEquivalent = "\u{1b}"
        saveButton.keyEquivalent = "\r"
        for button in [discardButton, cancelButton, saveButton] {
            button.target = self
            button.action = #selector(choose(_:))
            panel.addSubview(button)
        }
        panel.addSubview(titleField)
        panel.addSubview(bodyField)
        addSubview(scrim)
        addSubview(panel)
        layoutPanel()
    }
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    @objc private func choose(_ sender: NSButton) {
        let choice: AnnotateLeaveChoice = sender === saveButton ? .save : sender === cancelButton ? .cancel : .discard
        onChoice?(choice)
    }

    /// Padding 18 20 16, gap 8, the actions 8 further down (page 39 CSS).
    private func layoutPanel() {
        let inner: CGFloat = 400 - 40
        let titleHeight = titleField.intrinsicContentSize.height.rounded(.up)
        titleField.frame = NSRect(x: 20, y: 18, width: inner, height: titleHeight)
        let bodyHeight = bodyField.attributedStringValue.boundingRect(with: NSSize(width: inner, height: 1000),
            options: [.usesLineFragmentOrigin]).height.rounded(.up)
        bodyField.preferredMaxLayoutWidth = inner
        bodyField.frame = NSRect(x: 20, y: titleField.frame.maxY + 8, width: inner, height: bodyHeight)
        let actions = bodyField.frame.maxY + 16
        func width(_ button: NSButton) -> CGFloat { (button.attributedTitle.size().width + 24).rounded(.up) }
        discardButton.frame = NSRect(x: 20, y: actions, width: width(discardButton), height: 28)
        saveButton.frame = NSRect(x: 400 - 20 - width(saveButton), y: actions, width: width(saveButton), height: 28)
        cancelButton.frame = NSRect(x: saveButton.frame.minX - 8 - width(cancelButton), y: actions,
                                    width: width(cancelButton), height: 28)
        panel.setFrameSize(NSSize(width: 400, height: actions + 28 + 16))
    }

    public override func viewWillMove(toSuperview newSuperview: NSView?) {
        stopFollowing(self)
        super.viewWillMove(toSuperview: newSuperview)
    }
    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        follow(self, #selector(superviewFrameChanged))
        fill()
    }
    @objc private func superviewFrameChanged() { fill() }
    public override func resize(withOldSuperviewSize oldSize: NSSize) { fill() }

    private func fill() {
        guard let superview else { return }
        frame = superview.bounds
        scrim.frame = bounds
        panel.setFrameOrigin(NSPoint(x: ((bounds.width - 400) / 2).rounded(), y: 0))
    }

    /// Square at the top where it meets the title bar, 12 rounded at the bottom (page 39 CSS).
    private final class SheetPanelView: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                DesignColor.popoverBackground.nsColor.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
                NSRect(x: 0, y: 0, width: bounds.width, height: min(12, bounds.height)).fill()
            }
        }
    }

    private final class ScrimView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            DesignColor.scrim.nsColor.setFill()
            bounds.fill()
        }
        override func mouseDown(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
    }
}
