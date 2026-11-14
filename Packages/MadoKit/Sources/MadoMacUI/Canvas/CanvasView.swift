import AppKit
import MadoCore
import MadoApplication

/// Reusable renderer and input adapter. Geometry is pure; zoom intent belongs to the Session.
@MainActor
open class CanvasView: NSView {
    public let session: ViewerSession
    /// Explicit opens mint a generation; revision retries reuse it. No file access occurs here.
    public var openingGeneration: (() -> UUID)?
    private var previousOpeningGeneration: UUID?
    private var transform = CanvasTransform(backingScale: 1)
    private var image: NSImage?
    private var decodedFrame: CGImage?
    private var backdropGeneration: UInt64 = 0
    private var sourceSize = CGSize.zero
    private var message: String?
    private var dragPoint: CGPoint?
    private var previousViewport = CGSize.zero
    private var showsKeyboardFocusRing = false
    private var preserveKeyboardFocusRingForOpening = false
    public var onResolutionNeeded: ((Int) -> Void)?
    /// #690: points kept free on the right for the Annotate strip; the fit uses the area to its left.
    /// Growing it (⌘E) always refits, whatever the zoom, so the strip never covers the image (fix r1); shrinking it
    /// (leaving) refits only in fit mode, so a zoom chosen inside the mode stays.
    public var trailingReserve: CGFloat = 0 {
        didSet {
            guard trailingReserve != oldValue, sourceSize.width > 0,
                  trailingReserve > oldValue || session.zoomMode == .fit else { return }
            if session.zoomMode != .fit { session.beginCanvasImage() }
            fit()
            needsDisplay = true
            requestDetail()
            publishBackdrop()
        }
    }
    public var onBackdropChange: ((CanvasBackdropFrame) -> Void)?
    public var backdropFrame: CanvasBackdropFrame {
        let theme: DesignTheme = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        let components = DesignColor.canvasBackground.components(theme)
        let background = NSColor(srgbRed: components[0], green: components[1], blue: components[2], alpha: components[3])
        return CanvasBackdropFrame(image: decodedFrame, sourceSize: sourceSize, transform: transform,
            canvasSize: bounds.size, background: background, generation: backdropGeneration)
    }

    private func publishBackdrop() {
        backdropGeneration &+= 1
        onBackdropChange?(backdropFrame)
    }

    public init(frame frameRect: NSRect, session: ViewerSession) {
        self.session = session
        super.init(frame: frameRect)
        previousViewport = frameRect.size
        clipsToBounds = true
        focusRingType = .none
        setAccessibilityIdentifier("viewer.canvas")
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(String(localized: "canvas.image", defaultValue: "Image"))
    }

    required public init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override var mouseDownCanMoveWindow: Bool { false }

    private func hideKeyboardFocusRing() {
        let wasVisible = showsKeyboardFocusRing
        showsKeyboardFocusRing = false
        focusRingType = .none
        if wasVisible { needsDisplay = true }
    }

    public var isShowingKeyboardFocusRing: Bool { showsKeyboardFocusRing }

    private func showKeyboardFocusRing() {
        showsKeyboardFocusRing = true
        focusRingType = .none
        needsDisplay = true
    }

    /// A visible ring survives only the openings `body` starts; later openings hide it.
    public func preservingKeyboardFocusRing<Result>(_ body: () -> Result) -> Result {
        let preserving = preserveKeyboardFocusRingForOpening
        preserveKeyboardFocusRingForOpening = showsKeyboardFocusRing
        defer { preserveKeyboardFocusRingForOpening = preserving }
        return body()
    }

    public func beginOpening() {
        if !preserveKeyboardFocusRingForOpening { hideKeyboardFocusRing() }
        image = nil
        decodedFrame = nil
        dragPoint = nil
        let generation = openingGeneration?() ?? UUID()
        if generation != previousOpeningGeneration {
            sourceSize = .zero
            session.beginCanvasImage()
        }
        previousOpeningGeneration = generation
        message = nil
        needsDisplay = true
        publishBackdrop()
    }

    public func showFailure() {
        dragPoint = nil
        image = nil
        decodedFrame = nil
        sourceSize = .zero
        message = nil
        needsDisplay = true
        publishBackdrop()
    }

    public func install(_ result: DecodedImage) {
        let changedSize = sourceSize != result.sourcePixelSize
        sourceSize = result.sourcePixelSize
        image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        decodedFrame = result.image
        message = nil
        if changedSize {
            session.beginCanvasImage()
            fit()
        } else {
            requestDetail()
        }
        previousViewport = bounds.size
        needsDisplay = true
        publishBackdrop()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        publishBackdrop()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        synchronizeViewport()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        synchronizeViewport()
    }

    /// Also used by the App's full-screen handoff; all viewport changes use the same rule.
    public func synchronizeViewport() {
        defer { previousViewport = bounds.size }
        guard sourceSize.width > 0 else { return }
        transform.viewportChanged(source: sourceSize, from: previousViewport, to: bounds.size,
            backingScale: Double(window?.backingScaleFactor ?? 1), mode: session.zoomMode,
            trailingReserve: Double(trailingReserve))
        needsDisplay = true
        requestDetail()
        publishBackdrop()
    }

