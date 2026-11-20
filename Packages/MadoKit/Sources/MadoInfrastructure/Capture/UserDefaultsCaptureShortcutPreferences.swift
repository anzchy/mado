import Foundation
import MadoApplication

/// Shortcut bindings and registration failures in the App Group defaults (#685). Nothing stored means the defaults.
///
/// #717 changed the defaults from ⌃⇧⌘ to ⌃⌥. #685 wrote all five bindings on the first change and kept no record of
/// which ones the user set, so a stored set without `defaultsVersionKey` is moved once with
/// `replacingLegacyDefaults()` and written back with the version.
public final class UserDefaultsCaptureShortcutPreferences: CaptureShortcutPreferencePort, @unchecked Sendable {
    public static let bindingsKey = "capture.shortcuts.v1"
    public static let failuresKey = "capture.shortcutFailures.v1"
    public static let defaultsVersionKey = "capture.shortcuts.defaultsVersion"
    /// 2: the stored bindings are on the ⌃⌥ defaults of #717 (none or 1: #685's ⌃⇧⌘).
    static let defaultsVersion = 2
    private let defaults: UserDefaults
    private let afterEachRead: (@Sendable () async -> Void)?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.afterEachRead = nil
    }

    /// Package tests run another process's write after any one read of the suite; never used by the App or helper.
    init(defaults: UserDefaults, afterEachRead: @escaping @Sendable () async -> Void) {
        self.defaults = defaults
        self.afterEachRead = afterEachRead
    }

    /// The shared suite; nil only when the App Group is unavailable.
    public static func shared() -> UserDefaultsCaptureShortcutPreferences? {
        UserDefaults(suiteName: CaptureBarIdentity.appGroupID).map(UserDefaultsCaptureShortcutPreferences.init(defaults:))
    }

    public func bindings() async -> CaptureShortcutBindings {
        defaults.synchronize()
        // A migration writes bindings before version. Reading version first cannot pair old bindings with version 2.
        let version = await read { $0.integer(forKey: Self.defaultsVersionKey) }
        guard let stored = await read({ $0.dictionary(forKey: Self.bindingsKey) }) else { return .defaults }
        let bindings = CaptureShortcutBindings(Self.decode(stored))
        guard version < Self.defaultsVersion else { return bindings }
        return await migrateStoredSet()
    }

    /// Moves #685's stored set to the #717 defaults without overwriting a save that landed after the first reads.
    /// Settings and the Capture Helper are separate processes on one suite, and UserDefaults has no compare-and-set,
    /// so the stored state is read again just before the write. Version 2 there means another process saved or
    /// migrated: its set wins and nothing is written. Otherwise the set now stored is moved, not the one read first, so an
    /// action changed since keeps its value (`replacingLegacyDefaults()` moves only combos still on the old defaults).
    /// Not atomic: a write landing between this re-read and the write below is still overwritten; no suspension point
    /// separates them in the App or the helper.
    private func migrateStoredSet() async -> CaptureShortcutBindings {
        defaults.synchronize()
        let version = await read { $0.integer(forKey: Self.defaultsVersionKey) }
        // Nothing stored means the defaults: another process cleared the suite, and the first read is not written back.
        guard let stored = await read({ $0.dictionary(forKey: Self.bindingsKey) }) else { return .defaults }
        let current = CaptureShortcutBindings(Self.decode(stored))
        guard version < Self.defaultsVersion else { return current }
        let moved = current.replacingLegacyDefaults()
        await setBindings(moved)
        return moved
    }

    /// Every read of the shared suite in `bindings()` goes through here, so the test seam follows the reads, not a line.
    private func read<Value>(_ body: (UserDefaults) -> Value) async -> Value {
        let value = body(defaults)
        if let afterEachRead { await afterEachRead() }
        return value
    }

    public func setBindings(_ bindings: CaptureShortcutBindings) async {
        var combos: [CaptureShortcutAction: CaptureKeyCombo] = [:]
        for action in CaptureShortcutAction.allCases { combos[action] = bindings[action] }
        // Bindings first, version last: an exit between the two leaves the version unset, and the next read moves
        // the stored set again. `replacingLegacyDefaults()` leaves a moved set unchanged, so the rerun ends the same.
        write(combos, forKey: Self.bindingsKey)
        defaults.set(Self.defaultsVersion, forKey: Self.defaultsVersionKey)
        defaults.synchronize()
    }

    public func failures() async -> [CaptureShortcutAction: CaptureKeyCombo] {
        defaults.synchronize()
        return Self.decode(defaults.dictionary(forKey: Self.failuresKey) ?? [:])
    }

    public func setFailures(_ failures: [CaptureShortcutAction: CaptureKeyCombo]) async {
        write(failures, forKey: Self.failuresKey)
    }

    private func write(_ combos: [CaptureShortcutAction: CaptureKeyCombo], forKey key: String) {
        var plist: [String: [String: Any]] = [:]
        for (action, combo) in combos {
            plist[action.rawValue] = ["keyCode": Int(combo.keyCode), "key": combo.key, "modifiers": combo.modifiers.rawValue]
        }
        defaults.set(plist, forKey: key)
        defaults.synchronize()
    }

    /// Unknown actions and malformed entries are skipped.
    private static func decode(_ plist: [String: Any]) -> [CaptureShortcutAction: CaptureKeyCombo] {
        var combos: [CaptureShortcutAction: CaptureKeyCombo] = [:]
        for (name, value) in plist {
            guard let action = CaptureShortcutAction(rawValue: name), let entry = value as? [String: Any],
                  let keyCode = entry["keyCode"] as? Int, let key = entry["key"] as? String,
                  let modifiers = entry["modifiers"] as? Int else { continue }
            combos[action] = CaptureKeyCombo(keyCode: UInt32(keyCode), key: key,
                                             modifiers: CaptureKeyModifiers(rawValue: modifiers))
        }
        return combos
    }
}
