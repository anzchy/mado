import AppKit
import MadoApplication

/// A transient system-like selection surface. Its window ID is excluded from the request.
@MainActor final class CaptureSelectionPanel: NSPanel {
    enum Mode { case region, window }

    init(screen: NSScreen, displayID: UInt32, mode: Mode,
         windows: [ScreenCaptureKitScreen.WindowCandidate] = [],
         finish: @escaping (CaptureRequest.Target?) -> Void) {
        let canvas = CaptureSelectionView(screen: screen, displayID: displayID,
                                          mode: mode, windows: windows, finish: finish)
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        acceptsMouseMovedEvents = true
        contentView = canvas
        makeKeyAndOrderFront(nil)
        NSCursor.crosshair.set()
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            (contentView as? CaptureSelectionView)?.cancel()
        } else {
            super.keyDown(with: event)
        }
    }
}

@MainActor private final class CaptureSelectionView: NSView {
    private let screenFrame: CGRect
    private let displayID: UInt32
    private let scale: CGFloat
    private let mode: CaptureSelectionPanel.Mode
    private let windows: [(id: UInt32, rect: CGRect)]
    private let finish: (CaptureRequest.Target?) -> Void
    private var anchor: CGPoint?
    private var selection: CGRect?
    private var hovered: (id: UInt32, rect: CGRect)?

    init(screen: NSScreen, displayID: UInt32, mode: CaptureSelectionPanel.Mode,
         windows: [ScreenCaptureKitScreen.WindowCandidate], finish: @escaping (CaptureRequest.Target?) -> Void) {
        self.screenFrame = screen.frame
        self.displayID = displayID
        self.scale = screen.backingScaleFactor
        self.mode = mode
        self.finish = finish
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        self.windows = windows.map {
            ($0.id, CGRect(x: $0.frame.minX - screen.frame.minX,
                           y: primaryTop - $0.frame.maxY - screen.frame.minY,
                           width: $0.frame.width, height: $0.frame.height))
        }
        super.init(frame: CGRect(origin: .zero, size: screen.frame.size))
        setAccessibilityIdentifier("capture.selection")
    }

    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: mode == .region ? .crosshair : .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        switch mode {
        case .region:
            anchor = point
            selection = nil
        case .window:
            updateHover(at: point)
            if let hovered { finish(.window(windowID: hovered.id)) }
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .region, let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                           width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        if mode == .window { updateHover(at: convert(event.locationInWindow, from: nil)) }
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .region else { return }
        defer { anchor = nil }
        guard let rect = selection, rect.width > 0, rect.height > 0 else { cancel(); return }
        let global = rect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
        finish(.region(rect: global, displayID: displayID, displayFrame: screenFrame, scale: scale))
    }

    func cancel() { finish(nil) }

    private func updateHover(at point: CGPoint) {
        hovered = windows.first { $0.rect.contains(point) }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let selected = mode == .region ? selection : hovered?.rect
        NSColor.black.withAlphaComponent(0.25).setFill()
        if let selected, !selected.isEmpty {
            NSRect(x: 0, y: 0, width: bounds.width, height: selected.minY).fill()
            NSRect(x: 0, y: selected.maxY, width: bounds.width, height: bounds.maxY - selected.maxY).fill()
            NSRect(x: 0, y: selected.minY, width: selected.minX, height: selected.height).fill()
            NSRect(x: selected.maxX, y: selected.minY, width: bounds.maxX - selected.maxX, height: selected.height).fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selected)
            border.lineWidth = 1
            border.stroke()
            if mode == .region {
                let label = "\(Int(selected.width.rounded()))×\(Int(selected.height.rounded()))"
                let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.white,
                                                             .font: NSFont.systemFont(ofSize: 11)]
                (label as NSString).draw(at: CGPoint(x: selected.minX + 5, y: max(5, selected.minY - 18)),
                                         withAttributes: attrs)
            }
        } else {
            bounds.fill()
        }
    }
}
