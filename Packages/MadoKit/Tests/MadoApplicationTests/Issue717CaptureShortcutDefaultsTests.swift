import Testing
import MadoApplication

// #717 (P7-10 CAP-01): the capture shortcuts default to ⌃⌥1/2/3/4/0 instead of #685's ⌃⇧⌘ series (owner 2026-11-15).
// A binding still on its old ⌃⇧⌘ default moves to the new one; a binding the user set is kept.
// Virtual key codes: 1 = 18, 2 = 19, 3 = 20, 4 = 21, 5 = 23, 0 = 29, F = 3.

private func combo(_ keyCode: UInt32, _ key: String, _ modifiers: CaptureKeyModifiers) -> CaptureKeyCombo {
    CaptureKeyCombo(keyCode: keyCode, key: key, modifiers: modifiers)
}

private let ctrlOpt: CaptureKeyModifiers = [.control, .option]
private let ctrlShiftCmd: CaptureKeyModifiers = [.control, .shift, .command]
private let keys: [(CaptureShortcutAction, UInt32, String)] = [
    (.region, 18, "1"), (.window, 19, "2"), (.fullScreen, 20, "3"), (.recognizeText, 21, "4"), (.toggleBar, 29, "0")
]

@Test(.timeLimit(.minutes(2))) func issue717DefaultsAreTheControlOptionSeries() {
    for (action, keyCode, key) in keys {
        #expect(CaptureShortcutBindings.defaults[action] == combo(keyCode, key, ctrlOpt))
        #expect(CaptureShortcutBindings.legacyDefaults[action] == combo(keyCode, key, ctrlShiftCmd))
    }
    #expect(CaptureShortcutBindings.defaults[.region]?.display == "⌃⌥1")
    #expect(CaptureShortcutBindings.defaults[.toggleBar]?.display == "⌃⌥0")
}

@Test(.timeLimit(.minutes(2))) func issue717ControlOptionDigitsPassValidationAndTheRulesStay() {
    let bindings = CaptureShortcutBindings.defaults
    for (action, keyCode, key) in keys {
        #expect(bindings.validate(combo(keyCode, key, ctrlOpt), for: action) == nil)
        #expect(CaptureShortcutBindings([:]).validate(combo(keyCode, key, ctrlOpt), for: action) == nil)
    }
    // Unchanged rules: a duplicate, ⌥-only and the system screenshot keys are refused.
    #expect(bindings.validate(combo(19, "2", ctrlOpt), for: .region) == .usedBy(.window))
    #expect(bindings.validate(combo(18, "1", [.option]), for: .region) == .optionOnly)
    #expect(bindings.validate(combo(18, "1", [.option, .shift]), for: .region) == .optionOnly)
    let system = combo(20, "3", [.command, .shift])
    #expect(bindings.validate(system, for: .region) == .systemShortcut(system))
    // The old ⌃⇧⌘ combos are free again and can be bound by hand.
    #expect(bindings.validate(combo(18, "1", ctrlShiftCmd), for: .region) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue717BindingsStillOnTheOldDefaultsMoveToTheNewOnes() {
    #expect(CaptureShortcutBindings.legacyDefaults.replacingLegacyDefaults() == .defaults)
    #expect(CaptureShortcutBindings.defaults.replacingLegacyDefaults() == .defaults)
}

@Test(.timeLimit(.minutes(2))) func issue717BindingsTheUserSetAreKept() throws {
    var stored = CaptureShortcutBindings.legacyDefaults
    let f = combo(3, "F", [.control, .option, .command])
    try stored.bind(f, to: .region)
    stored.clear(.toggleBar)
    let moved = stored.replacingLegacyDefaults()
    #expect(moved[.region] == f)
    #expect(moved[.toggleBar] == nil)
    #expect(moved[.window] == combo(19, "2", ctrlOpt))
    #expect(moved[.fullScreen] == combo(20, "3", ctrlOpt))
    #expect(moved[.recognizeText] == combo(21, "4", ctrlOpt))
}

@Test(.timeLimit(.minutes(2))) func issue717OldDefaultStaysWhenItsNewDefaultIsTaken() throws {
    // The user put ⌃⌥2 on region; window still on ⌃⇧⌘2 must not move onto region's combo.
    var stored = CaptureShortcutBindings.legacyDefaults
    try stored.bind(combo(19, "2", ctrlOpt), to: .region)
    let moved = stored.replacingLegacyDefaults()
    #expect(moved[.region] == combo(19, "2", ctrlOpt))
    #expect(moved[.window] == combo(19, "2", ctrlShiftCmd))
    #expect(moved[.fullScreen] == combo(20, "3", ctrlOpt))
}

@Test(.timeLimit(.minutes(2))) func issue717SwappedOldCombosAreTheUsersChoice() {
    let swapped = CaptureShortcutBindings([.region: combo(19, "2", ctrlShiftCmd), .window: combo(18, "1", ctrlShiftCmd)])
    let moved = swapped.replacingLegacyDefaults()
    #expect(moved == swapped)
    // The label does not decide: an old default stored with another label still moves.
    let relabelled = CaptureShortcutBindings([.region: combo(18, "!", ctrlShiftCmd)])
    #expect(relabelled.replacingLegacyDefaults()[.region] == combo(18, "1", ctrlOpt))
}
