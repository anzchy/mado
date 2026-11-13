import Testing
@testable import MadoMacUI
@Test(.timeLimit(.minutes(2))) func designComponentStateAndActivation() throws {
    for theme in DesignTheme.allCases {
        for kind in ComponentKind.allCases {
            let normal = ComponentResolver.resolve(kind, state: [], theme: theme)
            #expect(!normal.focusRing && normal.opacity == 1 && normal.theme == theme)
            let selected = ComponentResolver.resolve(kind, state: .selected, theme: theme)
            #expect(!selected.focusRing)
            for other: ComponentState in [[], .hover, .pressed, .selected, [.pressed, .selected]] {
                let focused = ComponentResolver.resolve(kind, state: other.union(.keyboardFocused), theme: theme)
                #expect(focused.focusRing)
                #expect(focused.background == ComponentResolver.resolve(kind, state: other, theme: theme).background)
            }
            #expect(ComponentResolver.resolve(kind, state: .disabled, theme: theme).opacity == 0.4)
        }
        #expect(ComponentResolver.resolve(.icon, state: .hover, theme: theme).background == .hoverBackground)
        #expect(ComponentResolver.resolve(.folder, state: .selected, theme: theme).background == .selectionFill)
        #expect(ComponentResolver.resolve(.folder, state: .selected, theme: theme).foreground == .selectionText)
        #expect(ComponentResolver.resolve(.thumbnail, state: .selected, theme: theme).border == .accent)
        #expect(ComponentResolver.resolve(.error, state: [], theme: theme).foreground == .errorText)
        #expect(ComponentResolver.resolve(.search, state: [], theme: theme).background == .inputBackground)
    }
    for source in [ComponentResolver.Activation.click, .keyboard] {
        var calls = 0
        ComponentResolver.activate(source, state: .disabled) { calls += 1 }
        #expect(calls == 0)
        ComponentResolver.activate(source, state: []) { calls += 1 }
        #expect(calls == 1)
    }
    let behavior = try registry()["behaviorReferences"] as! [String: Any]
    #expect(ComponentResolver.transition(reduceMotion: false) == behavior["shortTransitionSeconds"] as? Double)
    #expect(ComponentResolver.transition(reduceMotion: true) == behavior["reducedMotionTransitionSeconds"] as? Double)
}
@Test(.timeLimit(.minutes(2))) func designThumbnailSelectionDoesNotTintImage() {
    for theme in DesignTheme.allCases {
        for state: ComponentState in [[], .selected, .hover, .pressed, [.selected, .keyboardFocused]] {
            #expect(ComponentResolver.resolve(.thumbnail, state: state, theme: theme).background == nil)
        }
    }
}
