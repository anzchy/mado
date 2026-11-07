import AppKit
import MadoMacUI

@MainActor private final class RebindStripButton: NSButton {
    override var acceptsFirstResponder: Bool { isEnabled && !isHiddenOrHasHiddenAncestor }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
}

/// Window-local feedback. Native buttons supply keyboard activation and visible focus.
final class AccessRebindStripView: NSView {
    let messageLabel = NSTextField(labelWithString: "")
    let undoButton: NSButton = RebindStripButton(title: String(localized: "Undo"), target: nil, action: nil)
    let closeButton: NSButton = RebindStripButton(title: "", target: nil, action: nil)
    var onUndo: (() -> Void)?
    var onClose: (() -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityIdentifier("access.rebind.strip")
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = DesignColor.textSecondary.nsColor
        messageLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.maximumNumberOfLines = 1
        for button in [undoButton, closeButton] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13)
            button.focusRingType = .exterior
            button.target = self
            addSubview(button)
        }
        undoButton.action = #selector(activateRebindUndo(_:))
        undoButton.setAccessibilityIdentifier("access.rebind.undo")
        closeButton.action = #selector(activateClose(_:))
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.setAccessibilityLabel(String(localized: "Dismiss Location Update"))
        closeButton.setAccessibilityIdentifier("access.rebind.close")
        addSubview(messageLabel)
        undoButton.nextKeyView = closeButton
        refreshColors()
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        let closeX = bounds.maxX - 16 - 28
        let undoWidth = max(60, ceil((undoButton.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 24)
        closeButton.frame = NSRect(x: closeX, y: (bounds.height - 28) / 2, width: 28, height: 28)
        undoButton.frame = NSRect(x: closeX - 8 - undoWidth, y: closeButton.frame.minY, width: undoWidth, height: 28)
        messageLabel.frame = NSRect(x: 16, y: (bounds.height - 18) / 2, width: max(0, undoButton.frame.minX - 8 - 16), height: 18)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refreshColors() }
    private func refreshColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = DesignColor.sidebarBackground.nsColor.cgColor }
    }
    func retire() {
        onUndo = nil; onClose = nil
        for button in [undoButton, closeButton] {
            button.isEnabled = false; button.nextKeyView = nil
            button.setAccessibilityHidden(true)
        }
        setAccessibilityHidden(true)
        removeFromSuperview()
    }
    @objc private func activateRebindUndo(_ sender: NSButton) { if sender.isEnabled { onUndo?() } }
    @objc private func activateClose(_ sender: NSButton) { if sender.isEnabled { onClose?() } }
}
