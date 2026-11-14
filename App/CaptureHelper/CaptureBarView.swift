import AppKit
import MadoMacUI

/// The expanded #680 page 37 toolbar. Later tickets enable the placeholder actions.
@MainActor final class CaptureBarView: NSVisualEffectView {
    init(localize: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) },
         captureAction: @escaping () -> Void) {
        self.captureAction = captureAction
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
        addButton("", symbol: "circle.grid.2x3", id: "capture.grip", x: x, width: 32, enabled: false)
        x += 34
        for (key, symbol, id, enabled) in [
            ("Region Capture", "camera.viewfinder", "capture.region", false),
            ("Window Capture", "macwindow", "capture.window", false),
            ("Full Screen Capture", "display", "capture.screen", true),
            ("Recognize Text", "text.viewfinder", "capture.text", false)
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
        addButton(mado, symbol: "photo", id: "capture.mado", x: x, width: madoWidth, enabled: false)
        x += madoWidth + 2
        addButton("", symbol: "chevron.up", id: "capture.collapse", x: x, width: 32, enabled: false)
        frame.size.width = x + 32 + 4
    }

    required init?(coder: NSCoder) { nil }

    private let captureAction: () -> Void
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
        button.toolTip = title.isEmpty ? (id == "capture.grip" ? localize("Drag Capture Bar") : localize("Collapse to Menu Bar")) : title
        if title.isEmpty { button.setAccessibilityLabel(button.toolTip!) }
        button.setAccessibilityIdentifier(id)
        addSubview(button)
    }

    @objc private func activate(_ sender: NSButton) {
        if sender.accessibilityIdentifier() == "capture.screen" { captureAction() }
    }
}
