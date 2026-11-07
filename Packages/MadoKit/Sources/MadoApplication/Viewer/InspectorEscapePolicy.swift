import MadoCore

/// Inspector Escape applies to Inspector controls; an active grid search handles its own Escape.
public enum InspectorEscapePolicy {
    public static func handlesEscape(inspectorVisible: Bool, menuTracking: Bool,
                                     focus: FocusContext, keyCode: UInt16,
                                     gridSearchFocused: Bool = false) -> Bool {
        keyCode == 53 && inspectorVisible && !menuTracking && focus != .canvas && !gridSearchFocused
    }
}
