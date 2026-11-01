import AppKit
import PicseeCore
import PicseeApplication

/// Reusable renderer and input adapter. Geometry is pure; zoom intent belongs to the Session.
@MainActor
open class CanvasView: NSView {
    public let session: ViewerSession
    /// Explicit opens mint a generation; revision retries reuse it. No file access occurs here.
    public var openingGeneration: (() -> UUID)?
    private var previousOpeningGeneration: UUID?
    private var transform = CanvasTransform(backingScale: 1)
    private var image: NSImage?
    private var sourceSize = CGSize.zero
    private var message: String?
    private var dragPoint: CGPoint?
    private var previousViewport = CGSize.zero
    private var showsKeyboardFocusRing = false
    private var preserveKeyboardFocusRingForOpening = false
    public var onResolutionNeeded: ((Int) -> Void)?

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

    public func showKeyboardFocusRing() {
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
        dragPoint = nil
        let generation = openingGeneration?() ?? UUID()
        if generation != previousOpeningGeneration {
            sourceSize = .zero
            session.beginCanvasImage()
        }
        previousOpeningGeneration = generation
        message = nil
        needsDisplay = true
    }

    public func showFailure() {
        dragPoint = nil
        image = nil
        sourceSize = .zero
        message = nil
        needsDisplay = true
    }

    public func install(_ result: DecodedImage) {
        let changedSize = sourceSize != result.sourcePixelSize
        sourceSize = result.sourcePixelSize
        image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
        message = nil
        if changedSize {
            session.beginCanvasImage()
            fit()
        } else {
            requestDetail()
        }
        previousViewport = bounds.size
        needsDisplay = true
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
            backingScale: Double(window?.backingScaleFactor ?? 1), mode: session.zoomMode)
        needsDisplay = true
        requestDetail()
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
        return transform.zoom
    }

    private func fit() {
        transform = .fitted(source: sourceSize, viewport: bounds.size,
                            backingScale: Double(window?.backingScaleFactor ?? 1))
    }

    /// Gesture values are testable independently of AppKit's non-constructible magnify event.
    public func magnify(by magnification: Double, at point: CGPoint) {
        guard image != nil else { return }
        transform.zoom(to: transform.zoom * exp(magnification), about: point,
                       source: sourceSize, viewport: bounds.size)
        session.reportCanvasZoom(transform.zoom)
        needsDisplay = true
        requestDetail()
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
