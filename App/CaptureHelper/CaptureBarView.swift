import AppKit
import MadoMacUI

/// The expanded #680 page 37 toolbar. Later tickets enable the placeholder actions.
@MainActor final class CaptureBarView: NSVisualEffectView {
    init(captureAction: @escaping () -> Void) {
        self.captureAction = captureAction
        super.init(frame: NSRect(x: 0, y: 0, width: 562, height: 40))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = DesignMetrics.radii["popover"]!
        layer?.masksToBounds = true
        setAccessibilityIdentifier("capture.bar")
        addButton("", symbol: "circle.grid.2x3", id: "capture.grip", x: 4, width: 32, enabled: false)
        addButton("区域截图", symbol: "camera.viewfinder", id: "capture.region", x: 38, width: 95, enabled: false)
        addButton("窗口截图", symbol: "macwindow", id: "capture.window", x: 135, width: 95, enabled: false)
        addButton("全屏截图", symbol: "display", id: "capture.screen", x: 232, width: 95, enabled: true)
        addButton("识别文字", symbol: "text.viewfinder", id: "capture.text", x: 329, width: 95, enabled: false)
        let divider = NSBox(frame: NSRect(x: 428, y: 10, width: 1, height: 20))
        divider.boxType = .separator
        addSubview(divider)
        addButton("打开 Mado", symbol: "photo", id: "capture.mado", x: 433, width: 91, enabled: false)
        addButton("", symbol: "chevron.up", id: "capture.collapse", x: 526, width: 32, enabled: false)
    }

    required init?(coder: NSCoder) { nil }

    private let captureAction: () -> Void

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
        button.toolTip = title.isEmpty ? (id == "capture.grip" ? "拖动工具条" : "收起到菜单栏") : title
        button.setAccessibilityIdentifier(id)
        addSubview(button)
    }

    @objc private func activate(_ sender: NSButton) {
        if sender.accessibilityIdentifier() == "capture.screen" { captureAction() }
    }
}
