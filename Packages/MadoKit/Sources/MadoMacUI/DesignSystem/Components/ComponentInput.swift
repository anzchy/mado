/// Forced samples render only their supplied state and never dispatch actions.
public enum ComponentInput: Sendable {
    case forced, live
    public func state(_ supplied: ComponentState, hover: Bool = false, focused: Bool = false, pressed: Bool = false) -> ComponentState {
        guard self == .live else { return supplied }
        return supplied.union(hover ? .hover : []).union(focused ? .keyboardFocused : []).union(pressed ? .pressed : [])
    }
}
