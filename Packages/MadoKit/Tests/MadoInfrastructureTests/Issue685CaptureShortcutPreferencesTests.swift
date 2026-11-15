import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #685 AC-1: rebinding persists; Settings writes and the helper reads the same App Group suite.

private func suite() throws -> (UserDefaults, String) {
    let name = "issue685-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}

@Test(.timeLimit(.minutes(2))) func issue685ShortcutBindingsPersistAcrossInstances() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = UserDefaultsCaptureShortcutPreferences(defaults: defaults)
    #expect(await settings.bindings() == .defaults)
    var changed = CaptureShortcutBindings.defaults
    let f = CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option, .shift, .command])
    try changed.bind(f, to: .region)
    changed.clear(.toggleBar)
    await settings.setBindings(changed)
    let helper = UserDefaultsCaptureShortcutPreferences(defaults: try #require(UserDefaults(suiteName: name)))
    let read = await helper.bindings()
    #expect(read == changed)
    #expect(read[.region] == f)
    #expect(read[.toggleBar] == nil)
    #expect(read[.window] == CaptureShortcutBindings.defaults[.window])
}

@Test(.timeLimit(.minutes(2))) func issue685ShortcutFailuresPersistAndClear() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let helper = UserDefaultsCaptureShortcutPreferences(defaults: defaults)
    #expect(await helper.failures().isEmpty)
    let combo = CaptureKeyCombo(keyCode: 18, key: "1", modifiers: [.control, .shift, .command])
    await helper.setFailures([.region: combo])
    let settings = UserDefaultsCaptureShortcutPreferences(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(await settings.failures() == [.region: combo])
    await helper.setFailures([:])
    #expect(await settings.failures().isEmpty)
}

@Test(.timeLimit(.minutes(2))) func issue685UnreadableShortcutDataFallsBackToDefaults() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = UserDefaultsCaptureShortcutPreferences(defaults: defaults)
    defaults.set("garbage", forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
    defaults.set(42, forKey: UserDefaultsCaptureShortcutPreferences.failuresKey)
    #expect(await preferences.bindings() == .defaults)
    #expect(await preferences.failures().isEmpty)
    // Unknown actions and malformed entries are skipped; well-formed ones survive.
    defaults.set(["region": ["keyCode": 3, "key": "F", "modifiers": 12],
                  "window": ["keyCode": "x"],
                  "teleport": ["keyCode": 3, "key": "F", "modifiers": 12]],
                 forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
    let read = await preferences.bindings()
    #expect(read[.region] == CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.option, .control]))
    #expect(read[.window] == nil)
    #expect(read[.fullScreen] == nil)
}

@Test(.timeLimit(.minutes(2))) func issue685ShortcutKeysLiveInTheSharedSuite() {
    #expect(UserDefaultsCaptureShortcutPreferences.bindingsKey == "capture.shortcuts.v1")
    #expect(UserDefaultsCaptureShortcutPreferences.failuresKey == "capture.shortcutFailures.v1")
    #expect(UserDefaultsCaptureShortcutPreferences.shared() != nil)
}
