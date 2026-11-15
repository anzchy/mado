import Testing
import MadoApplication

// #685 AC-2: a conflicting binding is refused with a message; ⌘⇧3/4/5 cannot be bound (grilling 2.4).
// Virtual key codes: 1 = 18, 2 = 19, 3 = 20, 4 = 21, 5 = 23, 0 = 29, A = 0, F = 3.

private func combo(_ keyCode: UInt32, _ key: String, _ modifiers: CaptureKeyModifiers) -> CaptureKeyCombo {
    CaptureKeyCombo(keyCode: keyCode, key: key, modifiers: modifiers)
}

private let ctrlShiftCmd: CaptureKeyModifiers = [.control, .shift, .command]

@Test(.timeLimit(.minutes(2))) func issue685DefaultsAreTheControlShiftCommandSeries() {
    let defaults = CaptureShortcutBindings.defaults
    #expect(defaults[.region] == combo(18, "1", ctrlShiftCmd))
    #expect(defaults[.window] == combo(19, "2", ctrlShiftCmd))
    #expect(defaults[.fullScreen] == combo(20, "3", ctrlShiftCmd))
    #expect(defaults[.recognizeText] == combo(21, "4", ctrlShiftCmd))
    #expect(defaults[.toggleBar] == combo(29, "0", ctrlShiftCmd))
    #expect(CaptureShortcutAction.allCases.map(\.rawValue)
            == ["region", "window", "fullScreen", "recognizeText", "toggleBar"])
}

@Test(.timeLimit(.minutes(2))) func issue685ComboDisplayUsesMenuOrder() {
    #expect(combo(18, "1", ctrlShiftCmd).display == "⌃⇧⌘1")
    #expect(combo(3, "F", [.command, .option, .control, .shift]).display == "⌃⌥⇧⌘F")
    #expect(combo(3, "F", [.option]).display == "⌥F")
    #expect(combo(3, "F", [.command]).display == "⌘F")
}

@Test(.timeLimit(.minutes(2))) func issue685BindingNeedsCommandControlOrOption() {
    let bindings = CaptureShortcutBindings.defaults
    #expect(bindings.validate(combo(0, "A", []), for: .region) == .needsModifier)
    #expect(bindings.validate(combo(0, "A", [.shift]), for: .region) == .needsModifier)
    for modifiers: CaptureKeyModifiers in [[.command], [.control], [.option], [.option, .shift]] {
        #expect(bindings.validate(combo(0, "A", modifiers), for: .region) == nil)
    }
}

@Test(.timeLimit(.minutes(2))) func issue685BindingNeedsANonModifierKey() {
    let bindings = CaptureShortcutBindings.defaults
    for keyCode in UInt32(54)...63 {
        #expect(bindings.validate(combo(keyCode, "", [.command, .option]), for: .region) == .needsKey)
    }
    #expect(bindings.validate(combo(53, "⎋", [.command, .option]), for: .region) == nil)
    #expect(bindings.validate(combo(64, "F17", [.command, .option]), for: .region) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue685SystemScreenshotCombosAreRefusedWithExtraModifiers() {
    let bindings = CaptureShortcutBindings([:])
    for (keyCode, key) in [(UInt32(20), "3"), (21, "4"), (23, "5")] {
        for extra: CaptureKeyModifiers in [[], [.control], [.option], [.control, .option]] {
            let refused = combo(keyCode, key, extra.union([.command, .shift]))
            #expect(bindings.validate(refused, for: .region) == .systemShortcut(refused))
        }
        // Without both ⌘ and ⇧ the key is free.
        #expect(bindings.validate(combo(keyCode, key, [.command, .control]), for: .region) == nil)
        #expect(bindings.validate(combo(keyCode, key, [.control, .shift]), for: .region) == nil)
    }
    #expect(bindings.validate(combo(22, "6", [.command, .shift]), for: .region) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue685DuplicateBindingNamesTheOtherAction() {
    var bindings = CaptureShortcutBindings.defaults
    let taken = combo(19, "2", ctrlShiftCmd)
    #expect(bindings.validate(taken, for: .region) == .usedBy(.window))
    #expect(throws: CaptureShortcutRejection.usedBy(.window)) { try bindings.bind(taken, to: .region) }
    #expect(bindings[.region] == combo(18, "1", ctrlShiftCmd))
    #expect(throws: CaptureShortcutRejection.systemShortcut(combo(21, "4", [.command, .shift]))) {
        try bindings.bind(combo(21, "4", [.command, .shift]), to: .toggleBar)
    }
    #expect(throws: CaptureShortcutRejection.needsModifier) { try bindings.bind(combo(0, "A", []), to: .toggleBar) }
    #expect(bindings == .defaults)
}

@Test(.timeLimit(.minutes(2))) func issue685RebindingAnActionToItsOwnComboIsAllowed() throws {
    var bindings = CaptureShortcutBindings.defaults
    let own = combo(18, "1", ctrlShiftCmd)
    #expect(bindings.validate(own, for: .region) == nil)
    try bindings.bind(own, to: .region)
    let fresh = combo(3, "F", [.control, .option])
    try bindings.bind(fresh, to: .region)
    #expect(bindings[.region] == fresh)
    // The freed combo can now go to another action.
    try bindings.bind(own, to: .toggleBar)
    #expect(bindings[.toggleBar] == own)
    #expect(bindings.validate(fresh, for: .toggleBar) == .usedBy(.region))
}

@Test(.timeLimit(.minutes(2))) func issue685ClearingLeavesTheActionUnboundAndFreesItsCombo() throws {
    var bindings = CaptureShortcutBindings.defaults
    bindings.clear(.toggleBar)
    #expect(bindings[.toggleBar] == nil)
    try bindings.bind(combo(29, "0", ctrlShiftCmd), to: .region)
    #expect(bindings[.region] == combo(29, "0", ctrlShiftCmd))
    #expect(bindings != .defaults)
}
