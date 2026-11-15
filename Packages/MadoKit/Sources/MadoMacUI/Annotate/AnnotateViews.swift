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
    /// `--color-running-text` #16a34a, the same in both appearances; the ✓ of the save confirmation. Not a
    /// DesignColor token: the registry has no running-text entry yet (#690 Still open).
    public static var confirmationTick: NSColor { NSColor(srgbRed: 22.0 / 255, green: 163.0 / 255, blue: 74.0 / 255, alpha: 1) }

    /// #693 annotate.html:95 `.reversible-hint`: color-mix(in srgb, --color-banner-unsaved 75%, --color-text). The banner
    /// colour #f59e0b is the registry's `waitingIndicator`; the mix follows the appearance's text colour.
    public static var redactionHint: NSColor {
        NSColor(name: nil) { appearance in
            let theme: DesignTheme = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
            let banner = DesignColor.waitingIndicator.components(theme), text = DesignColor.textPrimary.components(theme)
            func mix(_ i: Int) -> CGFloat { banner[i] * 0.75 + text[i] * 0.25 }
            return NSColor(srgbRed: mix(0), green: mix(1), blue: mix(2), alpha: 1)
        }
    }
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

    /// #693: the vertical centre of `item` in the strip's own top-left points, after scrolling.
    public func centreY(of item: AnnotateStripItem) -> CGFloat {
        buttons[item]!.frame.midY - scrollView.contentView.bounds.minY
    }

    private func configure(_ button: AnnotateButton, _ item: AnnotateStripItem) {
        let name = Self.name(item)
        button.setAccessibilityLabel(name)
        button.toolTip = "\(name) \(Self.shortcut(item))"
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

    /// Every item's key (#693 added M and C).
    private static func shortcut(_ item: AnnotateStripItem) -> String {
        switch item {
        case .select: "V"
        case .arrow: "A"
        case .rectangle: "R"
        case .text: "T"
        case .highlighter: "H"
        case .pen: "P"
        case .redact: "M"
        case .crop: "C"
        case .step: "N"
        case .undo: "⌘Z"
        case .redo: "⇧⌘Z"
        case .copy: "⌘C"
        case .save: "⌘S"
        case .done: "Esc"
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

    /// Every tool is enabled since #693.
    public func update(_ state: AnnotateStripState) {
        self.state = state
        for (item, button) in buttons {
            if let tool = Self.tool(item) {
                button.isEnabled = true
                setPressed(button, state.tool == tool)
                continue
            }
            switch item {
            case .undo: button.isEnabled = state.canUndo
            case .redo: button.isEnabled = state.canRedo
            case .copy: button.isEnabled = state.canCopy
            case .save: button.isEnabled = state.canSave
            default: button.isEnabled = true // 完成
            }
        }
    }

    private static func tool(_ item: AnnotateStripItem) -> AnnotateTool? {
        switch item {
        case .select: .select
        case .arrow: .arrow
        case .rectangle: .rectangle
        case .text: .text
        case .highlighter: .highlighter
        case .pen: .pen
        case .redact: .redact
        case .crop: .crop
        case .step: .step
        default: nil
        }
    }

    private func setPressed(_ button: AnnotateButton, _ pressed: Bool) {
        button.state = pressed ? .on : .off
        button.filled = pressed
        button.setAccessibilityValue(pressed)
    }

    @objc private func clicked(_ sender: NSButton) {
        guard sender.isEnabled, let item = buttons.first(where: { $0.value === sender })?.key else { return }
        update(state)
        let action: AnnotateStripAction = if let tool = Self.tool(item) { .tool(tool) } else {
            switch item {
            case .undo: .undo
        case .redo: .redo
        case .copy: .copy
            case .save: .save
            default: .done
            }
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

/// Draws the marks over the canvas through the copy's renderer, so screen and copy look the same (#692), and turns
/// drags and clicks into marks, selections, moves, resizes and text. View points are top-left; `transform` maps image
/// pixels to them.
@MainActor public final class AnnotationOverlayView: NSView, NSTextFieldDelegate {
    public var isActive = false
    public var marks: [AnnotationMark] = [] { didSet { if marks != oldValue { needsDisplay = true } } }
    public var selectedMark: Int? { didSet { if selectedMark != oldValue { needsDisplay = true } } }
    /// Changing the tool drops a drag in progress and ends text editing (#692).
    public var tool: AnnotateTool? {
        didSet {
            guard tool != oldValue else { return }
            cancelDrag()
            commitText()
        }
    }
    public var transform: CanvasTransform? { didSet { needsDisplay = true; placeTextEditor() } }
    public var imageSize: CGSize = .zero
    public var onAddMark: ((AnnotationMark) -> Void)?
    public var onSelect: ((Int?) -> Void)?
    /// #692: a move or resize of mark `index`, once on mouse-up; a plain click never calls it.
    public var onReplace: ((Int, AnnotationMark) -> Void)?
    /// #692: text editing ended: the edited mark's index (nil for a new one), the text, the origin (image pixels)
    /// and the style for a new mark.
    public var onCommitText: ((Int?, String, CGPoint, AnnotationStyle) -> Void)?
    /// #692 fix r1: the typed text changed (the window refreshes 存储).
    public var onTextChange: (() -> Void)?
    /// #692 fix r1: a mark's accessibility 删除 action.
    public var onDelete: ((Int) -> Void)?
    public private(set) var textEditor: NSTextField?
    public var isEditingText: Bool { editing != nil }
    /// The text mark being edited (hidden while its field is up); nil for a new one or none.
    public var editingMark: Int? { editing?.index }
    public var isDragging: Bool { drag != nil }

    /// #693: the upright original the copy is flattened from; redactions show the copy's pixels once it is set.
    public struct RedactionSource: @unchecked Sendable {
        public let image: CGImage
        public let orientation: Int
        public init(image: CGImage, orientation: Int) { self.image = image; self.orientation = orientation }
    }
    public var redactionSource: RedactionSource? { didSet { patches = [:]; needsDisplay = true } }
    /// #693: the style a new redaction is drawn with.
    public var redactionStyle: RedactionStyle = .mosaic(strength: RedactionStyle.defaultMosaicStrength)
    /// #693: the applied crop and the one being adjusted with the crop tool (image pixels). Outside the shown crop the
    /// image is dimmed 25% black inside a 1 pt white border (#683's look; no page pins the crop).
    public var crop: CGRect? { didSet { if crop != oldValue { needsDisplay = true } } }
    public var pendingCrop: CGRect? { didSet { if pendingCrop != oldValue { needsDisplay = true } } }
    /// #693: the crop tool's drag, handle or move released, once on mouse-up.
    public var onCropChange: ((CGRect) -> Void)?

    private enum Drag {
        /// A rectangle, arrow, highlighter or pen: every sample, in view points.
        case create(AnnotateTool, [CGPoint])
        case move(Int, from: CGPoint, original: AnnotationMark)
        case resize(Int, AnnotationHandle, original: AnnotationMark)
        /// Select on empty canvas, a step marker or a text click: acts on mouse-up.
        case click
        /// #693 the crop tool.
        case crop(CropDrag)
    }
    /// A new crop from a point, a handle of the shown crop, or a move of it (view points).
    private enum CropDrag {
        case create(CGPoint)
        case resize(AnnotationHandle, original: CGRect)
        case move(from: CGPoint, original: CGRect)
    }
    /// The crop a crop-tool drag would report now.
    private var cropPreview: CGRect?
    /// #693: each redaction's copy pixels, kept while the marks up to it and the source stay the same.
    private var patches: [Int: (marks: [AnnotationMark], patch: AnnotationFlattener.RedactionPatch)] = [:]
    private var drag: Drag?
    /// What the drag would commit now: a replacement for `index`, or a new mark.
    private var preview: (index: Int?, mark: AnnotationMark)?
    private var editing: (index: Int?, origin: CGPoint, style: AnnotationStyle)?

    private static let handleSize: CGFloat = 7
    private static let handleReach: CGFloat = 6

    /// One accessibility element per mark, kept while the mark count stays, so VoiceOver keeps its place (#692 fix r1).
    private var markElements: [AnnotationMarkElement] = []

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Annotations"))
    }
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    /// Only the image takes clicks (#690 fix r1): inactive, or outside the image, every event passes through to the
    /// canvas and the window's other views (the Inspector, the strip).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isActive, let transform else { return nil }
        let image = viewRect(CGRect(origin: .zero, size: imageSize), transform)
        let local = convert(point, from: superview)
        if let textEditor, textEditor.frame.contains(local) { return super.hitTest(point) }
        return image.contains(local) ? super.hitTest(point) : nil
    }

    private var pointsPerImagePixel: Double {
        guard let transform else { return 1 }
        return transform.zoom / transform.backingScale
    }

    private var screenStyle: AnnotationStyle { .forScreen(pointsPerImagePixel: pointsPerImagePixel) }

    fileprivate func viewRect(_ rect: CGRect, _ transform: CanvasTransform) -> CGRect {
        let a = transform.imageToView(rect.origin), b = transform.imageToView(CGPoint(x: rect.maxX, y: rect.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    // MARK: Accessibility

    /// The text field while typing, then one element per completed mark, in drawing order.
    public override func accessibilityChildren() -> [Any]? {
        let kept = markElements.prefix(marks.count)
        markElements = Array(kept) + (kept.count..<marks.count).map { AnnotationMarkElement(overlay: self, index: $0) }
        return Array([super.accessibilityChildren()].compactMap { $0 }.joined()) + markElements
    }

    public override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityChildren()?.filter { ($0 as? AnnotationMarkElement)?.isAccessibilitySelected() == true }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        guard let transform, let context = NSGraphicsContext.current?.cgContext else { return }
        var shown = marks
        if let preview {
            if let index = preview.index, shown.indices.contains(index) { shown[index] = preview.mark }
            else if preview.index == nil { shown.append(preview.mark) }
        }
        let scale = pointsPerImagePixel
        context.saveGState()
        // The copy ends at the bitmap edge, so the screen does too (#692 fix r1); the selection chrome is not clipped.
        context.clip(to: viewRect(CGRect(origin: .zero, size: imageSize), transform))
        context.translateBy(x: transform.origin.x, y: transform.origin.y)
        context.scaleBy(x: scale, y: scale)
        var redactions = shown.indices.filter { shown[$0].kind == .redaction }[...]
        AnnotationRenderer.draw(shown, in: context, hiding: editing?.index) { [self] mark in
            guard let index = redactions.popFirst() else { return }
            drawRedaction(mark, at: index, of: shown, in: context)
        }
        context.restoreGState()
        drawCrop(transform)

        guard let selectedMark, shown.indices.contains(selectedMark), selectedMark != editing?.index else { return }
        let mark = shown[selectedMark]
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let outset = AnnotationMetrics.drawnWidth(mark) * scale / 2 + 2
            let outline = NSBezierPath(rect: viewRect(mark.rect, transform).insetBy(dx: -outset, dy: -outset))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            DesignColor.accent.nsColor.setStroke()
            outline.stroke()
            for handle in AnnotationGeometry.handles(for: mark.kind) {
                let centre = transform.imageToView(AnnotationGeometry.handlePoint(handle, of: mark))
                let size = Self.handleSize
                let square = NSBezierPath(rect: CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size))
                NSColor.white.setFill()
                square.fill()
                square.lineWidth = 1
                DesignColor.accent.nsColor.setStroke()
                square.stroke()
            }
        }
    }

    /// The copy's pixels for a redaction once the source is decoded, else opaque black: the screen never shows what a
    /// redaction hides. While a drag changes marks before it, the last patch stays (its area does not move); while the
    /// redaction itself is dragged it is black.
    private func drawRedaction(_ mark: AnnotationMark, at index: Int, of shown: [AnnotationMark], in context: CGContext) {
        let prefix = Array(shown[...index])
        var patch = patches[index].flatMap { $0.marks == prefix ? $0.patch : nil }
        if patch == nil, let source = redactionSource {
            if preview == nil {
                patch = try? AnnotationFlattener.redactionPatch(source.image, orientation: source.orientation, marks: prefix,
                                                               index: index)
                if let patch { patches[index] = (prefix, patch) }
            } else if let cached = patches[index], cached.marks.last == mark {
                patch = cached.patch
            }
        }
        context.saveGState()
        if let patch {
            context.interpolationQuality = .none
            context.translateBy(x: patch.area.minX, y: patch.area.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(patch.image, in: CGRect(origin: .zero, size: patch.area.size))
        } else {
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(mark.rect.integral.intersection(CGRect(origin: .zero, size: imageSize)))
        }
        context.restoreGState()
    }

    /// The crop the overlay shows: the crop tool's drag, else with the crop tool the pending crop, else the applied one.
    private var shownCrop: CGRect? { cropPreview ?? (tool == .crop ? pendingCrop ?? crop : crop) }

    private func drawCrop(_ transform: CanvasTransform) {
        guard let crop = shownCrop else { return }
        let image = viewRect(CGRect(origin: .zero, size: imageSize), transform), box = viewRect(crop, transform)
        let dim = NSBezierPath(rect: image)
        dim.append(NSBezierPath(rect: box))
        dim.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.25).setFill()
        dim.fill()
        // A 1 pt white border just outside the crop, on whole points.
        let snapped = CGRect(x: box.minX.rounded(.down), y: box.minY.rounded(.down),
                             width: box.maxX.rounded(.down) - box.minX.rounded(.down),
                             height: box.maxY.rounded(.down) - box.minY.rounded(.down))
        let border = NSBezierPath(rect: snapped.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
        guard tool == .crop else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            for handle in AnnotationGeometry.handles(for: .rectangle) {
                let centre = transform.imageToView(AnnotationGeometry.handlePoint(handle, of: AnnotationMark(rect: crop)))
                let size = Self.handleSize
                let square = NSBezierPath(rect: CGRect(x: centre.x - size / 2, y: centre.y - size / 2, width: size, height: size))
                NSColor.white.setFill()
                square.fill()
                square.lineWidth = 1
                DesignColor.accent.nsColor.setStroke()
                square.stroke()
            }
        }
    }

    // MARK: Mouse

    public override func mouseDown(with event: NSEvent) {
        guard isActive, let transform, let tool else { return }
        // A click while typing only ends the typing (#692 O12).
        if commitText() { return }
        let point = convert(event.locationInWindow, from: nil)
        switch tool {
        case .select:
            if let selectedMark, marks.indices.contains(selectedMark),
               let handle = handle(at: point, of: marks[selectedMark], transform) {
                drag = .resize(selectedMark, handle, original: marks[selectedMark])
            } else if let hit = AnnotationGeometry.hitTest(transform.viewToImage(point), marks: marks) {
                drag = .move(hit, from: point, original: marks[hit])
            } else {
                drag = .click
            }
        case .rectangle, .arrow, .highlighter, .pen, .redact:
            drag = .create(tool, [point])
        case .crop:
            if let shown = pendingCrop ?? crop {
                let box = AnnotationMark(rect: shown)
                if let handle = handle(at: point, of: box, transform) {
                    drag = .crop(.resize(handle, original: shown))
                } else if viewRect(shown, transform).contains(point) {
                    drag = .crop(.move(from: point, original: shown))
                } else {
                    drag = .crop(.create(point))
                }
            } else {
                drag = .crop(.create(point))
            }
        case .text, .step:
            drag = .click
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard isActive, let drag, let transform else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch drag {
        case .create(let tool, var points):
            points.append(point)
            self.drag = .create(tool, points)
            preview = candidate(tool, points, transform).map { (nil, $0) }
        case .move(let index, let start, let original):
            preview = (index, moved(original, from: start, to: point))
        case .resize(let index, let handle, let original):
            preview = (index, AnnotationGeometry.resize(original, handle: handle, to: transform.viewToImage(point),
                                                        imageSize: imageSize))
        case .click:
            return
        case .crop(let crop):
            cropPreview = cropped(crop, to: point, transform)
        }
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        guard isActive, let drag, let transform else { return }
        let end = convert(event.locationInWindow, from: nil)
        self.drag = nil
        preview = nil
        cropPreview = nil
        needsDisplay = true
        switch drag {
        case .crop(let drag):
            if let rect = cropped(drag, to: end, transform), rect != pendingCrop ?? crop { onCropChange?(rect) }
        case .create(let tool, var points):
            if points.last != end { points.append(end) }
            if let mark = candidate(tool, points, transform) { onAddMark?(mark) }
        case .move(let index, let start, let original):
            let mark = moved(original, from: start, to: end)
            if mark == original { onSelect?(index) } else { onReplace?(index, mark) }
        case .resize(let index, let handle, let original):
            let mark = AnnotationGeometry.resize(original, handle: handle, to: transform.viewToImage(end), imageSize: imageSize)
            if mark != original { onReplace?(index, mark) }
        case .click:
            switch tool {
            case .step:
                onAddMark?(AnnotationGeometry.step(at: end, transform: transform, imageSize: imageSize, style: screenStyle))
            case .text:
                if let hit = AnnotationGeometry.hitTest(transform.viewToImage(end), marks: marks), marks[hit].kind == .text {
                    let mark = marks[hit]
                    beginEditing(index: hit, text: mark.text, origin: mark.anchor, style: mark.style)
                } else {
                    beginEditing(index: nil, text: "", origin: transform.viewToImage(end), style: screenStyle)
                }
            default:
                onSelect?(AnnotationGeometry.hitTest(transform.viewToImage(end), marks: marks))
            }
        }
    }

    /// Drops the drag in progress: no mark, no replace on mouse-up. False when there was none.
    @discardableResult public func cancelDrag() -> Bool {
        guard drag != nil else { return false }
        drag = nil
        preview = nil
        cropPreview = nil
        needsDisplay = true
        return true
    }

    private func candidate(_ tool: AnnotateTool, _ points: [CGPoint], _ transform: CanvasTransform) -> AnnotationMark? {
        guard let first = points.first, let last = points.last else { return nil }
        switch tool {
        case .rectangle:
            return AnnotationGeometry.rect(from: first, to: last, transform: transform, imageSize: imageSize)
                .map { AnnotationMark(rect: $0, style: screenStyle) }
        case .arrow:
            return AnnotationGeometry.arrow(from: first, to: last, transform: transform, imageSize: imageSize, style: screenStyle)
        case .redact:
            return AnnotationGeometry.rect(from: first, to: last, transform: transform, imageSize: imageSize)
                .map { .redaction(rect: $0, style: redactionStyle) }
        default:
            // Only rectangle, arrow, highlighter and pen start a `.create` drag (mouseDown), so this is a stroke.
            return AnnotationGeometry.stroke(tool == .pen ? .pen : .highlighter, through: points, transform: transform,
                                             imageSize: imageSize, style: screenStyle)
        }
    }

    /// The crop a crop-tool drag gives at `point`: whole image pixels, inside the image, at least 1×1.
    private func cropped(_ drag: CropDrag, to point: CGPoint, _ transform: CanvasTransform) -> CGRect? {
        switch drag {
        case .create(let start):
            return AnnotationGeometry.cropRect(from: start, to: point, transform: transform, imageSize: imageSize)
        case .resize(let handle, let original):
            let p = transform.viewToImage(point)
            let rect = AnnotationGeometry.resize(AnnotationMark(rect: original), handle: handle,
                                                 to: CGPoint(x: p.x.rounded(), y: p.y.rounded()), imageSize: imageSize).rect
            return rect.width >= 1 && rect.height >= 1 ? rect : original
        case .move(let start, let original):
            let scale = pointsPerImagePixel
            let delta = CGVector(dx: ((point.x - start.x) / scale).rounded(), dy: ((point.y - start.y) / scale).rounded())
            return AnnotationGeometry.translate(AnnotationMark(rect: original), by: delta, imageSize: imageSize).rect
        }
    }

    private func moved(_ mark: AnnotationMark, from start: CGPoint, to point: CGPoint) -> AnnotationMark {
        let scale = pointsPerImagePixel
        return AnnotationGeometry.translate(mark, by: CGVector(dx: (point.x - start.x) / scale, dy: (point.y - start.y) / scale),
                                            imageSize: imageSize)
    }

    private func handle(at point: CGPoint, of mark: AnnotationMark, _ transform: CanvasTransform) -> AnnotationHandle? {
        AnnotationGeometry.handles(for: mark.kind).first { handle in
            let centre = transform.imageToView(AnnotationGeometry.handlePoint(handle, of: mark))
            return abs(centre.x - point.x) <= Self.handleReach && abs(centre.y - point.y) <= Self.handleReach
        }
    }

    // MARK: Text

    private func beginEditing(index: Int?, text: String, origin: CGPoint, style: AnnotationStyle) {
        let field = NSTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.font = NSFont.systemFont(ofSize: AnnotationMetrics.textFontSize * style.unit * pointsPerImagePixel, weight: .semibold)
        field.textColor = NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1)
        field.setAccessibilityLabel(String(localized: "Annotation Text"))
        field.setAccessibilityIdentifier("annotate.text-field")
        field.delegate = self
        editing = (index, origin, style)
        textEditor = field
        addSubview(field)
        placeTextEditor()
        needsDisplay = true
        window?.makeFirstResponder(field)
    }

    private func placeTextEditor() {
        guard let textEditor, let editing, let transform else { return }
        let origin = transform.imageToView(editing.origin)
        let size = textEditor.intrinsicContentSize
        let width = max(40, textEditor.attributedStringValue.size().width + 16)
        textEditor.frame = CGRect(x: origin.x, y: origin.y, width: width.rounded(.up), height: size.height.rounded(.up))
    }

    /// Ends text editing, reporting the text once. False when nothing was being edited.
    @discardableResult public func commitText() -> Bool {
        guard let editing, let field = textEditor else { return false }
        let text = field.stringValue
        self.editing = nil
        textEditor = nil
        if let editor = field.currentEditor(), window?.firstResponder === editor { window?.makeFirstResponder(nil) }
        field.delegate = nil
        field.removeFromSuperview()
        needsDisplay = true
        onCommitText?(editing.index, text, editing.origin, editing.style)
        return true
    }

    public func controlTextDidChange(_ notification: Notification) {
        placeTextEditor()
        onTextChange?()
    }

    public func controlTextDidEndEditing(_ notification: Notification) { commitText() }

    /// Return and Esc end the typing; Esc does not leave Annotate Mode (#692).
    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) || selector == #selector(NSResponder.cancelOperation(_:))
        else { return false }
        // #692 fix r1: an Esc no input method took while composing drops the composition, as Pinyin's Esc does, and
        // typing goes on; it never commits the half-typed text.
        if selector == #selector(NSResponder.cancelOperation(_:)), textView.hasMarkedText() {
            textView.insertText("", replacementRange: textView.markedRange())
            textView.unmarkText()
            return true
        }
        commitText()
        return true
    }
}

