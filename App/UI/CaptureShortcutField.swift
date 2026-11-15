import AppKit
import MadoApplication
import MadoMacUI

/// A global capture shortcut field (design page 35, settings.html:99-101 `.shortcut-field`). Click it, then press the
/// new shortcut: Esc cancels, Delete clears. ⌘ combos arrive as key equivalents, so both paths record.
@MainActor final class CaptureShortcutField: NSButton {
    enum Outcome: Equatable { case cancelled, cleared, recorded(CaptureKeyCombo) }

    var combo: CaptureKeyCombo? { didSet { refreshTitle() } }
    private(set) var isRecording = false
    var began: (() -> Void)?
    var finished: ((Outcome) -> Void)?
    private let localize: (String) -> String

    init(frame: NSRect, name: String, localize: @escaping (String) -> String) {
        self.localize = localize
        super.init(frame: frame)
        bezelStyle = .rounded
        alignment = .left
        target = self
        action = #selector(startRecording)
        toolTip = localize("Click, then press the new shortcut")
        setAccessibilityLabel(String(format: localize("%@ Shortcut"), name))
        refreshTitle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { isEnabled }

    /// While recording: the mouse-down monitor and the window / app observers that end it (#685 fix r2 F3).
    private var recordingObservers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    @objc private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        window?.makeFirstResponder(self)
        refreshTitle()
        watchForRecordingEnd()
        began?()
    }

    /// A click on a label never takes first responder, so the field watches for it itself; leaving the Settings
    /// window or Mado ends recording too. Otherwise the global shortcuts stay suspended until the helper's 30 s resume.
    private func watchForRecordingEnd() {
        let center = NotificationCenter.default
        let cancel: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelRecording() }
        }
        recordingObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: cancel),
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main,
                               using: cancel),
        ]
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) {
            [weak self] event in
            let window = event.window, point = event.locationInWindow
            MainActor.assumeIsolated { self?.mouseDownWhileRecording(in: window, at: point) }
            return event
        }
    }

    private func stopWatchingForRecordingEnd() {
        recordingObservers.forEach(NotificationCenter.default.removeObserver)
        recordingObservers = []
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }

    private func cancelRecording() {
        if isRecording { end(.cancelled) }
    }

    /// The mouse-down monitor's decision while recording (fix r2 F3). `point` is in `window`'s coordinates. A click
    /// inside the field keeps recording; anywhere else, in this window or another, ends it.
    func mouseDownWhileRecording(in window: NSWindow?, at point: NSPoint) {
        guard isRecording else { return }
        if let window, window === self.window, bounds.contains(convert(point, from: nil)) { return }
        end(.cancelled)
    }

    override func keyDown(with event: NSEvent) {
        if isRecording { record(event) } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { end(.cancelled) }
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, isRecording { end(.cancelled) }
        super.viewWillMove(toWindow: newWindow)
    }

    private func record(_ event: NSEvent) {
        let plain = Self.modifiers(event.modifierFlags).isEmpty
        if plain, event.keyCode == 53 { end(.cancelled); return }
        if plain, [51, 117].contains(event.keyCode) { end(.cleared); return }
        end(.recorded(Self.combo(from: event)))
    }

    private func end(_ outcome: Outcome) {
        isRecording = false
        stopWatchingForRecordingEnd()
        refreshTitle()
        finished?(outcome)
    }

    private func refreshTitle() {
        let text: String
        let font: NSFont
        let color: NSColor
        if isRecording {
            (text, font, color) = (localize("Type Shortcut…"), DesignMetrics.font("uiSmall"), DesignColor.textSecondary.nsColor)
        } else if let combo {
            (text, font, color) = (combo.display, DesignMetrics.font("uiSmall", monospaced: true), DesignColor.textPrimary.nsColor)
        } else {
            // settings.html:101 `.shortcut-field.unset`: muted, sans.
            (text, font, color) = (localize("Not Set"), DesignMetrics.font("uiSmall"), DesignColor.textSecondary.nsColor)
        }
        self.font = font
        attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let width = max(96, (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 24)
        setFrameSize(NSSize(width: width, height: 24))
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> CaptureKeyModifiers {
        var result: CaptureKeyModifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    static func combo(from event: NSEvent) -> CaptureKeyCombo {
        let base = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers
        return CaptureKeyCombo(keyCode: UInt32(event.keyCode), key: keyLabel(keyCode: event.keyCode, characters: base),
                               modifiers: modifiers(event.modifierFlags))
    }

    /// Named keys by virtual key code; other keys by the character they type without modifiers.
    static func keyLabel(keyCode: UInt16, characters: String?) -> String {
        let named: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 76: "⌤",
            123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
            109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
            79: "F18", 80: "F19", 90: "F20",
        ]
        if let name = named[keyCode] { return name }
        let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return text.isEmpty ? "#\(keyCode)" : text
    }
}
