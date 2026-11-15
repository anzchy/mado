import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #717 (P7-10 CAP-01): the capture shortcuts default to ⌃⌥1/2/3/4/0 (owner 2026-11-15). Settings › 截图 reads the real
// App Group store in a fresh suite here, so these tests cover the fresh-install defaults, 恢复默认, a binding kept from
// #685, the "used by another app" row, the bar tooltips, and that no Mado menu item uses a ⌃⌥ default.

private actor Bar: CaptureBarPreferencePort {
    func isCaptureBarEnabled() -> Bool { true }
    func setCaptureBarEnabled(_ enabled: Bool) {}
    func capturePermissionState() -> CapturePermissionState? { .granted }
}

private actor Folder: CaptureFolderPreferencePort {
    func folderRecord() -> CaptureFolderRecord { .downloads }
    func setFolderRecord(_ record: CaptureFolderRecord) {}
}

private actor LoginItem: CaptureLoginItemPort {
    func status() -> CaptureLoginItemStatus { .notRegistered }
    func register() throws {}
    func unregister() {}
    func openLoginItemsSettings() {}
}

@MainActor private struct Fixture {
    let panel: SettingsPanelWindow
    let store: UserDefaultsCaptureShortcutPreferences
    let defaults: UserDefaults
    let suiteName: String
    var signals: [String] { box.names }
    private let box = Box()

    @MainActor private final class Box { var names: [String] = [] }

    /// `prepare` writes to the fresh suite before Settings first reads it.
    init(prepare: (UserDefaults) -> Void = { _ in }) {
        suiteName = "issue717-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        prepare(defaults)
        store = UserDefaultsCaptureShortcutPreferences(defaults: defaults)
        let preferences = InMemoryDisplayPreferencesStore()
        let box = box
        panel = SettingsPanelWindow(
            cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
            preferencesStore: preferences,
            defaults: UserDefaults(suiteName: "issue717-panel-\(UUID().uuidString)")!,
            capturePreferences: Bar(), captureLocalize: { $0 },
            captureShortcuts: store, captureFolder: Folder(), captureLoginItem: LoginItem(),
            captureSignal: { box.names.append($0) }, captureYieldActivation: { _ in })
        panel.select(.capture)
    }

    func close() {
        panel.window.close()
        defaults.removePersistentDomain(forName: suiteName)
    }

    func view(_ id: String) -> NSView? {
        func walk(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == id { return view }
            for child in view.subviews { if let found = walk(child) { return found } }
            return nil
        }
        return panel.window.contentView.flatMap(walk)
    }

    func field(_ index: Int) throws -> CaptureShortcutField {
        try #require(view(index == 0 ? "settings.capture.shortcut-region" : "settings.capture.shortcut-\(index)")
            as? CaptureShortcutField)
    }

    func titles() -> [String] { (0..<5).map { (try? field($0).title) ?? "" } }

    func message(_ index: Int) throws -> NSTextField {
        try #require(view("settings.capture.shortcut-message-\(index)") as? NSTextField)
    }
}