/// A completed mark for VoiceOver (#692 fix r1): its kind (a step reads 「序号 N」 with its current number), a text
/// mark's words as the value, the selection, and the mark's view bounds as the frame. Selecting or pressing it selects
/// the mark; the 删除 action asks the window to delete it.
@MainActor private final class AnnotationMarkElement: NSAccessibilityElement {
    private weak var overlay: AnnotationOverlayView?
    private let index: Int

    init(overlay: AnnotationOverlayView, index: Int) {
        self.overlay = overlay
        self.index = index
        super.init()
        setAccessibilityElement(true)
        setAccessibilityRole(.layoutItem)
        setAccessibilityParent(overlay)
    }

    private var mark: AnnotationMark? {
        guard let marks = overlay?.marks, marks.indices.contains(index) else { return nil }
        return marks[index]
    }

    override func accessibilityLabel() -> String? {
        guard let overlay, let mark else { return nil }
        switch mark.kind {
        case .rectangle: return String(localized: "Rectangle")
        case .arrow: return String(localized: "Arrow")
        case .text: return String(localized: "Text")
        case .highlighter: return String(localized: "Highlighter")
        case .pen: return String(localized: "Pen")
        case .redaction: return String(localized: "Redact")
        case .step:
            // Steps number by creation order: this one is the count of steps up to it.
            let number = overlay.marks[...index].filter { $0.kind == .step }.count
            return String(format: String(localized: "Step %lld"), number)
        }
    }

