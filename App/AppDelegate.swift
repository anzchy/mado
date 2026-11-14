import AppKit
import UniformTypeIdentifiers
import os
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

#if DEBUG
struct AppDelegateProbeHooks {
    enum ProductEvent {
        case windowOpened, sessionRestored, recentItemsTouched, openURL
    }

    let arguments: [String]
    let runProbe: () -> Void
    let terminate: () -> Void
    let makeAccessServices: () -> Task<AccessServices, Error>
    let record: (ProductEvent) -> Void
}
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let thumbnailCache = ThumbnailDiskCache()
    private lazy var imagePipeline = ImageIOPipeline(cacheTrace: UntestedNativeResourceSnapshotTrace(),
                                                     thumbnailCache: thumbnailCache)
    private lazy var memoryPressure = UntestedNativeMemoryPressureForwarder(pipeline: imagePipeline) { [weak self] level in
        self?.windowController?.memoryPressure(level != .normal)
    }
    private let displayPreferences = UserDefaultsDisplayPreferencesStore(defaults: .standard)
    private lazy var appearanceAdapter = WindowAppearanceAdapter(preferencesStore: displayPreferences)
    private lazy var motionPolicy = MotionPolicy(source: UntestedNativeReduceMotionSource())
    private var commandMenu: CommandMenu?
    private var settingsWindow: SettingsPanelWindow?
    private var diagnosticsWindow: DiagnosticsWindow?
    private(set) var shortcutWindow: ShortcutWindow?
    private var windowController: CanvasWindowController?
    #if DEBUG && PICSEE_UI_TEST_FIXTURE
    private var uiTestFixtureRoot: URL?
    #endif
    private lazy var accessServices: Task<AccessServices, Error> = {
        #if DEBUG
        if let probeHooks { return probeHooks.makeAccessServices() }
        #endif
        let sha = Bundle.main.object(forInfoDictionaryKey: "MadoGitSHA") as? String ?? "unknown"
        #if DEBUG && PICSEE_UI_TEST_FIXTURE
        let fixtureRoot = uiTestFixtureRoot
        return Task.detached {
            if let fixtureRoot { return try AccessServices(buildSHA: sha, fixtureRoot: fixtureRoot) }
            return try AccessServices(buildSHA: sha)
        }
        #else
        return Task.detached { try AccessServices(buildSHA: sha) }
        #endif
    }()
    private let logger = Logger(subsystem: "io.github.anzchy.mado", category: "lifecycle")

    #if DEBUG
    private let probeHooks: AppDelegateProbeHooks?
    init(probeHooks: AppDelegateProbeHooks? = nil) {
        self.probeHooks = probeHooks
        super.init()
    }
    #else
    override init() {
        super.init()
    }
    #endif

    private var launchArguments: [String] {
        #if DEBUG
        if let probeHooks { return probeHooks.arguments }
        #endif
        return ProcessInfo.processInfo.arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let sha = Bundle.main.object(forInfoDictionaryKey: "MadoGitSHA") as? String ?? "unknown"
        logger.notice("Mado launch git=\(sha, privacy: .public)")
        #if DEBUG
        if let probeHooks {
            if AccessProbeRunner.runIfRequested(
                arguments: probeHooks.arguments,
                runProbe: probeHooks.runProbe,
                terminate: probeHooks.terminate
            ) { return }
        } else if AccessProbeRunner.runIfRequested(arguments: launchArguments) { return }
        if let probeHooks {
            probeHooks.record(.windowOpened)
            probeHooks.record(.sessionRestored)
            probeHooks.record(.recentItemsTouched)
            return
        }
        #endif
        _ = memoryPressure
        #if DEBUG && PICSEE_UI_TEST_FIXTURE
        do {
            uiTestFixtureRoot = try UITestFixtureLaunch.prepare(arguments: ProcessInfo.processInfo.arguments,
                environment: ProcessInfo.processInfo.environment)
        } catch {
            logger.error("UI fixture staging failed: \(String(describing: error), privacy: .private)")
        }
        #endif

        commandMenu = CommandMenu(preferencesStore: displayPreferences,
                                  openWithoutWindow: { [weak self] in self?.viewer().route(.open, from: .menu) },
                                  openSettings: { [weak self] in self?.showSettings() },
                                  openDiagnostics: { [weak self] in self?.showDiagnostics() },
                                  openShortcuts: { [weak self] in self?.showShortcuts() })
        viewer().showWindow(nil)
        viewer().refreshRecents()
        #if DEBUG && PICSEE_UI_TEST_FIXTURE
        if let uiTestFixtureRoot { viewer().openGrantedFolder(uiTestFixtureRoot) }
        #endif
        NSApplication.shared.activate(ignoringOtherApps: true)
        startUpdatesOnce()
    }

    /// Runs after the first window is front, so Sparkle's second-launch question opens on top of it (#359).
    private func startUpdatesOnce() {
        guard !updatesStarted, let updates else { return }
        updatesStarted = true
        updates.start()
    }

    #if DEBUG && PICSEE_UI_TEST_FIXTURE
    func applicationWillTerminate(_ notification: Notification) {
        guard let uiTestFixtureRoot else { return }
        do { try UITestFixtureLaunch.removeRun(folder: uiTestFixtureRoot) }
        catch { logger.error("UI fixture cleanup failed: \(String(describing: error), privacy: .private)") }
    }
    #endif

    /// Returning to the foreground reconciles every watched folder (events may have been coalesced or lost),
    /// and a window whose watch failed rescans and subscribes again.
    func applicationDidBecomeActive(_ notification: Notification) {
        #if DEBUG
        if AccessProbeRunner.isRequested(arguments: launchArguments) { return }
        #endif
        let services = accessServices
        Task { try? await services.value.watch.reconcileAll() }
        windowController?.session.folderScan?.reconcileUnwatched()
        windowController?.reconcileStandaloneImage()
    }

    /// #690: quitting with unsaved Annotate Mode marks asks 存储/不存储/取消 first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windowController?.annotateShouldTerminate() ?? .terminateNow
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        #if DEBUG
        if AccessProbeRunner.isRequested(arguments: launchArguments) { return }
        #endif
        #if DEBUG
        if let probeHooks {
            probeHooks.record(.openURL)
            return
        }
        #endif
        viewer().openInput(urls)
        application.activate(ignoringOtherApps: true)
    }

    private func viewer() -> CanvasWindowController {
        if let windowController { return windowController }
        let controller = CanvasWindowController(pipeline: imagePipeline, preferencesStore: displayPreferences, accessServices: accessServices, motionPolicy: motionPolicy)
        controller.appearanceAdapter = appearanceAdapter
        controller.onOpenRequest = { [weak self] in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.image, .folder]
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                if url.hasDirectoryPath { self?.viewer().openGrantedFolder(url) }
                else { self?.viewer().openInput([url]) }
            }
        }
        controller.menuTracking = { [weak self] in self?.commandMenu?.isTracking ?? false }
        controller.onRecentsChanged = { [weak self] folders in
            self?.commandMenu?.setRecentFolders(folders) { [weak self] folder in self?.viewer().openRecent(folder) }
        }
        windowController = controller
        return controller
    }

    /// Set before the app runs; started once at the end of launch and read once when the Settings window is first built.
    var updates: (any AppUpdatePort)?
    private var updatesStarted = false

    func makeSettingsWindow(defaults: UserDefaults = .standard) -> SettingsPanelWindow {
        SettingsPanelWindow(cache: thumbnailCache, appearanceAdapter: appearanceAdapter,
                            preferencesStore: displayPreferences, defaults: defaults, updates: updates)
    }

    private func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeSettingsWindow()
        }
        settingsWindow?.show()
    }

    private func showDiagnostics() {
        if diagnosticsWindow == nil {
            diagnosticsWindow = DiagnosticsWindow(source: imagePipeline, appearanceAdapter: appearanceAdapter)
        }
        diagnosticsWindow?.show()
    }

    func showShortcuts() {
        if shortcutWindow == nil, let mainMenu = NSApp.mainMenu {
            shortcutWindow = ShortcutWindow(menu: mainMenu, appearanceAdapter: appearanceAdapter)
        }
        shortcutWindow?.show()
    }
}

/// Untested native forwarding only; injected source behavior is covered in MadoMacUI.
@MainActor private final class UntestedNativeReduceMotionSource: NSObject, ReduceMotionSource {
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var onChange: (@MainActor () -> Void)?
    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(changed(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    @objc private func changed(_ notification: Notification) { onChange?() }
}
