import Testing
import MadoCore
@testable import MadoApplication

@Test func issue136ComboGridSearchEscapePrecedesInspector() {
    #expect(!InspectorEscapePolicy.handlesEscape(inspectorVisible: true, menuTracking: false,
        focus: .textInput, keyCode: 53, gridSearchFocused: true))
    #expect(InspectorEscapePolicy.handlesEscape(inspectorVisible: true, menuTracking: false,
        focus: .panel, keyCode: 53, gridSearchFocused: false))
}

@Test func inspectorEscapePrecedesGridTextInputGuard() {
    for focus in [FocusContext.textInput, .panel] {
        #expect(InspectorEscapePolicy.handlesEscape(inspectorVisible: true,
            menuTracking: false, focus: focus, keyCode: 53))
    }
    #expect(!InspectorEscapePolicy.handlesEscape(inspectorVisible: true,
        menuTracking: true, focus: .textInput, keyCode: 53))
    #expect(!InspectorEscapePolicy.handlesEscape(inspectorVisible: false,
        menuTracking: false, focus: .textInput, keyCode: 53))
    #expect(!InspectorEscapePolicy.handlesEscape(inspectorVisible: true,
        menuTracking: false, focus: .canvas, keyCode: 53))
}
