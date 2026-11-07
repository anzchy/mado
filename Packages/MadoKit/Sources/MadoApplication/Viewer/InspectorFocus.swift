import MadoCore

/// Pure focus transitions; the native host applies these to its responder chain.
public struct InspectorFocus: Sendable {
    public private(set) var isVisible = false
    public private(set) var focus: FocusContext = .canvas
    public init() {}
    public mutating func setVisible(_ visible: Bool) {
        isVisible = visible
        if !visible { focus = .canvas }
    }
    public mutating func updateFocus(_ context: FocusContext) {
        if isVisible || context == .canvas || context == .tools { focus = context }
    }
    public mutating func tab(reverse: Bool) {
        if reverse { focus = .canvas }
        else if isVisible { focus = .textInput }
    }
    public mutating func escape() { focus = .canvas }
}
