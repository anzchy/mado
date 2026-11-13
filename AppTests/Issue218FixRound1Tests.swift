import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor func fixPanel(
    cache: ThumbnailDiskCache? = nil,
    confirm: ((NSWindow, @escaping (Bool) -> Void) -> Void)? = nil
) -> (SettingsPanelWindow, InMemoryDisplayPreferencesStore) {
    let store = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(
        cache: cache ?? ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: store),
        preferencesStore: store,
        defaults: UserDefaults(suiteName: "issue218-fix-\(UUID().uuidString)")!,
        confirmClear: confirm)
    return (panel, store)
}

@MainActor func fixView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = fixView(id, in: child) { return found }
    }
    return nil
}

@MainActor private func pixels(_ view: NSView) throws -> Data {
    let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: rep)
    let bytes = try #require(rep.bitmapData)
    return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218AppearanceSelectionChangesPixelsAndAccessibleValue() throws {
    let (panel, store) = fixPanel()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        for appearance in [DisplayAppearance.system, .light, .dark] {
            let button = try #require(fixView("settings.appearance.\(appearance.rawValue)", in: root) as? NSButton)
            store.value.appearance = appearance == .system ? .light : .system
            panel.window.appearance = NSAppearance(named: name)
            let offPixels = try pixels(button)
            let offValue = button.accessibilityValue() as? String
            store.value.appearance = appearance
            panel.window.appearance = NSAppearance(named: name)
            let onPixels = try pixels(button)
            #expect(panel.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == name)
            #expect(onPixels != offPixels, "Appearance selection has no rendered difference: \(appearance.rawValue) in \(name.rawValue)")
            #expect(offValue == "0")
            for option in [DisplayAppearance.system, .light, .dark] {
                let candidate = try #require(fixView("settings.appearance.\(option.rawValue)", in: root) as? NSButton)
                #expect((candidate.accessibilityValue() as? String) == (option == appearance ? "1" : "0"))
            }
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218RepeatedAppearanceChoiceRemainsSelectedWithPersistentStore() throws {
    let suite = "issue218-repeat-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let panel = SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: store),
        preferencesStore: store, defaults: defaults)
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    for name in [NSAppearance.Name.aqua, .darkAqua] {
        for appearance in [DisplayAppearance.system, .light, .dark] {
            let button = try #require(fixView("settings.appearance.\(appearance.rawValue)", in: root) as? NSButton)
            store.value.appearance = appearance
            panel.window.appearance = NSAppearance(named: name)
            button.performClick(nil)
            #expect(store.value.appearance == appearance)
            #expect(button.state == .on)
            #expect((button.accessibilityValue() as? String) == "1")
        }
    }
}
