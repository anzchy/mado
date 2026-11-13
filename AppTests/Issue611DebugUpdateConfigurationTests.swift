import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private let issue611Feed = "https://raw.githubusercontent.com/anzchy/mado/main/appcast-mado.xml"
private let issue611Repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Only Sparkle's external operations are replaced; configuration and the adapter are real.
@MainActor private final class Issue611Controller: SparkleController {
    private let defaults: UserDefaults
    var automaticallyChecksForUpdates: Bool {
        get { defaults.bool(forKey: "SUEnableAutomaticChecks") }
        set { defaults.set(newValue, forKey: "SUEnableAutomaticChecks") }
    }
    var lastUpdateCheckDate: Date? = Date(timeIntervalSince1970: 123)
    var canCheckForUpdates = true
    var starts = 0
    var checks = 0
    var callback: (@MainActor () -> Void)?
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func startUpdater() { starts += 1; canCheckForUpdates = true; callback?() }
    func checkForUpdates() { checks += 1; canCheckForUpdates = false; callback?() }
    func observe(_ onChange: @escaping @MainActor () -> Void) { callback = onChange }
}

private func issue611Defaults(_ automatic: Bool = true, _ install: Bool = true) -> UserDefaults {
    let defaults = UserDefaults(suiteName: "issue611-\(UUID().uuidString)")!
    defaults.set(automatic, forKey: "SUEnableAutomaticChecks")
    defaults.set(install, forKey: "SUAutomaticallyUpdate")
    return defaults
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue611BuiltDebugConfigurationNeverConstructsOrStartsUpdater() throws {
    // App tests are a standalone bundle: Bundle.main is the test runner, not Mado.app.
    let url = issue611Repository.appendingPathComponent(".build/dd-ci/Build/Products/Debug/Mado.app/Contents/Info.plist")
    let info = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    #expect(info["SUFeedURL"] as? String == issue611Feed)
    #expect(info["MadoDisableUpdates"] as? String == "YES")
    let native = Issue611Controller(issue611Defaults())
    var constructions = 0
    let port = SparkleUpdatePort(infoDictionary: info, makeController: { constructions += 1; return native })
    // Keep these operations after nonfatal assertions: RED must demonstrate the actual start path.
    port.start()
    #expect(!port.isAvailable, "a built Debug app must not expose the release updater")
    #expect(!port.automaticallyChecksForUpdates)
    #expect(!port.canCheckForUpdates)
    #expect(port.lastUpdateCheckDate == nil)
    #expect(constructions == 0, "Debug currently constructs Sparkle with the release feed")
    #expect(native.starts == 0, "Debug currently forwards startUpdater(), enabling the scheduler")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue611DisabledDebugPreservesEveryStoredPreferenceCombination() {
    for automatic in [false, true] {
        for install in [false, true] {
            let defaults = issue611Defaults(automatic, install)
            let before = defaults.dictionaryRepresentation()
            let native = Issue611Controller(defaults)
            var constructions = 0
            let port = SparkleUpdatePort(infoDictionary: ["SUFeedURL": issue611Feed, "MadoDisableUpdates": "YES"],
                makeController: { constructions += 1; return native })
            var notifications = 0
            port.observe { notifications += 1 }
            for _ in 0..<3 {
                port.start()
                port.checkForUpdates()
                port.automaticallyChecksForUpdates = false
                #expect(defaults.bool(forKey: "SUEnableAutomaticChecks") == automatic)
                port.automaticallyChecksForUpdates = true
                #expect(!port.isAvailable && !port.automaticallyChecksForUpdates && !port.canCheckForUpdates)
                #expect(port.lastUpdateCheckDate == nil)
                #expect(NSDictionary(dictionary: defaults.dictionaryRepresentation()).isEqual(to: before))
                #expect(constructions == 0 && native.starts == 0 && native.checks == 0)
                #expect(notifications == 0)
            }
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue611ReleaseAndLegacyConfigurationKeepExistingUpdateBehavior() {
    for disabled: String? in ["NO", nil] {
        var info: [String: Any] = ["SUFeedURL": issue611Feed]
        if let disabled { info["MadoDisableUpdates"] = disabled }
        let native = Issue611Controller(issue611Defaults())
        let port = SparkleUpdatePort(infoDictionary: info, makeController: { native })
        #expect(port.isAvailable && port.automaticallyChecksForUpdates && port.canCheckForUpdates)
        #expect(port.lastUpdateCheckDate == Date(timeIntervalSince1970: 123))
        port.automaticallyChecksForUpdates = false
        #expect(!native.automaticallyChecksForUpdates)
        var notifications = 0
        port.observe { notifications += 1 }
        port.checkForUpdates()
        #expect(!port.canCheckForUpdates && native.checks == 1)
        port.start()
        #expect(port.canCheckForUpdates && native.starts == 1)
        #expect(notifications == 2)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue611RealDisabledDebugPortIsUnavailable() {
    let port = SparkleUpdatePort(infoDictionary: ["SUFeedURL": issue611Feed, "MadoDisableUpdates": "YES"])
    #expect(!port.isAvailable)
    // On RED the native controller is still stopped; never start/check a real enabled updater here.
    guard !port.isAvailable else { return }
    port.start()
    port.checkForUpdates()
    port.automaticallyChecksForUpdates = true
    #expect(!port.automaticallyChecksForUpdates && !port.canCheckForUpdates)
    #expect(port.lastUpdateCheckDate == nil)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue611DisabledDebugSettingsReuseUnavailableStateAfterClicksAndRefresh() throws {
    let native = Issue611Controller(issue611Defaults())
    let port = SparkleUpdatePort(infoDictionary: ["SUFeedURL": issue611Feed, "MadoDisableUpdates": "YES"],
        makeController: { native })
    let preferences = InMemoryDisplayPreferencesStore()
    let cache = ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let panel = SettingsPanelWindow(cache: cache,
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences, defaults: issue611Defaults(), updates: port)
    defer { panel.window.close() }
    panel.select(.update)
    let automatic = try #require(issue220View("settings.update.automatic", in: panel) as? NSButton)
    let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
    func unavailable() throws {
        #expect(!automatic.isEnabled && automatic.state == .off && !check.isEnabled)
        let pane = try #require(issue220View("settings.pane.update", in: panel))
        let labels = pane.subviews.compactMap { $0 as? NSTextField }.map(\.stringValue)
        #expect(labels.contains(String(localized: "Updates are not available in this build.")))
        #expect(!labels.contains(String(localized: "Mado contacts GitHub only to check for updates and sends no system information.")))
    }
    try unavailable()
    automatic.performClick(nil)
    check.performClick(nil)
    panel.select(.general)
    panel.select(.update)
    try unavailable()
    #expect(!port.isAvailable && !port.automaticallyChecksForUpdates && !port.canCheckForUpdates)
    #expect(native.starts == 0 && native.checks == 0)
}