    public var onCommand: ((CommandID) -> Bool)?
    public var pointerIsOverPanel: (() -> Bool)?
    public var onCanvasFocus: (() -> Void)?
    public var onTab: ((Bool) -> Void)?
    public var hasImage: Bool { image != nil }

    public override func becomeFirstResponder() -> Bool {
        let event = window?.currentEvent ?? NSApplication.shared.currentEvent
        // Any key press that moves focus here shows the ring, except Return, Space and keypad Enter,
        // which open an image.
        if let event, event.type == .keyDown, ![36, 49, 76].contains(event.keyCode) {
            showKeyboardFocusRing()
        } else {
            hideKeyboardFocusRing()
        }
        needsDisplay = true
        return true
    }
    public override func resignFirstResponder() -> Bool {
        hideKeyboardFocusRing()
        needsDisplay = true
        return true
    }
    public override var focusRingMaskBounds: NSRect { .zero }
    public override func drawFocusRingMask() {}

    public override func mouseDown(with event: NSEvent) {
        // AppKit can forward a background view's unhandled press to this canvas.
        if let content = window?.contentView, let parent = content.superview,
           content.hitTest(parent.convert(event.locationInWindow, from: nil)) !== self {
            dragPoint = nil
            return
        }
        hideKeyboardFocusRing()
        onCanvasFocus?()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let end = transform.imageToView(CGPoint(x: sourceSize.width, y: sourceSize.height))
        let rectangle = CGRect(origin: transform.origin,
            size: CGSize(width: end.x - transform.origin.x, height: end.y - transform.origin.y))
        dragPoint = image != nil && rectangle.contains(point) ? point : nil
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let previous = dragPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        transform.pan(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y),
            source: sourceSize, viewport: bounds.size, snap: session.zoomMode == .actualPixels)
        dragPoint = point
        needsDisplay = true
        publishBackdrop()
    }

    public override func mouseUp(with event: NSEvent) { dragPoint = nil }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { onTab?(event.modifierFlags.contains(.shift)); return }
        if event.modifierFlags.intersection([.control, .option]).isEmpty,
           let key = event.charactersIgnoringModifiers,
           let id = CommandID.matching(key: key, command: event.modifierFlags.contains(.command)) {
            let handled = id == .previous || id == .next
                ? preservingKeyboardFocusRing { onCommand?(id) == true } : onCommand?(id) == true
            if handled { return }
        }
        super.keyDown(with: event)
    }

    public func apply(_ command: CommandID, from entry: CommandEntry) -> Double? {
        guard image != nil else { return nil }
        switch command {
        case .fit: fit()
        case .actualPixels:
            transform.actualPixels(about: centre)
            transform.bound(source: sourceSize, viewport: bounds.size, snap: true)
        case .zoomIn: transform.zoom(to: transform.zoom * 1.25, about: commandAnchor(from: entry), source: sourceSize, viewport: bounds.size)
        case .zoomOut: transform.zoom(to: transform.zoom / 1.25, about: commandAnchor(from: entry), source: sourceSize, viewport: bounds.size)
        default: return nil
        }
        needsDisplay = true
        requestDetail()
        publishBackdrop()
        return transform.zoom
    }

    private func fit() {
        transform = .fitted(source: sourceSize, viewport: bounds.size,
                            backingScale: Double(window?.backingScaleFactor ?? 1), trailingReserve: Double(trailingReserve))
    }

    /// Gesture values are testable independently of AppKit's non-constructible magnify event.
    public func magnify(by magnification: Double, at point: CGPoint) {
        guard image != nil else { return }
        transform.zoom(to: transform.zoom * exp(magnification), about: point,
                       source: sourceSize, viewport: bounds.size)
        session.reportCanvasZoom(transform.zoom)
        needsDisplay = true
        requestDetail()
        publishBackdrop()
    }

    private var centre: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    private func commandAnchor(from entry: CommandEntry) -> CGPoint {
        let pointer = window.flatMap { window -> CGPoint? in
            guard window.isVisible else { return nil }
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return bounds.contains(point) ? point : nil
        }
        return CommandZoomAnchor.resolve(entry: entry, pointer: pointer,
            pointerOverPanel: pointerIsOverPanel?() ?? false, centre: centre)
    }

    private func requestDetail() {
        guard image != nil, sourceSize.width > 0 else { return }
        let backing = window?.backingScaleFactor ?? 1
        let viewport = CGSize(width: max(1, bounds.width - 32) * backing,
                              height: max(1, bounds.height - 32) * backing)
        onResolutionNeeded?(CanvasDecodePolicy.maximumPixelSize(source: sourceSize, viewport: viewport,
                                                                zoom: transform.zoom))
    }

    public override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            DesignColor.canvasBackground.nsColor.setFill()
            bounds.fill()
        }
        if let image {
            let origin = transform.imageToView(.zero)
            let end = transform.imageToView(CGPoint(x: sourceSize.width, y: sourceSize.height))
            let rectangle = NSRect(x: origin.x, y: origin.y, width: end.x - origin.x, height: end.y - origin.y)
            image.draw(in: rectangle, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
        }
        if showsKeyboardFocusRing, window?.firstResponder === self {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                DesignColor.focusRing.nsColor.setStroke()
                let ring = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }
}
