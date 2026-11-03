/// A key plus whether it needs ⌘; the menu shows one and catches the rest as hidden alternates.
public struct CommandKeyBinding: Hashable, Sendable {
    public let key: String
    public let command: Bool
    public init(key: String, command: Bool) {
        self.key = key
        self.command = command
    }
}

/// Frozen base commands. Raw values are stable identifiers, independent of UI titles.
public enum CommandID: String, CaseIterable, Sendable {
    case preview, previous, next, escape, enter, fit, actualPixels, zoomIn, zoomOut, search, open, inspector

    public var defaultKey: String {
        switch self {
        case .preview: " "
        case .previous: "\u{f702}"
        case .next: "\u{f703}"
        case .escape: "\u{1b}"
        case .enter: "\r"
        case .fit: "0"
        case .actualPixels: "1"
        case .zoomIn: "+"
        case .zoomOut: "-"
        case .search: "f"
        case .open: "o"
        case .inspector: "i"
        }
    }
    public var usesCommand: Bool { [.search, .open, .inspector].contains(self) }
    public var isImplemented: Bool { [.preview, .enter, .previous, .next, .escape, .fit, .actualPixels, .zoomIn, .zoomOut, .search, .open, .inspector].contains(self) }
    public var shortcutHint: String? { isImplemented ? (usesCommand ? "⌘" + defaultKey.uppercased() : defaultKey) : nil }
    public static var menuCommands: [Self] { allCases.filter { $0.isImplemented && $0 != .search } }
    /// The Preview-style ⌘ form of a zoom command (#348); the bare key keeps working beside it.
    public var commandKey: String? {
        switch self {
        case .fit: "9"
        case .actualPixels: "0"
        case .zoomIn: "+"
        case .zoomOut: "-"
        default: nil
        }
    }
    public var menuBinding: CommandKeyBinding {
        CommandKeyBinding(key: commandKey ?? defaultKey, command: commandKey != nil || usesCommand)
    }
    /// Keys the menu catches without showing them: the bare key, and ⌘= beside ⌘+.
    public var alternateMenuBindings: [CommandKeyBinding] {
        guard commandKey != nil else { return [] }
        let bare = CommandKeyBinding(key: defaultKey, command: usesCommand)
        return self == .zoomIn ? [bare, CommandKeyBinding(key: "=", command: true)] : [bare]
    }
    public static func matching(key: String, command: Bool) -> Self? {
        let normalized = key == "=" ? "+" : (key == "−" ? "-" : key)
        return allCases.first { $0.defaultKey == normalized && $0.usesCommand == command }
            ?? (command ? allCases.first { $0.commandKey == normalized } : nil)
    }
}