    override func accessibilityValue() -> Any? { mark?.kind == .text ? mark?.text : nil }

    override func isAccessibilitySelected() -> Bool { mark != nil && overlay?.selectedMark == index }

    override func setAccessibilitySelected(_ selected: Bool) {
        guard let overlay else { return }
        if selected { overlay.onSelect?(index) } else if overlay.selectedMark == index { overlay.onSelect?(nil) }
    }

    override func accessibilityPerformPress() -> Bool {
        setAccessibilitySelected(true)
        return true
    }

    override func accessibilityFrame() -> NSRect {
        guard let overlay, let mark, let transform = overlay.transform, let window = overlay.window else { return .zero }
        return window.convertToScreen(overlay.convert(overlay.viewRect(mark.rect, transform), to: nil))
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: String(localized: "Delete")) { [weak self] in
            guard let self, let overlay = self.overlay else { return false }
            overlay.onDelete?(self.index)
            return true
        }]
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
    /// The copy 存储 writes, named in the body; a fresh plan replaces it in place.
    public var plannedName: String { didSet { showPlannedName() } }

    public init(originalName: String, plannedName: String) {
        self.plannedName = plannedName
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
        showPlannedName()
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
    private func showPlannedName() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 18
        paragraph.maximumLineHeight = 18
        bodyField.attributedStringValue = NSAttributedString(
            string: String(format: String(localized: "Save keeps the original unchanged and saves a copy as %@. Don't Save discards these marks."),
                           plannedName),
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: DesignColor.textSecondary.nsColor,
                         .paragraphStyle: paragraph])
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

