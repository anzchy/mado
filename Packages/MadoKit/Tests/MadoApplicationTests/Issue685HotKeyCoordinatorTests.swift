import Testing
import MadoApplication

// #685 AC-1/AC-2: the helper keeps its registered hotkeys equal to the stored bindings, re-registers on change
// without a restart, and a combo the system refuses is reported (and a refused rebind keeps the old shortcut).

private actor StoredShortcuts: CaptureShortcutPreferencePort {
    var stored: CaptureShortcutBindings
    var refused: [CaptureShortcutAction: CaptureKeyCombo] = [:]
    var bindingWrites = 0
    init(_ stored: CaptureShortcutBindings = .defaults) { self.stored = stored }
    func bindings() -> CaptureShortcutBindings { stored }
    func setBindings(_ bindings: CaptureShortcutBindings) { stored = bindings; bindingWrites += 1 }
    func failures() -> [CaptureShortcutAction: CaptureKeyCombo] { refused }
    func setFailures(_ failures: [CaptureShortcutAction: CaptureKeyCombo]) { refused = failures }
    func edit(_ change: (inout CaptureShortcutBindings) throws -> Void) rethrows { try change(&stored) }
}

private actor FakeRegistrar: CaptureHotKeyRegistrarPort {
    var held: [UInt32: CaptureKeyCombo] = [:]
    var takenByOtherApps: Set<CaptureKeyCombo> = []
    var registerCalls = 0
    var unregisterCalls = 0
    func register(_ combo: CaptureKeyCombo, id: UInt32) -> Bool {
        registerCalls += 1
        // Exclusive, like kEventHotKeyExclusive: a combo held by anyone else is refused.
        guard !takenByOtherApps.contains(combo), !held.values.contains(combo) else { return false }
        held[id] = combo
        return true
    }
    func unregister(id: UInt32) { unregisterCalls += 1; held[id] = nil }
    func take(_ combo: CaptureKeyCombo) { takenByOtherApps.insert(combo) }
    func free(_ combo: CaptureKeyCombo) { takenByOtherApps.remove(combo) }
}

private let f = CaptureKeyCombo(keyCode: 3, key: "F", modifiers: [.control, .option])
private let g = CaptureKeyCombo(keyCode: 5, key: "G", modifiers: [.control, .option])

private func id(_ action: CaptureShortcutAction) -> UInt32 { CaptureHotKeyCoordinator.hotKeyID(for: action) }

@Test(.timeLimit(.minutes(2))) func issue685HotKeyIDsMapBackToTheirActions() {
    let ids = CaptureShortcutAction.allCases.map(CaptureHotKeyCoordinator.hotKeyID(for:))
    #expect(Set(ids).count == CaptureShortcutAction.allCases.count)
    #expect(!ids.contains(0))
    for action in CaptureShortcutAction.allCases {
        #expect(CaptureHotKeyCoordinator.action(forHotKeyID: id(action)) == action)
    }
    #expect(CaptureHotKeyCoordinator.action(forHotKeyID: 0) == nil)
    #expect(CaptureHotKeyCoordinator.action(forHotKeyID: 999) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue685CoordinatorRegistersEveryStoredBindingAtLaunch() async {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    for action in CaptureShortcutAction.allCases {
        #expect(await registrar.held[id(action)] == CaptureShortcutBindings.defaults[action])
    }
    #expect(await coordinator.registered.count == 5)
    #expect(await preferences.refused.isEmpty)
    #expect(await preferences.bindingWrites == 0)
}

@Test(.timeLimit(.minutes(2))) func issue685CoordinatorReRegistersOnlyChangedBindings() async throws {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    try await preferences.edit { try $0.bind(f, to: .window) }
    await coordinator.apply()
    #expect(await registrar.registerCalls == 6)
    #expect(await registrar.unregisterCalls == 1)
    #expect(await registrar.held[id(.window)] == f)
    #expect(await coordinator.registered[.window] == f)
    await coordinator.apply()
    #expect(await registrar.registerCalls == 6)
}

@Test(.timeLimit(.minutes(2))) func issue685RefusedRebindKeepsTheOldShortcutAndRecordsTheCombo() async throws {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    await registrar.take(f)
    try await preferences.edit { try $0.bind(f, to: .region) }
    await coordinator.apply()
    let old = CaptureShortcutBindings.defaults[.region]
    #expect(await registrar.held[id(.region)] == old)
    #expect(await coordinator.registered[.region] == old)
    #expect(await preferences.stored[.region] == old)
    #expect(await preferences.refused == [.region: f])
    // A later successful rebind clears the failure.
    try await preferences.edit { try $0.bind(g, to: .region) }
    await coordinator.apply()
    #expect(await registrar.held[id(.region)] == g)
    #expect(await preferences.refused.isEmpty)
}

