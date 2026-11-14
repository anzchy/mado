import AppKit
import MadoApplication

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
    private var status: NSTextField?
    private let session = CaptureSession(screen: ScreenCaptureKitScreen(), files: DownloadsCaptureFilePort())

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults(suiteName: CaptureBarIdentity.appGroupID)?
            .bool(forKey: CaptureBarIdentity.enabledKey) == true else {
            NSApp.terminate(nil)
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 180, y: 180, width: 260, height: 62),
                            styleMask: [.nonactivatingPanel, .titled], backing: .buffered, defer: false)
        panel.title = "Capture Bar"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if #available(macOS 26, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        let button = NSButton(title: "Full Screen Capture", target: self, action: #selector(capture))
        button.frame = NSRect(x: 12, y: 31, width: 236, height: 24)
        panel.contentView?.addSubview(button)
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 12, y: 7, width: 236, height: 20)
        panel.contentView?.addSubview(status)
        self.status = status
        self.panel = panel
        panel.orderFrontRegardless()
    }

    @objc private func capture() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await session.capture()
                status?.stringValue = "Saved \(url.lastPathComponent)"
            } catch ScreenCaptureKitScreen.Failure.permissionDenied {
                status?.stringValue = "Screen Recording permission is required."
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            } catch CaptureSessionError.busy {
                status?.stringValue = "Capture in progress"
            } catch {
                status?.stringValue = "Capture failed: \(error.localizedDescription)"
            }
        }
    }
}