// MARK: - Redaction options

/// #693 page 39 `#tool-options` (annotate.html:86–97, :155–160): 遮挡's options, 236 wide, 12 left of the strip, its
/// nub at the 遮挡 tool's centre and its top clamped 12 inside the window (:207–209). Rows: the title, 马赛克/实色块,
/// then for a mosaic 强度 with an unnumbered slider (decision 5.3) and the reversible hint with 改用实色块 (5.4), or for a
/// solid box 「纯黑色块，不可还原。」. Choosing reports the style; `update(_:)` shows one without reporting it.
@MainActor public final class AnnotateRedactionOptionsView: NSView, NSTextViewDelegate {
    public struct Strings: Sendable {
        public var dialog, title, mosaic, solid, strength, strengthLabel, hint, link, solidLine: String
        public init(dialog: String, title: String, mosaic: String, solid: String, strength: String, strengthLabel: String,
                    hint: String, link: String, solidLine: String) {
            self.dialog = dialog; self.title = title; self.mosaic = mosaic; self.solid = solid; self.strength = strength
            self.strengthLabel = strengthLabel; self.hint = hint; self.link = link; self.solidLine = solidLine
        }
        public static var localized: Strings {
            Strings(dialog: String(localized: "Redaction Options"), title: String(localized: "Redact"),
                    mosaic: String(localized: "Mosaic"), solid: String(localized: "Solid"),
                    strength: String(localized: "Strength"), strengthLabel: String(localized: "Mosaic Strength"),
                    hint: String(localized: "A weak mosaic can be reversed to reveal text; use a solid box for anything truly secret."),
                    link: String(localized: "Use Solid Box"),
                    solidLine: String(localized: "Solid black box; cannot be reversed."))
        }
    }

