import AppKit
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private actor HelperSwitchPreferences: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool {
        let defaults = UserDefaults(suiteName: CaptureBarIdentity.appGroupID)
        defaults?.synchronize()
        return defaults?.bool(forKey: CaptureBarIdentity.enabledKey) == true
    }
    func setCaptureBarEnabled(_ enabled: Bool) {}
}

@MainActor private final class HelperExit: CaptureBarExitPort {
    func exitCaptureBar() { NSApp.terminate(nil) }
}

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
    private var selectionPanels: [CaptureSelectionPanel] = []
    private let selectionAdmission = CaptureSelectionAdmission()
    private let session = CaptureSession(screen: ScreenCaptureKitScreen(), files: MadoInfrastructure.DownloadsCaptureFilePort())
    private let lifecycle = CaptureHelperLifecycle(preferences: HelperSwitchPreferences(), exit: HelperExit())

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard UserDefaults(suiteName: CaptureBarIdentity.appGroupID)?
            .bool(forKey: CaptureBarIdentity.enabledKey) == true else {
            NSApp.terminate(nil)
            return
        }
        let bar = CaptureBarView(captureAction: { [weak self] in self?.capture() },
                                 regionAction: { [weak self] in self?.startSelection(.region) },
                                 windowAction: { [weak self] in self?.startSelection(.window) })
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: bar.frame.width, height: 40),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if #available(macOS 26, *) { panel.collectionBehavior.insert(.canJoinAllApplications) }
        panel.contentView = bar
        let display = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let display {
            panel.setFrameOrigin(NSPoint(x: display.frame.midX - bar.frame.width / 2,
                                         y: display.visibleFrame.maxY - 32 - 40))
        }
        let statusPanel = NSPanel(contentRect: NSRect(x: panel.frame.minX, y: panel.frame.minY - 42,
                                                        width: bar.frame.width, height: 36),
                                  styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        statusPanel.level = .screenSaver
        statusPanel.collectionBehavior = panel.collectionBehavior
        statusPanel.backgroundColor = DesignColor.popoverBackground.nsColor
        let status = NSTextField(labelWithString: "")
        status.frame = NSRect(x: 10, y: 7, width: bar.frame.width - 20, height: 22)
        status.font = DesignMetrics.font("uiSmall")
        status.textColor = DesignColor.textPrimary.nsColor
        statusPanel.contentView?.addSubview(status)
        self.statusPanel = statusPanel
        self.status = status
        self.panel = panel
        panel.orderFrontRegardless()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(), { _, observer, _, _, _ in
                guard let observer else { return }
                let helper = Unmanaged<CaptureHelperDelegate>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in helper.stopIfSwitchOff() }
            }, CaptureBarIdentity.switchChangedNotification as CFString, nil, .deliverImmediately)
        stopIfSwitchOff()
    }

    private func stopIfSwitchOff() {
        Task { await lifecycle.switchChanged() }
    }

    @objc private func capture() {
        capture(request: nil)
    }

    private func startSelection(_ mode: CaptureSelectionPanel.Mode) {
        guard selectionPanels.isEmpty, selectionAdmission.begin() else { return }
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { selectionAdmission.end(); return }
        if mode == .region {
            showSelection(on: screen, displayID: displayID, mode: mode, windows: [])
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let excluded = Set(NSApp.windows.compactMap { UInt32(exactly: $0.windowNumber) })
                    let windows = try await ScreenCaptureKitScreen().selectableWindows(excluding: excluded)
                    showSelection(on: screen, displayID: displayID, mode: mode, windows: windows)
                } catch {
                    selectionAdmission.end()
                    report(error)
                }
            }
        }
    }

    private func showSelection(on screen: NSScreen, displayID: UInt32, mode: CaptureSelectionPanel.Mode,
                               windows: [ScreenCaptureKitScreen.WindowCandidate]) {
        selectionAdmission.end()
        let screens = mode == .window ? NSScreen.screens : [screen]
        for item in screens {
            let id = (item.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? displayID
            let overlay = CaptureSelectionPanel(screen: item, displayID: id, mode: mode, windows: windows) {
                [weak self] target in
                guard let self else { return }
                let overlays = selectionPanels
                selectionPanels.forEach { $0.orderOut(nil) }
                selectionPanels.removeAll()
                guard let target else { return }
                let request = CaptureRequestFromWindows.make(target: target,
                    bars: [panel, statusPanel].compactMap { $0 }, overlays: overlays)
                capture(request: request)
            }
            selectionPanels.append(overlay)
        }
        selectionPanels.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
    }

    private func capture(request: CaptureRequest?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.captureResult(request: request)
                NSPasteboard.general.clearContents()
                let copied = NSPasteboard.general.setData(result.png, forType: .png)
                let message = copied ? "Saved %@" : "Saved %@, but clipboard copy failed"
                status?.stringValue = String(format: String(localized: String.LocalizationValue(message)), result.url.lastPathComponent)
            } catch {
                report(error)
            }
            statusPanel?.orderFrontRegardless()
        }
    }

    private func report(_ error: Error) {
        switch error {
        case ScreenCaptureKitScreen.Failure.permissionNotAsked:
            status?.stringValue = String(localized: "Allow Mado to record the screen in System Settings, then try Capture again.")
        case ScreenCaptureKitScreen.Failure.permissionDenied:
            status?.stringValue = String(localized: "Screen capture requires Screen Recording permission, which is currently denied. System Settings has been opened.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case CaptureSessionError.busy:
            status?.stringValue = String(localized: "Capture in progress")
        default:
            status?.stringValue = String(format: String(localized: "Capture failed: %@"), error.localizedDescription)
        }
        statusPanel?.orderFrontRegardless()
    }
}
