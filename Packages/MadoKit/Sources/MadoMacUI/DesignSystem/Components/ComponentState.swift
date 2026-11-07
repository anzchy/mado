public struct ComponentState: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let hover = Self(rawValue: 1)
    public static let pressed = Self(rawValue: 2)
    public static let selected = Self(rawValue: 4)
    public static let keyboardFocused = Self(rawValue: 8)
    public static let disabled = Self(rawValue: 16)
}
public enum ComponentKind: CaseIterable, Sendable { case icon, folder, thumbnail, search, shortcut, scale, progress, error, status }
public struct ComponentStyle {
    public let foreground: DesignColor
    public let background: DesignColor?
    public let border: DesignColor?
    public let focusRing: Bool
    public let opacity: Double
    public let theme: DesignTheme
}
public enum ComponentResolver {
    public static func resolve(_ kind: ComponentKind, state: ComponentState, theme: DesignTheme) -> ComponentStyle {
        let selected = state.contains(.selected) || state.contains(.pressed)
        let background: DesignColor? = selected ? .selectionFill : state.contains(.hover) ? .hoverBackground : nil
        let foreground: DesignColor = kind == .error ? .errorText : selected && kind == .folder ? .selectionText : .textPrimary
        return ComponentStyle(foreground: foreground,
                              background: kind == .thumbnail ? nil : kind == .search ? .inputBackground : background,
                              border: kind == .thumbnail && state.contains(.selected) ? .accent : nil,
                              focusRing: state.contains(.keyboardFocused), opacity: state.contains(.disabled) ? 0.4 : 1,
                              theme: theme)
    }
    public static func transition(reduceMotion: Bool) -> Double { reduceMotion ? 0 : 0.15 }
    public enum Activation { case click, keyboard }
    public static func activate(_ source: Activation, state: ComponentState, action: () -> Void) {
        guard !state.contains(.disabled) else { return }
        action()
    }
}