    public var onChange: ((RedactionStyle) -> Void)?
    /// The strip the popover docks beside; set before adding it to the strip's superview.
    public weak var strip: AnnotateStripView? { didSet { dock() } }
    public let mosaicButton: NSButton
    public let solidButton: NSButton
    public let slider = NSSlider(value: Double(RedactionStyle.defaultMosaicStrength),
                                 minValue: Double(RedactionStyle.minimumMosaicStrength),
                                 maxValue: Double(RedactionStyle.maximumMosaicStrength), target: nil, action: nil)
    public let hintView = NSTextView(frame: .zero)
    public let solidLine = NSTextField(labelWithString: "")
    /// The nub's centre, in the popover's own top-left points.
    public private(set) var nubY: CGFloat = 0
    public private(set) var style: RedactionStyle = .mosaic(strength: RedactionStyle.defaultMosaicStrength)

    public static let width: CGFloat = 236
    // annotate.html:86 `gap: 8px; padding: 10px 12px`; rows measured on the page (12 px type, line-height 1.4).
    private static let padding = (x: CGFloat(12), y: CGFloat(10))
    private static let gap: CGFloat = 8
    private static let titleHeight: CGFloat = 17
    private static let segmentedHeight: CGFloat = 28
    private static let sliderRowHeight: CGFloat = 17
    private static let lineHeight: CGFloat = 16.8
    private static let link = URL(string: "mado-annotate:solid")!

