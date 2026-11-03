import AppKit
import PicseeCore
import PicseeApplication

@MainActor public enum ViewerStateFocus {
    private static func controls(_ state: ViewerStateHost, _ chrome: ViewerChromeOverlay) -> [NSView] {
        state.buttons.filter(\.acceptsFirstResponder) + chrome.tools.filter(\.acceptsFirstResponder)
            + chrome.trailingKeyViews().filter(\.acceptsFirstResponder)
    }
    public static func link(canvas: NSView, state: ViewerStateHost, chrome: ViewerChromeOverlay) {
        if chrome.tools.contains(where: { !$0.isHiddenOrHasHiddenAncestor && $0.isAccessibilityEnabled() != $0.acceptsFirstResponder }) {
            chrome.refresh(filename: chrome.filename, position: chrome.position)
        }
        chrome.linkKeyViews(to: canvas)
        let loop = [canvas] + controls(state, chrome)
        for index in loop.indices { loop[index].nextKeyView = loop[(index + 1) % loop.count] }
    }
    public static func move(reverse: Bool, entering: Bool, state: ViewerStateHost, chrome: ViewerChromeOverlay) -> Bool {
        let controls = controls(state, chrome)
        let target: NSView?
        if entering { target = reverse ? controls.last : controls.first }
        else if let current = controls.firstIndex(where: { $0 === state.window?.firstResponder }) {
            let next = current + (reverse ? -1 : 1)
            target = controls.indices.contains(next) ? controls[next] : nil
        } else { target = nil }
        guard let target else { return false }
        return state.window?.makeFirstResponder(target) == true
    }
}

@MainActor final class ViewerStateButton: NSButton {
    weak var session: ViewerSession?
    override var acceptsFirstResponder: Bool { !isHiddenOrHasHiddenAncestor && isEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        let radius = DesignMetrics.radii["control"]!
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
    override func becomeFirstResponder() -> Bool {
        guard acceptsFirstResponder, super.becomeFirstResponder() else { return false }
        session?.updateFocus(.tools)
        return true
    }
    override func accessibilityPerformPress() -> Bool {
        guard acceptsFirstResponder else { return false }
        performClick(nil)
        return true
    }
    override func keyDown(with event: NSEvent) {
        guard acceptsFirstResponder else { return }
        switch event.keyCode {
        case 48: session?.tab(reverse: event.modifierFlags.contains(.shift))
        case 53:
            if let session { CommandRouter().route(.escape, from: .key, to: session) }
        case 49, 36: performClick(nil)
        default: break
        }
    }
}
