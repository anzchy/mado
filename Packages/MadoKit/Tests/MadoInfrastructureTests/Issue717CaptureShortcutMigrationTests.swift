import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

// #717 migration. #685 stored nothing until the first change, then all five bindings at once (also after 恢复默认),
// with no record of which ones the user set. So a stored combo equal to its old ⌃⇧⌘ default counts as a default and
// moves to ⌃⌥; once moved, the stored set is marked so a ⌃⇧⌘ combo the user binds later is not moved again.

private func suite() throws -> (UserDefaults, String) {
    let name = "issue717-\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: name)), name)
}

/// The plist #685 wrote for these bindings.
private func store685(_ bindings: CaptureShortcutBindings, in defaults: UserDefaults) {
    var plist: [String: [String: Any]] = [:]
    for action in CaptureShortcutAction.allCases {
        guard let combo = bindings[action] else { continue }
        plist[action.rawValue] = ["keyCode": Int(combo.keyCode), "key": combo.key, "modifiers": combo.modifiers.rawValue]
    }
    defaults.set(plist, forKey: UserDefaultsCaptureShortcutPreferences.bindingsKey)
}

private let f = CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option, .command])

@Test(.timeLimit(.minutes(2))) func issue717FreshPreferencesReadTheControlOptionDefaults() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let read = await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings()
    #expect(read == .defaults)
    #expect(read[.region] == CaptureKeyCombo(keyCode: 18, key: "1", modifiers: [.control, .option]))
}

@Test(.timeLimit(.minutes(2))) func issue717StoredOldDefaultsMoveAndUserBindingsStay() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    var old = CaptureShortcutBindings.legacyDefaults
    try old.bind(f, to: .region)
    old.clear(.toggleBar)
    store685(old, in: defaults)
    let read = await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings()
    #expect(read == old.replacingLegacyDefaults())
    #expect(read[.region] == f)
    #expect(read[.toggleBar] == nil)
    #expect(read[.window] == CaptureShortcutBindings.defaults[.window])
    // The move is written back, so the other process (helper or Settings) reads the same set.
    #expect(defaults.integer(forKey: UserDefaultsCaptureShortcutPreferences.defaultsVersionKey) == 2)
    let other = UserDefaultsCaptureShortcutPreferences(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(await other.bindings() == read)
}

@Test(.timeLimit(.minutes(2))) func issue717AllOldDefaultsStoredByRestoreDefaultsMove() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    store685(.legacyDefaults, in: defaults)
    #expect(await UserDefaultsCaptureShortcutPreferences(defaults: defaults).bindings() == .defaults)
}

@Test(.timeLimit(.minutes(2))) func issue717AnOldComboBoundAfterTheMoveIsKept() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    store685(.legacyDefaults, in: defaults)
    let preferences = UserDefaultsCaptureShortcutPreferences(defaults: defaults)
    var bindings = await preferences.bindings()
    let chosen = try #require(CaptureShortcutBindings.legacyDefaults[.region])
    try bindings.bind(chosen, to: .region)
    await preferences.setBindings(bindings)
    let again = UserDefaultsCaptureShortcutPreferences(defaults: try #require(UserDefaults(suiteName: name)))
    #expect(await again.bindings()[.region] == chosen)
    #expect(await again.bindings()[.window] == CaptureShortcutBindings.defaults[.window])
}

@Test(.timeLimit(.minutes(2))) func issue717SetBindingsOnFreshPreferencesIsNeverMoved() async throws {
    let (defaults, name) = try suite()
    defer { defaults.removePersistentDomain(forName: name) }
    let preferences = UserDefaultsCaptureShortcutPreferences(defaults: defaults)
    await preferences.setBindings(.legacyDefaults)
    #expect(defaults.integer(forKey: UserDefaultsCaptureShortcutPreferences.defaultsVersionKey) == 2)
    #expect(await preferences.bindings() == .legacyDefaults)
    #expect(UserDefaultsCaptureShortcutPreferences.defaultsVersionKey == "capture.shortcuts.defaultsVersion")
}