    private let strings: Strings
    private let title = NSTextField(labelWithString: "")
    private let segmented = SegmentedView()
    private let strengthLabel = NSTextField(labelWithString: "")
    private let nub = CALayer()

    public init(strings: Strings = .localized) {
        self.strings = strings
        mosaicButton = SegmentButton(title: strings.mosaic)
        solidButton = SegmentButton(title: strings.solid)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.width, height: 100))
        panelBackground(self)
        layer?.masksToBounds = false
        nub.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        nub.setAffineTransform(CGAffineTransform(rotationAngle: .pi / 4))
        layer?.addSublayer(nub)
        setAccessibilityElement(true)
        setAccessibilityRole(.popover)
        setAccessibilityLabel(strings.dialog)
        setAccessibilityIdentifier("annotate.redaction-options")

        title.stringValue = strings.title
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = DesignColor.textPrimary.nsColor
        segmented.addSubview(mosaicButton)
        segmented.addSubview(solidButton)
        for button in [mosaicButton, solidButton] {
            button.target = self
            button.action = #selector(chooseSegment(_:))
        }
        strengthLabel.stringValue = strings.strength
        strengthLabel.font = .systemFont(ofSize: 12)
        strengthLabel.textColor = DesignColor.textPrimary.nsColor
        slider.isContinuous = false
        slider.numberOfTickMarks = 0
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(slid(_:))
        slider.setAccessibilityLabel(strings.strengthLabel)

        hintView.isEditable = false
        hintView.isSelectable = true
        hintView.drawsBackground = false
        hintView.textContainerInset = .zero
        hintView.textContainer?.lineFragmentPadding = 0
        hintView.isVerticallyResizable = false
        hintView.delegate = self
        hintView.linkTextAttributes = [.foregroundColor: DesignColor.selectionText.nsColor, .cursor: NSCursor.pointingHand]
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = Self.lineHeight
        paragraph.maximumLineHeight = Self.lineHeight
        let font = NSFont.systemFont(ofSize: 12)
        let hint = NSMutableAttributedString(string: strings.hint + " ", attributes: [.font: font, .paragraphStyle: paragraph,
            .foregroundColor: AnnotatePaint.redactionHint])
        hint.append(NSAttributedString(string: strings.link, attributes: [.font: font, .paragraphStyle: paragraph,
            .link: Self.link]))
        hintView.textStorage?.setAttributedString(hint)

        solidLine.stringValue = strings.solidLine
        solidLine.font = font
        solidLine.textColor = DesignColor.textSecondary.nsColor
        for view in [title, segmented, strengthLabel, slider, hintView, solidLine] { addSubview(view) }
        update(style)
    }
    required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    /// Shows `style` (a selected redaction's, or the tool's) without reporting it.
    public func update(_ style: RedactionStyle) {
        self.style = style
        let mosaic: Bool
        switch style {
        case .mosaic(let strength):
            mosaic = true
            slider.integerValue = strength
        case .solid:
            mosaic = false
        }
        mosaicButton.state = mosaic ? .on : .off
        solidButton.state = mosaic ? .off : .on
        for view in [strengthLabel, slider, hintView] as [NSView] { view.isHidden = !mosaic }
        solidLine.isHidden = mosaic
        layoutRows()
        dock()
    }

    private func layoutRows() {
        let x = Self.padding.x, inner = Self.width - 2 * x
        var y = Self.padding.y
        title.frame = CGRect(x: x, y: y, width: inner, height: Self.titleHeight)
        y += Self.titleHeight + Self.gap
        segmented.frame = CGRect(x: x, y: y, width: segmented.layoutButtons(), height: Self.segmentedHeight)
        y += Self.segmentedHeight + Self.gap
        if solidLine.isHidden {
            let label = ceil(strengthLabel.intrinsicContentSize.width)
            strengthLabel.frame = CGRect(x: x, y: y, width: label, height: Self.sliderRowHeight)
            slider.frame = CGRect(x: x + label + 6, y: y, width: inner - label - 6, height: Self.sliderRowHeight)
            y += Self.sliderRowHeight + Self.gap
            let height = Self.lineHeight * CGFloat(hintLines(width: inner))
            hintView.frame = CGRect(x: x, y: y, width: inner, height: height)
            y += height
        } else {
            solidLine.frame = CGRect(x: x, y: y, width: inner, height: Self.lineHeight)
            y += Self.lineHeight
        }
        let height = y + Self.padding.y
        if frame.size != CGSize(width: Self.width, height: height) { setFrameSize(CGSize(width: Self.width, height: height)) }
    }

    private func hintLines(width: CGFloat) -> Int {
        guard let container = hintView.textContainer, let manager = hintView.layoutManager else { return 1 }
        container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(1, Int((manager.usedRect(for: container).height / Self.lineHeight).rounded()))
    }

    // MARK: Placement

    /// The popover's top-left frame beside a strip at `stripFrame` whose 遮挡 tool is centred at `toolCentreY` (the
    /// container's top-left points), and the nub's y in the popover.
    public static func placement(height: CGFloat, stripFrame: CGRect, toolCentreY: CGFloat,
                                 containerHeight: CGFloat) -> (frame: CGRect, nubY: CGFloat) {
        let top = max(12, min(containerHeight - height - 12, (toolCentreY - height / 2).rounded()))
        return (CGRect(x: stripFrame.minX - 12 - width, y: top, width: width, height: height), toolCentreY - top)
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
        guard let superview, let strip else { return }
        let size = superview.bounds.size
        let stripFrame = AnnotateStripView.frame(in: size)
        let placed = Self.placement(height: frame.height, stripFrame: stripFrame,
                                    toolCentreY: stripFrame.minY + strip.centreY(of: .redact), containerHeight: size.height)
        nubY = placed.nubY
        place(self, topLeft: placed.frame)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        nub.position = CGPoint(x: Self.width, y: layer?.isGeometryFlipped == true ? nubY : frame.height - nubY)
        CATransaction.commit()
        needsDisplay = true
    }

    // MARK: Drawing and input

    public override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let panel = DesignColor.popoverBackground.nsColor
            panel.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            nub.backgroundColor = panel.cgColor
        }
    }

    @objc private func chooseSegment(_ sender: NSButton) {
        choose(sender === solidButton ? .solid : .mosaic(strength: slider.integerValue))
    }

    @objc private func slid(_ sender: NSSlider) { choose(.mosaic(strength: sender.integerValue)) }

    private func choose(_ style: RedactionStyle) {
        update(style)
        onChange?(style)
    }

    /// 改用实色块.
    public func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        choose(.solid)
        return true
    }

    /// annotate.html:89–91 `.segmented`: a 2 pt inset track in `--color-hover`; the pressed segment is panel-filled.
    private final class SegmentedView: NSView {
        override var isFlipped: Bool { true }
        func layoutButtons() -> CGFloat {
            var x: CGFloat = 2
            for case let button as SegmentButton in subviews {
                let width = ceil(button.titleWidth) + 20
                button.frame = CGRect(x: x, y: 2, width: width, height: 24)
                x += width
            }
            return x + 2
        }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                DesignColor.hoverBackground.nsColor.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
            }
        }
    }

    private final class SegmentButton: NSButton {
        init(title: String) {
            super.init(frame: .zero)
            self.title = title
            isBordered = false
            bezelStyle = .regularSquare
            setButtonType(.onOff)
            refusesFirstResponder = true
            font = .systemFont(ofSize: 12)
        }
        required init?(coder: NSCoder) { nil }
        var titleWidth: CGFloat { (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width }
        override var state: NSControl.StateValue { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let on = state == .on
                if on {
                    DesignColor.popoverBackground.nsColor.setFill()
                    NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
                    DesignColor.divider.nsColor.setStroke()
                    let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
                    edge.lineWidth = 0.5
                    edge.stroke()
                }
                let colour = on ? DesignColor.textPrimary.nsColor : DesignColor.textSecondary.nsColor
                let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 12),
                                                                           .foregroundColor: colour])
                let size = text.size()
                text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
            }
        }
    }
}
