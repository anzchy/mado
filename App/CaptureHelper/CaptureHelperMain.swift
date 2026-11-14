import AppKit
import MadoApplication
import MadoMacUI

@main enum CaptureHelperMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = CaptureHelperDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor private final class CaptureHelperDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var statusPanel: NSPanel?
    private var status: NSTextField?
    private let session = CaptureSession(screen: ScreenCaptureKitScreen(), files: DownloadsCaptureFilePort())

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults(suiteName: CaptureBarIdentity.appGroupID)?
            .bool(forKey: CaptureBarIdentity.enabledKey) == true else {
            NSApp.terminate(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 562, height: 40),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if #available(macOS 26, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.contentView = CaptureBarView { [weak self] in self?.capture() }
        let display = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let display {
            panel.setFrameOrigin(NSPoint(x: display.frame.midX - 281,
                                         y: display.visibleFrame.maxY - 32 - 40))
        }
        let statusPanel = NSPanel(contentRect: NSRect(x: panel.frame.minX, y: panel.frame.minY - 42,
                                                        width: 562, height: 36),
                                  styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        statusPanel.level = .screenSaver
        statusPanel.collectionBehavior = panel.collectionBehavior
        statusPanel.backgroundColor = DesignColor.popoverBackground.nsColor
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 10, y: 7, width: 542, height: 22)
        status.font = DesignMetrics.font("uiSmall")
        status.textColor = DesignColor.textPrimary.nsColor
        statusPanel.contentView?.addSubview(status)
        self.statusPanel = statusPanel
        self.status = status
        self.panel = panel
        panel.orderFrontRegardless()
    }

    @objc private func capture() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await session.capture()
                status?.stringValue = String(format: String(localized: "Saved %@"), url.lastPathComponent)
            } catch ScreenCaptureKitScreen.Failure.permissionDenied {
                status?.stringValue = String(localized: "Screen capture requires Screen Recording permission, which is currently denied. System Settings has been opened.")
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            } catch CaptureSessionError.busy {
                status?.stringValue = String(localized: "Capture in progress")
            } catch {
                status?.stringValue = String(format: String(localized: "Capture failed: %@"), error.localizedDescription)
            }
            statusPanel?.orderFrontRegardless()
        }
    }
}