@Test(.timeLimit(.minutes(2))) func issue685BindingRefusedAtLaunchIsReportedAndRetried() async {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let taken = CaptureShortcutBindings.defaults[.fullScreen]!
    await registrar.take(taken)
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    #expect(await preferences.refused == [.fullScreen: taken])
    #expect(await coordinator.registered[.fullScreen] == nil)
    #expect(await preferences.stored == .defaults)
    #expect(await preferences.bindingWrites == 0)
    await registrar.free(taken)
    await coordinator.apply()
    #expect(await coordinator.registered[.fullScreen] == taken)
    #expect(await preferences.refused.isEmpty)
}

@Test(.timeLimit(.minutes(2))) func issue685ClearedBindingIsUnregisteredAndItsFailureDropped() async {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let taken = CaptureShortcutBindings.defaults[.toggleBar]!
    await registrar.take(taken)
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    await preferences.edit { $0.clear(.toggleBar); $0.clear(.region) }
    await coordinator.apply()
    #expect(await registrar.held[id(.region)] == nil)
    #expect(await coordinator.registered[.region] == nil)
    #expect(await coordinator.registered[.toggleBar] == nil)
    #expect(await preferences.refused.isEmpty)
}

@Test(.timeLimit(.minutes(2))) func issue685SwappingCombosBetweenActionsInOneApplySucceeds() async throws {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    let one = CaptureShortcutBindings.defaults[.region]!
    let zero = CaptureShortcutBindings.defaults[.toggleBar]!
    // The user had moved ⌃⇧⌘1 to the toggle; 恢复默认 hands it back to region in one change.
    try await preferences.edit { $0.clear(.region); $0.clear(.toggleBar); try $0.bind(one, to: .toggleBar) }
    await coordinator.apply()
    await preferences.edit { $0 = .defaults }
    await coordinator.apply()
    #expect(await registrar.held[id(.region)] == one)
    #expect(await registrar.held[id(.toggleBar)] == zero)
    #expect(await preferences.refused.isEmpty)
}

@Test(.timeLimit(.minutes(2))) func issue685RefusedRebindWhoseOldComboIsAlsoLostStaysRecorded() async throws {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    let old = CaptureShortcutBindings.defaults[.window]!
    await registrar.take(f)
    await registrar.take(old)  // another app grabbed the old one in between
    try await preferences.edit { try $0.bind(f, to: .window) }
    await coordinator.apply()
    #expect(await coordinator.registered[.window] == nil)
    #expect(await preferences.stored[.window] == f)
    #expect(await preferences.refused == [.window: f])
}

// While Settings records a shortcut the helper releases every hotkey, so the pressed combo reaches the recorder
// instead of starting a capture; changes made meanwhile wait for resume.
@Test(.timeLimit(.minutes(2))) func issue685SuspendReleasesEveryHotKeyAndResumeRestoresThem() async {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    await coordinator.suspend()
    #expect(await registrar.held.isEmpty)
    #expect(await coordinator.registered.isEmpty)
    #expect(await coordinator.isSuspended)
    await coordinator.suspend()
    #expect(await registrar.unregisterCalls == 5)
    await preferences.edit { $0.clear(.toggleBar) }
    await coordinator.apply()
    #expect(await registrar.held.isEmpty)
    await coordinator.resume()
    #expect(await !coordinator.isSuspended)
    #expect(await registrar.held[id(.region)] == CaptureShortcutBindings.defaults[.region])
    #expect(await registrar.held[id(.toggleBar)] == nil)
    #expect(await coordinator.registered.count == 4)
}

@Test(.timeLimit(.minutes(2))) func issue685RefusedComboRecordedWhileSuspendedFallsBackToTheOldShortcut() async throws {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.apply()
    await coordinator.suspend()
    await registrar.take(f)
    try await preferences.edit { try $0.bind(f, to: .region) }
    await coordinator.resume()
    let old = CaptureShortcutBindings.defaults[.region]
    #expect(await registrar.held[id(.region)] == old)
    #expect(await preferences.stored[.region] == old)
    #expect(await preferences.refused == [.region: f])
    // The released set is used once: a later refusal has only the live registration to fall back on.
    await coordinator.suspend()
    await coordinator.resume()
    #expect(await coordinator.registered.count == 5)
}

@Test(.timeLimit(.minutes(2))) func issue685ResumeWithoutSuspendIsAnApply() async {
    let preferences = StoredShortcuts()
    let registrar = FakeRegistrar()
    let coordinator = CaptureHotKeyCoordinator(preferences: preferences, registrar: registrar)
    await coordinator.resume()
    #expect(await coordinator.registered.count == 5)
}
