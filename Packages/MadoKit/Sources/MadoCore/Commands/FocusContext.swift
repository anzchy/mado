public enum FocusContext: Sendable {
    case canvas, panel, textInput
    case tools
}

public enum CommandEntry: CaseIterable, Sendable {
    case menu, button, key
}