/// Polls until `condition` holds or about two seconds pass.
@MainActor private func eventually(_ condition: () async -> Bool) async {
    for _ in 0..<200 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private let newDefaults = ["⌃⌥1", "⌃⌥2", "⌃⌥3", "⌃⌥4", "⌃⌥0"]

/// The plist #685 wrote: every binding, no defaults version.
private func store685(_ bindings: CaptureShortcutBindings, in defaults: UserDefaults) {
    var plist: [String: [String: Any]] = [:]
    for action in CaptureShortcutAction.allCases {
        guard let combo = bindings[action] else { continue }
        plist[action.rawValue] = ["keyCode": Int(combo.keyCode), "key": combo.key, "modifiers": combo.modifiers.rawValue]
    }
    defaults.set(plist, forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue717FreshSettingsShowTheControlOptionDefaults() async throws {
    let fixture = Fixture()
    defer { fixture.close() }
    let region = try fixture.field(0)
    await eventually { region.isEnabled && fixture.titles() == newDefaults }
    #expect(region.isEnabled)
    #expect(fixture.titles() == newDefaults)
    #expect(await fixture.store.bindings() == .defaults)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue717RestoreDefaultsSetsAllFiveToControlOption() async throws {
    let fixture = Fixture { defaults in
        var bindings = CaptureShortcutBindings.legacyDefaults
        bindings.clear(.region)
        try? bindings.bind(CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option]), to: .window)
        store685(bindings, in: defaults)
    }
    defer { fixture.close() }
    let restore = try #require(fixture.view("settings.capture.shortcut-restore") as? NSButton)
    await eventually { restore.isEnabled && (try? fixture.field(1).title) == "⌃⌥F" }
    #expect(try fixture.field(1).title == "⌃⌥F")
    restore.performClick(nil)
    await eventually { fixture.titles() == newDefaults }
    #expect(fixture.titles() == newDefaults)
    #expect(await fixture.store.bindings() == .defaults)
    #expect(fixture.signals == [CaptureBarIdentity.shortcutsChangedNotification])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue717BindingTheUserChangedIn685IsKeptAfterTheUpdate() async throws {
    let fixture = Fixture { defaults in
        var bindings = CaptureShortcutBindings.legacyDefaults
        try? bindings.bind(CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option, .command]), to: .region)
        store685(bindings, in: defaults)
    }
    defer { fixture.close() }
    let expected = ["⌃⌥⌘F", "⌃⌥2", "⌃⌥3", "⌃⌥4", "⌃⌥0"]
    await eventually { fixture.titles() == expected }
    #expect(fixture.titles() == expected)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue717ControlOptionDefaultHeldByAnotherAppIsNamedOnItsRow() async throws {
    let fixture = Fixture()
    defer { fixture.close() }
    await fixture.store.setFailures([.fullScreen: try #require(CaptureShortcutBindings.defaults[.fullScreen])])
    NotificationCenter.default.post(name: SettingsPanelWindow.captureSignalNotification, object: nil,
                                    userInfo: ["name": CaptureBarIdentity.shortcutStatusNotification])
    await eventually { (try? fixture.message(2).stringValue.isEmpty) == false }
    #expect(try fixture.message(2).stringValue == "⌃⌥3 is used by another app. Choose another shortcut.")
    #expect(try fixture.message(0).stringValue == "")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue717CaptureBarTooltipsShowTheControlOptionDefaults() throws {
    let ids: [(String, CaptureShortcutAction)] = [("capture.region", .region), ("capture.window", .window),
                                                  ("capture.screen", .fullScreen), ("capture.text", .recognizeText)]
    var labels: [String: String] = [:]
    for (id, action) in ids { labels[id] = CaptureShortcutBindings.defaults[action]?.display }
    let bar = CaptureBarView(localize: { $0 }, captureAction: {}, collapseAction: {}, shortcuts: labels)
    func tip(_ id: String) -> String? {
        (bar.subviews.first { $0.accessibilityIdentifier() == id } as? NSButton)?.toolTip
    }
    #expect(tip("capture.region") == "Region Capture ⌃⌥1")
    #expect(tip("capture.window") == "Window Capture ⌃⌥2")
    #expect(tip("capture.screen") == "Full Screen Capture ⌃⌥3")
    #expect(tip("capture.text") == "Capture and Recognize Text ⌃⌥4")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue717DefaultsDoNotCollideWithMadoMenuShortcuts() throws {
    _ = NSApplication.shared
    let previous = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(), openWithoutWindow: {},
                           openSettings: {}, openDiagnostics: {}, windowController: { nil })
    defer { NSApp.mainMenu = previous; withExtendedLifetime(menu) {} }
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
        (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let all = items(NSApp.mainMenu)
    try #require(all.count > 20)
    let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
    let taken = all.filter { !$0.keyEquivalent.isEmpty }
        .map { ($0.keyEquivalent.lowercased(), $0.keyEquivalentModifierMask.intersection(relevant)) }
    for action in CaptureShortcutAction.allCases {
        let combo = try #require(CaptureShortcutBindings.defaults[action])
        #expect(combo.modifiers == [.control, .option])
        #expect(!taken.contains { $0.0 == combo.key && $0.1 == [.control, .option] },
                "\(combo.display) is a Mado menu shortcut")
    }
}
