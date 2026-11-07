import AppKit
import MadoApplication
import MadoMacUI

/// Untested native one-shot adapter. The Session supplies the entire deadline policy.
@MainActor final class ChromeTimerAdapter: NSObject, ViewerChromeScheduling {
    private var timer: Timer?
    private var callback: (@MainActor () -> Void)?
    func replace(deadline: Double?, action: @escaping @MainActor () -> Void) {
        timer?.invalidate(); timer = nil
        callback = deadline == nil ? nil : action
        guard let deadline else { return }
        let timer = Timer(fireAt: Date(timeIntervalSinceNow: max(0, deadline - ProcessInfo.processInfo.systemUptime)),
            interval: 0, target: self, selector: #selector(fire), userInfo: nil, repeats: false)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    @objc private func fire() {
        timer = nil
        let action = callback; callback = nil
        action?()
    }
}

/// Untested native tracking bridge: forwards coordinates only, including canvas pan drags.
@MainActor final class ChromeEventBridge: NSResponder {
    private weak var overlay: ViewerChromeOverlay?
    private weak var window: NSWindow?
    private let timer: ChromeTimerAdapter
    private var monitor: Any?
    private var tracking: NSTrackingArea?
    init(window: NSWindow, overlay: ViewerChromeOverlay, timer: ChromeTimerAdapter) {
        self.window = window; self.overlay = overlay; self.timer = timer
        super.init()
        startTracking()
        NotificationCenter.default.addObserver(self, selector: #selector(stop), name: NSWindow.willCloseNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(start), name: NSWindow.didBecomeKeyNotification, object: window)
    }
    required init?(coder: NSCoder) { nil }
    private func startTracking() {
        guard monitor == nil, let window, let overlay else { return }
        let area = NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        overlay.addTrackingArea(area); tracking = area
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] event in
            if event.window === self?.window { self?.mouseMoved(with: event) }
            return event
        }
    }
    @objc private func start(_ notification: Notification) { startTracking() }
    override func mouseMoved(with event: NSEvent) {
        if let overlay { overlay.pointerMoved(overlay.convert(event.locationInWindow, from: nil)) }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { overlay?.pointerMoved(NSPoint(x: -1, y: -1)) }
    @objc private func stop(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if let tracking { overlay?.removeTrackingArea(tracking); self.tracking = nil }
        timer.replace(deadline: nil, action: {})
    }
}
