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
    private let session: CaptureSession
    /// The Capture Folder: ~/Downloads, or the folder chosen in this helper's open panel (ADR-0021).
    private let folder: CaptureFolderAccess
    private let shortcuts: any CaptureShortcutPreferencePort =
        UserDefaultsCaptureShortcutPreferences.shared() ?? UserDefaultsCaptureShortcutPreferences(defaults: .standard)
    private let registrar = CarbonHotKeyRegistrar()
    private let hotKeys: CaptureHotKeyCoordinator
    private let layout: any CaptureBarLayoutPort =
        UserDefaults(suiteName: CaptureBarIdentity.appGroupID).map(UserDefaultsCaptureBarLayout.init(defaults:))
        ?? UserDefaultsCaptureBarLayout(defaults: .standard)
    private var collapse: CaptureBarCollapseController?
    private var bar: CaptureBarView?
    private var folderPanel: NSOpenPanel?
    private var recordingGeneration = 0
    private let thumbnails = CaptureThumbnailPresenter()
    /// 截图并识别文字's notice and panel (#687); its window exists from launch, so every Capture can leave it out.
    private let textPresenter = CaptureRecogniseTextPresenter()
    /// Read at every Capture, so a Settings change applies without restarting the helper.
    private let outputPreferences = UserDefaultsCaptureOutputPreferences.shared()
    private let lifecycle = CaptureHelperLifecycle(preferences: HelperSwitchPreferences(), exit: HelperExit())
    /// Held for the process lifetime; the kernel drops it when the helper exits.
    private let instanceLock = FlockCaptureHelperInstanceLock.appGroup()
    /// The Mado that embeds this helper (#686).
    private let mado = CaptureMadoLauncher()

    override init() {
        // The real home folder: in the sandbox NSHomeDirectory() is the container. ~/Downloads is open to the helper
        // through its Downloads entitlement.
        let home = getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let folder = CaptureFolderAccess(
            scope: SystemSecurityScope(),
            preferences: UserDefaultsCaptureFolderPreferences.shared() ?? UserDefaultsCaptureFolderPreferences(defaults: .standard),
            downloads: home.appendingPathComponent("Downloads", isDirectory: true), home: home)
        self.folder = folder
        session = CaptureSession(screen: ScreenCaptureKitScreen(),
                                 files: MadoInfrastructure.DownloadsCaptureFilePort(folder: { await folder.currentFolder() },
                                                                                   display: { await folder.currentDisplay() }))
        hotKeys = CaptureHotKeyCoordinator(preferences: shortcuts, registrar: registrar)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One helper at a time (#685 fix r3, device N1): a second copy, for example launchd's login item while the
        // bar already runs, exits here with no bar, no hotkeys and no Screen Recording request.
        CaptureHelperStartup.launch(lock: instanceLock, exit: { NSApp.terminate(nil) }, start: { start() })
    }

    /// A recognise read still pending when the helper quits shows and copies nothing (#687c fix r1 F1).
    func applicationWillTerminate(_ notification: Notification) {
        textPresenter.dismiss()
    }

    private func start() {
        guard UserDefaults(suiteName: CaptureBarIdentity.appGroupID)?
            .bool(forKey: CaptureBarIdentity.enabledKey) == true else {
            NSApp.terminate(nil)
            return
        }
        let bar = CaptureBarView(captureAction: { [weak self] in self?.capture() },
                                 regionAction: { [weak self] in self?.startSelection(.region) },
                                 windowAction: { [weak self] in self?.startSelection(.window) },
                                 recognizeAction: { [weak self] in self?.startSelection(.region, purpose: .recogniseText) },
                                 collapseAction: { [weak self] in self?.collapse?.collapse() },
                                 madoAction: { [weak self] in self?.openMado() })
        self.bar = bar
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
        panel.isMovableByWindowBackground = true
        let display = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let display {
            panel.setFrameOrigin(CaptureBarPlacement.defaultOrigin(barSize: bar.frame.size, visibleFrame: display.visibleFrame))
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
        let layout = layout
        collapse = CaptureBarCollapseController(bar: panel, changed: { collapsed in
            Task { await layout.setCollapsed(collapsed) }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(barMoved(_:)), name: NSWindow.didMoveNotification,
                                               object: panel)
        Task { await restoreLayout(of: panel) }
        for name in [CaptureBarIdentity.switchChangedNotification, CaptureBarIdentity.shortcutsChangedNotification,
                     CaptureBarIdentity.chooseFolderNotification, CaptureBarIdentity.recordingBeganNotification,
                     CaptureBarIdentity.recordingEndedNotification] {
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(), { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let helper = Unmanaged<CaptureHelperDelegate>.fromOpaque(observer).takeUnretainedValue()
                    let received = name.rawValue as String
                    Task { @MainActor in helper.received(received) }
                }, name as CFString, nil, .deliverImmediately)
        }
        registrar.install { [weak self] id in
            guard let action = CaptureHotKeyCoordinator.action(forHotKeyID: id) else { return }
            self?.shortcutPressed(action)
        }
        applyShortcuts()
        stopIfSwitchOff()
    }

    private func received(_ name: String) {
        switch name {
        case CaptureBarIdentity.shortcutsChangedNotification: applyShortcuts()
        case CaptureBarIdentity.chooseFolderNotification: chooseFolder()
        case CaptureBarIdentity.recordingBeganNotification: suspendShortcuts()
        case CaptureBarIdentity.recordingEndedNotification: resumeShortcuts()
        default: stopIfSwitchOff()
        }
    }

    /// The saved origin for this display arrangement, clamped on screen; then the collapsed state.
    private func restoreLayout(of panel: NSPanel) async {
        let key = CaptureBarPlacement.arrangementKey(NSScreen.screens.map(\.frame))
        if let saved = await layout.origin(forArrangement: key) {
            let pointer = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            panel.setFrameOrigin(CaptureBarPlacement.origin(saved: saved, barSize: panel.frame.size,
                                                            visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                                            pointerVisibleFrame: pointer?.visibleFrame ?? panel.frame))
        }
        if await layout.isCollapsed() { collapse?.collapse() } else { panel.orderFrontRegardless() }
    }

    @objc private func barMoved(_ notification: Notification) {
        guard let panel else { return }
        let origin = panel.frame.origin
        let key = CaptureBarPlacement.arrangementKey(NSScreen.screens.map(\.frame))
        Task { await layout.setOrigin(origin, forArrangement: key) }
        statusPanel?.setFrameOrigin(NSPoint(x: origin.x, y: origin.y - 42))
    }

    /// Registers the stored bindings again (no restart), then tells Settings to read the failures.
    private func applyShortcuts() {
        Task {
            await hotKeys.apply()
            let bindings = await shortcuts.bindings()
            let ids: [(String, CaptureShortcutAction)] = [("capture.region", .region), ("capture.window", .window),
                                                          ("capture.screen", .fullScreen), ("capture.text", .recognizeText)]
            var labels: [String: String] = [:]
            for (id, action) in ids { labels[id] = bindings[action]?.display }
            bar?.setShortcuts(labels)
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(CaptureBarIdentity.shortcutStatusNotification as CFString), nil, nil, true)
        }
    }

    /// Settings is recording a shortcut. If it never says it finished (it quit, or the field lost its window
    /// without telling us), the hotkeys come back after 30 seconds anyway.
    /// The generation is the coordinator's sequence: these tasks may reach it out of order (#685 fix r1).
    private func suspendShortcuts() {
        recordingGeneration += 1
        let generation = recordingGeneration
        Task {
            await hotKeys.recordingChanged(true, sequence: UInt64(generation))
            try? await Task.sleep(for: .seconds(30))
            if generation == recordingGeneration { resumeShortcuts() }
        }
    }

    private func resumeShortcuts() {
        recordingGeneration += 1
        let generation = recordingGeneration
        Task {
            await hotKeys.recordingChanged(false, sequence: UInt64(generation))
            applyShortcuts()
        }
    }

    private func shortcutPressed(_ action: CaptureShortcutAction) {
        switch CaptureHelperCommand.command(for: action) {
        case .selectRegion(let purpose): startSelection(.region, purpose: purpose)
        case .selectWindow: startSelection(.window)
        case .captureFullScreen: capture()
        case .toggleBar: collapse?.toggle()
        }
    }

    /// The Capture Folder open panel runs here, in the helper, so the security-scoped bookmark is the helper's own
    /// (ADR-0021). Settings only asks for it.
    private func chooseFolder() {
        if let folderPanel { folderPanel.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true
        openPanel.prompt = String(localized: "Choose")
        openPanel.message = String(localized: "Choose the folder new captures are saved to.")
        folderPanel = openPanel
        NSApp.activate()
        Task {
            openPanel.directoryURL = await folder.currentFolder()
            let response = await openPanel.begin()
            folderPanel = nil
            if response == .OK, let url = openPanel.url {
                try? await folder.choose(url)
                _ = await folder.currentFolder()
            }
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                CFNotificationName(CaptureBarIdentity.folderChangedNotification as CFString), nil, nil, true)
        }
    }

    private func stopIfSwitchOff() {
        Task { await lifecycle.switchChanged() }
    }

    @objc private func capture() {
        thumbnails.dismiss()
        textPresenter.dismiss()
        capture(request: nil, selectedDisplay: nil)
    }

    private func startSelection(_ mode: CaptureSelectionPanel.Mode, purpose: CaptureSelectionPurpose = .capture) {
        guard selectionPanels.isEmpty, selectionAdmission.begin() else { return }
        thumbnails.dismiss()  // the new Capture replaces it; it must not be in the image
        textPresenter.dismiss()  // so does a recognised-text notice or panel (#687)
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        else { selectionAdmission.end(); return }
        if mode == .region {
            showSelection(on: screen, displayID: displayID, mode: mode, purpose: purpose, windows: [])
        } else {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let excluded = Set(NSApp.windows.compactMap { UInt32(exactly: $0.windowNumber) })
                    let windows = try await ScreenCaptureKitScreen().selectableWindows(excluding: excluded)
                    showSelection(on: screen, displayID: displayID, mode: mode, purpose: purpose, windows: windows)
                } catch {
                    selectionAdmission.end()
                    report(error)
                }
            }
        }
    }

    private func showSelection(on screen: NSScreen, displayID: UInt32, mode: CaptureSelectionPanel.Mode,
                               purpose: CaptureSelectionPurpose, windows: [ScreenCaptureKitScreen.WindowCandidate]) {
        selectionAdmission.end()
        let screens = mode == .window ? NSScreen.screens : [screen]
        for item in screens {
            let id = (item.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? displayID
            let overlay = CaptureSelectionPanel(screen: item, displayID: id, mode: mode, windows: windows) {
                [weak self] target in
                guard let self else { return }
                let overlays = selectionPanels
                guard !overlays.isEmpty else { return }  // another display's panel already finished
                selectionPanels.forEach { $0.orderOut(nil) }
                selectionPanels.removeAll()
                guard let target else { return }  // Esc: nothing captured, nothing recognised
                let request = CaptureHelperWindows.resolver(target: target, bar: panel, status: statusPanel,
                                                            thumbnails: thumbnails, overlays: overlays,
                                                            others: { [textPresenter] in textPresenter.windows })
                switch CaptureSelectionOutcome.route(purpose: purpose, target: target) {
                case .capture: capture(request: request, selectedDisplay: id, keepingAlive: overlays)
                case .recognise: recogniseText(request: request, selectedDisplay: id, keepingAlive: overlays)
                case .none: break
                }
            }
            selectionPanels.append(overlay)
        }
        selectionPanels.first { $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
    }

    /// `overlays` stay alive until the capture finishes, so nothing depends on when AppKit frees them.
    /// `selectedDisplay` is the display whose selection overlay finished. The pointer is read once, now, so the
    /// thumbnail lands on the display captured even when the pointer moves during the Capture.
    private func capture(request: (@MainActor () -> CaptureRequest)?, selectedDisplay: UInt32?,
                         keepingAlive overlays: [NSWindow] = []) {
        let pointer = NSEvent.mouseLocation
        Task { [weak self] in
            guard let self else { return }
            defer { withExtendedLifetime(overlays) {} }
            do {
                let policy = await outputPreferences?.outputPolicy() ?? .standard
                let clipboard = PasteboardCaptureClipboard()
                let read: @MainActor () async throws -> (CaptureThumbnailState, NSRect) = { [session] in
                    try await CaptureThumbnailFlow.capture(
                        request: request, selectedDisplay: selectedDisplay, session: session, policy: policy,
                        clipboard: clipboard, pointer: { pointer }, screens: CaptureThumbnailPlacement.screens,
                        // The menu bar icon's window is not one of ours to exclude; whileCapturing hides it (fix r2 F1).
                        fullScreenRequest: { ScreenCaptureKitScreen.fullScreenRequest(
                            displayID: $0, windows: NSApp.windows.filter { $0.level != .statusBar }) })
                }
                let (state, frame) = if let collapse { try await collapse.whileCapturing(read) } else { try await read() }
                statusPanel?.orderOut(nil)
                let model = CaptureThumbnailModel(state: state, session: session, clipboard: clipboard,
                                                  trash: FileManagerCaptureTrash())
                thumbnails.present(CaptureThumbnailController(model: model, visibleFrame: frame, opener: mado))
            } catch {
                report(error)
            }
        }
    }

    /// 截图并识别文字 (#687): the region is read into memory under the same admission as a Capture, never saved and
    /// never thumbnailed; the 「截图之后」 switches do not apply. Busy and Screen Recording failures report as a Capture's.
    private func recogniseText(request: @escaping @MainActor () -> CaptureRequest, selectedDisplay: UInt32?,
                               keepingAlive overlays: [NSWindow]) {
        // Taken now, on the selection's completion: a Capture, selection or quit before the Task runs makes it stale.
        let ticket = textPresenter.ticket()
        Task { [weak self] in
            guard let self else { return }
            defer { withExtendedLifetime(overlays) {} }
            do {
                let read: @MainActor () async throws -> (png: Data, visibleFrame: NSRect) = { [session] in
                    try await CaptureRecogniseTextFlow.capture(request: request, selectedDisplay: selectedDisplay,
                                                              session: session, screens: CaptureThumbnailPlacement.screens)
                }
                // A Capture or selection started meanwhile dismissed the presenter: this read is then dropped (fix r1 F1).
                _ = try await textPresenter.recognise(
                    ticket: ticket, read: { [collapse] in if let collapse { try await collapse.whileCapturing(read) } else { try await read() } },
                    willPresent: { [statusPanel] in statusPanel?.orderOut(nil) })
            } catch {
                report(error)
            }
        }
    }

    /// The bar's 打开 Mado (#686): Mado comes to the front with a new or existing window, as its own reopen does.
    private func openMado() {
        Task { [weak self] in
            guard let self else { return }
            do { try await mado.bringMadoForward() } catch {
                status?.stringValue = String(localized: "Couldn't open Mado")
                statusPanel?.orderFrontRegardless()
            }
        }
    }

    private func report(_ error: Error) {
        switch error {
        case ScreenCaptureKitScreen.Failure.permissionNotAsked:
            status?.stringValue = String(localized: "Allow Mado in System Settings › Privacy & Security › Screen & System Audio Recording, then try Capture again.")
        case ScreenCaptureKitScreen.Failure.permissionDenied:
            status?.stringValue = String(localized: "Capture requires Screen & System Audio Recording, which is currently denied. System Settings has been opened.")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        case CaptureSessionError.busy:
            status?.stringValue = String(localized: "Capture in progress")
        default:
            status?.stringValue = String(format: String(localized: "Capture failed: %@"), error.localizedDescription)
        }
        statusPanel?.orderFrontRegardless()
    }
}
