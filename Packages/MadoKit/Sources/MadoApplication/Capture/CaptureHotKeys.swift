/// The shortcut bindings and registration failures Mado Settings and the capture helper share (#685).
public protocol CaptureShortcutPreferencePort: Sendable {
    func bindings() async -> CaptureShortcutBindings
    func setBindings(_ bindings: CaptureShortcutBindings) async
    /// Per action, the combo the system refused to register.
    func failures() async -> [CaptureShortcutAction: CaptureKeyCombo]
    func setFailures(_ failures: [CaptureShortcutAction: CaptureKeyCombo]) async
}

/// System-wide hotkeys (Carbon `RegisterEventHotKey` in the helper).
public protocol CaptureHotKeyRegistrarPort: Sendable {
    /// False when the system refuses, for example because another app holds the combo.
    func register(_ combo: CaptureKeyCombo, id: UInt32) async -> Bool
    func unregister(id: UInt32) async
}

/// Keeps the registered hotkeys equal to the stored bindings. A rebind the system refuses keeps the previous
/// registration, puts the previous binding back and records the refused combo, so Settings can name it.
public actor CaptureHotKeyCoordinator {
    private let preferences: any CaptureShortcutPreferencePort
    private let registrar: any CaptureHotKeyRegistrarPort
    public private(set) var registered: [CaptureShortcutAction: CaptureKeyCombo] = [:]
    public private(set) var isSuspended = false
    /// What `suspend()` released; a combo refused on resume falls back to it, as a refused rebind does.
    private var released: [CaptureShortcutAction: CaptureKeyCombo] = [:]

    public init(preferences: any CaptureShortcutPreferencePort, registrar: any CaptureHotKeyRegistrarPort) {
        self.preferences = preferences
        self.registrar = registrar
    }

    /// 1-based position in `CaptureShortcutAction.allCases`; 0 is never used.
    public static func hotKeyID(for action: CaptureShortcutAction) -> UInt32 {
        UInt32(CaptureShortcutAction.allCases.firstIndex(of: action)!) + 1
    }

    public static func action(forHotKeyID id: UInt32) -> CaptureShortcutAction? {
        let cases = CaptureShortcutAction.allCases
        guard id >= 1, id <= UInt32(cases.count) else { return nil }
        return cases[Int(id) - 1]
    }

    /// Registers what changed since the last call. Every changed hotkey is released first, so combos can move
    /// between actions in one change (恢复默认).
    public func apply() async {
        if isSuspended { return }
        var bindings = await preferences.bindings()
        let storedFailures = await preferences.failures()
        var failures = storedFailures
        // A binding refused at launch (or one cleared after that) has no registration but a failure: retry or drop it.
        let changed = CaptureShortcutAction.allCases.filter {
            bindings[$0] != registered[$0] || (registered[$0] == nil && failures[$0] != nil)
        }
        var previous: [CaptureShortcutAction: CaptureKeyCombo] = [:]
        for action in changed {
            if let old = registered.removeValue(forKey: action) {
                previous[action] = old
                await registrar.unregister(id: Self.hotKeyID(for: action))
            } else if let old = released[action] {
                previous[action] = old
            }
        }
        released = [:]
        var reverted = false
        for action in changed {
            let id = Self.hotKeyID(for: action)
            guard let wanted = bindings[action] else { failures[action] = nil; continue }
            if await registrar.register(wanted, id: id) {
                registered[action] = wanted
                failures[action] = nil
                continue
            }
            failures[action] = wanted
            if let old = previous[action], await registrar.register(old, id: id) {
                registered[action] = old
                bindings.restore(old, for: action)
                reverted = true
            }
        }
        if reverted { await preferences.setBindings(bindings) }
        if failures != storedFailures { await preferences.setFailures(failures) }
    }

    /// Releases every hotkey while Settings records a shortcut, so the pressed combo reaches the recorder.
    /// `apply()` does nothing until `resume()`.
    public func suspend() async {
        if isSuspended { return }
        isSuspended = true
        for (action, combo) in registered {
            released[action] = combo
            await registrar.unregister(id: Self.hotKeyID(for: action))
        }
        registered = [:]
    }

    public func resume() async {
        isSuspended = false
        await apply()
    }
}
