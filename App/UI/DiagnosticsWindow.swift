import AppKit
import SwiftUI
import MadoCore
import MadoMacUI

/// Untested native panel (CACHE-04, a native exception: no pinned C state). The model's refresh loop runs only
/// while the panel is on screen; closing, minimising or covering it stops the loop. Shows counts and sizes only.
@MainActor
final class DiagnosticsWindow: NSObject {
    private let panel: NSPanel
    private let appearanceAdapter: WindowAppearanceAdapter
    private let model: DiagnosticsPanelModel

    init(source: any DiagnosticsProviding, appearanceAdapter: WindowAppearanceAdapter) {
        self.appearanceAdapter = appearanceAdapter
        model = DiagnosticsPanelModel(source: source)
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
                        styleMask: [.titled, .closable, .miniaturizable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = String(localized: "Diagnostics")
        panel.identifier = NSUserInterfaceItemIdentifier("diagnostics.window")
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: DiagnosticsPanelView(model: model))
        panel.center()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(visibilityChanged(_:)),
                           name: NSWindow.didChangeOcclusionStateNotification, object: panel)
        center.addObserver(self, selector: #selector(willClose(_:)), name: NSWindow.willCloseNotification, object: panel)
    }

    func show() {
        appearanceAdapter.register(panel)
        panel.makeKeyAndOrderFront(nil)
        // On screen only if the panel isn't covered; otherwise the occlusion notification starts the loop.
        visibilityChanged(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: panel))
    }

    @objc private func visibilityChanged(_ notification: Notification) {
        model.setVisible(panel.isVisible && panel.occlusionState.contains(.visible))
    }

    @objc private func willClose(_ notification: Notification) { model.setVisible(false) }
}
