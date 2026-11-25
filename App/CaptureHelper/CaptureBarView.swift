import AppKit
import MadoMacUI

/// The expanded #680 page 37 toolbar. Dragging its background or the grip moves the bar (#685).
@MainActor final class CaptureBarView: NSVisualEffectView {
    /// `shortcuts` maps a button id to its shortcut, shown after the name in the tooltip (capture-bar.html:110-113).
    init(localize: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) },
         captureAction: @escaping () -> Void,
         regionAction: @escaping () -> Void = {}, windowAction: @escaping () -> Void = {},
         recognizeAction: (() -> Void)? = nil,
         collapseAction: (() -> Void)? = nil, madoAction: (() -> Void)? = nil, shortcuts: [String: String] = [:]) {
        self.captureAction = captureAction
        self.regionAction = regionAction
        self.windowAction = windowAction
        self.recognizeAction = recognizeAction
        self.collapseAction = collapseAction
        self.madoAction = madoAction
        self.localize = localize
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: 40))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = DesignMetrics.radii["popover"]!
        layer?.masksToBounds = true
        setAccessibilityIdentifier("capture.bar")
        var x: CGFloat = 4
        let grip = CaptureBarGrip(frame: NSRect(x: x, y: 4, width: 32, height: 32))
        grip.image = NSImage(systemSymbolName: "circle.grid.2x3", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        grip.contentTintColor = DesignColor.textSecondary.nsColor
        grip.toolTip = localize("Drag Capture Bar")
        grip.setAccessibilityLabel(grip.toolTip)
        grip.setAccessibilityIdentifier("capture.grip")
        addSubview(grip)
        x += 34
        for (key, symbol, id, enabled) in [
            ("Region Capture", "camera.viewfinder", "capture.region", true),
            ("Window Capture", "macwindow", "capture.window", true),
            ("Full Screen Capture", "display", "capture.screen", true),
            ("Recognise Text", "text.viewfinder", "capture.text", recognizeAction != nil)
        ] {
            let title = localize(key)
            let width = titleWidth(title) + 10 + 6 + 18 + 10
            addButton(title, symbol: symbol, id: id, x: x, width: width, enabled: enabled)
            x += width + 2
        }
        let divider = NSBox(frame: NSRect(x: x + 2, y: 10, width: 1, height: 20))
        divider.boxType = .separator
        addSubview(divider)
        x += 7
        let mado = localize("Open Mado")
        let madoWidth = titleWidth(mado) + 10 + 6 + 18 + 10
        addButton(mado, symbol: "photo", id: "capture.mado", x: x, width: madoWidth, enabled: madoAction != nil)
        x += madoWidth + 2
        addButton("", symbol: "chevron.up", id: "capture.collapse", x: x, width: 32, enabled: collapseAction != nil)
        frame.size.width = x + 32 + 4
        setShortcuts(shortcuts)
    }

    /// Re-labels the tooltips after a rebind, without rebuilding the bar.
    func setShortcuts(_ shortcuts: [String: String]) {
        for case let button as NSButton in subviews {
            guard !button.title.isEmpty else { continue }
            let id = button.accessibilityIdentifier()
            // The short 识别文字 button is named in full in its tooltip (capture-bar.html:113).
            let name = id == "capture.text" ? localize("Capture and Recognise Text") : button.title
            button.toolTip = shortcuts[id].map { "\(name) \($0)" } ?? name
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    required init?(coder: NSCoder) { nil }

    private let captureAction: () -> Void
    private let regionAction: () -> Void
    private let windowAction: () -> Void
    /// 截图并识别文字 (#687); without it the button stays disabled.
    private let recognizeAction: (() -> Void)?
    private let collapseAction: (() -> Void)?
    private let madoAction: (() -> Void)?
    private let localize: (String) -> String

    private func titleWidth(_ title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: DesignMetrics.font("uiSmall")]).width.rounded(.up)
    }

    private func addButton(_ title: String, symbol: String, id: String, x: CGFloat, width: CGFloat, enabled: Bool) {
        let button = NSButton(title: title, target: self, action: #selector(activate(_:)))
        button.frame = NSRect(x: x, y: 4, width: width, height: 32)
        button.isBordered = false
        button.font = DesignMetrics.font("uiSmall")
        button.contentTintColor = DesignColor.textPrimary.nsColor
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        button.imagePosition = .imageLeading
        button.isEnabled = enabled
        button.toolTip = title.isEmpty ? localize("Collapse to Menu Bar") : title
        if title.isEmpty { button.setAccessibilityLabel(button.toolTip!) }
        button.setAccessibilityIdentifier(id)
        addSubview(button)
    }

    @objc private func activate(_ sender: NSButton) {
        switch sender.accessibilityIdentifier() {
        case "capture.region": regionAction()
        case "capture.window": windowAction()
        case "capture.screen": captureAction()
        case "capture.text": recognizeAction?()
        case "capture.collapse": collapseAction?()
        case "capture.mado": madoAction?()
        default: break
        }
    }
}

/// The drag handle: not a control, so a press on it moves the window.
@MainActor final class CaptureBarGrip: NSImageView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
