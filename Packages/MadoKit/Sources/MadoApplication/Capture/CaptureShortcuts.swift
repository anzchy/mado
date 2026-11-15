import Foundation

/// What a global capture shortcut does (#685, grilling 2.4).
public enum CaptureShortcutAction: String, CaseIterable, Codable, Sendable {
    case region, window, fullScreen, recognizeText, toggleBar
}

public struct CaptureKeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = CaptureKeyModifiers(rawValue: 1)
    public static let shift = CaptureKeyModifiers(rawValue: 2)
    public static let option = CaptureKeyModifiers(rawValue: 4)
    public static let control = CaptureKeyModifiers(rawValue: 8)
}

/// One key with its modifiers. `keyCode` is the macOS virtual key code; `key` is the label shown for it.
public struct CaptureKeyCombo: Hashable, Codable, Sendable {
    public let keyCode: UInt32
    public let key: String
    public let modifiers: CaptureKeyModifiers

    public init(keyCode: UInt32, key: String, modifiers: CaptureKeyModifiers) {
        self.keyCode = keyCode
        self.key = key
        self.modifiers = modifiers
    }

    /// Modifiers in the macOS menu order ⌃⌥⇧⌘, then the key.
    public var display: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + key
    }
}

public enum CaptureShortcutRejection: Error, Equatable, Sendable {
    /// Needs at least one of ⌘ ⌃ ⌥.
    case needsModifier
    /// The key pressed was itself a modifier.
    case needsKey
    /// A macOS screenshot shortcut (⌘⇧3 / ⌘⇧4 / ⌘⇧5 and their variants).
    case systemShortcut(CaptureKeyCombo)
    /// Already bound to another capture action.
    case usedBy(CaptureShortcutAction)
    /// The system refused to register it: another app holds it.
    case unavailable(CaptureKeyCombo)
}

public struct CaptureShortcutBindings: Equatable, Codable, Sendable {
    private var combos: [CaptureShortcutAction: CaptureKeyCombo]

    public init(_ combos: [CaptureShortcutAction: CaptureKeyCombo]) { self.combos = combos }

    /// ⌃⇧⌘1 region, 2 window, 3 full screen, 4 capture and recognise text, 0 show / collapse the bar.
    public static let defaults: CaptureShortcutBindings = {
        let modifiers: CaptureKeyModifiers = [.control, .shift, .command]
        return CaptureShortcutBindings([
            .region: CaptureKeyCombo(keyCode: 18, key: "1", modifiers: modifiers),
            .window: CaptureKeyCombo(keyCode: 19, key: "2", modifiers: modifiers),
            .fullScreen: CaptureKeyCombo(keyCode: 20, key: "3", modifiers: modifiers),
            .recognizeText: CaptureKeyCombo(keyCode: 21, key: "4", modifiers: modifiers),
            .toggleBar: CaptureKeyCombo(keyCode: 29, key: "0", modifiers: modifiers)
        ])
    }()

    /// Virtual key codes of ⌘ ⇧ ⇪ ⌥ ⌃ (left and right) and fn.
    private static let modifierKeyCodes: ClosedRange<UInt32> = 54...63
    /// The 3, 4 and 5 keys: with ⌘⇧ (and any extra modifier, such as ⌃ for the clipboard) they are macOS screenshots.
    private static let systemScreenshotKeyCodes: Set<UInt32> = [20, 21, 23]

    public subscript(action: CaptureShortcutAction) -> CaptureKeyCombo? { combos[action] }

    public func validate(_ combo: CaptureKeyCombo, for action: CaptureShortcutAction) -> CaptureShortcutRejection? {
        if Self.modifierKeyCodes.contains(combo.keyCode) { return .needsKey }
        if combo.modifiers.isDisjoint(with: [.command, .control, .option]) { return .needsModifier }
        if combo.modifiers.isSuperset(of: [.command, .shift]), Self.systemScreenshotKeyCodes.contains(combo.keyCode) {
            return .systemShortcut(combo)
        }
        let other = CaptureShortcutAction.allCases.first { $0 != action && sameKeys(combos[$0], combo) }
        return other.map(CaptureShortcutRejection.usedBy)
    }

    public mutating func bind(_ combo: CaptureKeyCombo, to action: CaptureShortcutAction) throws(CaptureShortcutRejection) {
        if let rejection = validate(combo, for: action) { throw rejection }
        combos[action] = combo
    }

    public mutating func clear(_ action: CaptureShortcutAction) { combos[action] = nil }

    /// The label is only for display; the key code and modifiers decide a clash.
    private func sameKeys(_ bound: CaptureKeyCombo?, _ combo: CaptureKeyCombo) -> Bool {
        bound?.keyCode == combo.keyCode && bound?.modifiers == combo.modifiers
    }
}
