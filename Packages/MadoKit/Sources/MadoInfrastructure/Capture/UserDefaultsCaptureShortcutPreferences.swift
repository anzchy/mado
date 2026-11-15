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

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The shared suite; nil only when the App Group is unavailable.
    public static func shared() -> UserDefaultsCaptureShortcutPreferences? {
        UserDefaults(suiteName: CaptureBarIdentity.appGroupID).map(UserDefaultsCaptureShortcutPreferences.init(defaults:))
    }

    public func bindings() async -> CaptureShortcutBindings {
        defaults.synchronize()
        guard let stored = defaults.dictionary(forKey: Self.bindingsKey) else { return .defaults }
        let bindings = CaptureShortcutBindings(Self.decode(stored))
        guard defaults.integer(forKey: Self.defaultsVersionKey) < Self.defaultsVersion else { return bindings }
        let moved = bindings.replacingLegacyDefaults()
        await setBindings(moved)
        return moved
    }

    public func setBindings(_ bindings: CaptureShortcutBindings) async {
        var combos: [CaptureShortcutAction: CaptureKeyCombo] = [:]
        for action in CaptureShortcutAction.allCases { combos[action] = bindings[action] }
        defaults.set(Self.defaultsVersion, forKey: Self.defaultsVersionKey)
        write(combos, forKey: Self.bindingsKey)
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
