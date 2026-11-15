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
///
/// The registrar's calls are awaits, so actor isolation alone would let `suspend`, `resume` and `apply` interleave
/// (#685 fix r1). Each call records what it wants and waits while one loop at a time moves the registrations there.
public actor CaptureHotKeyCoordinator {
    private let preferences: any CaptureShortcutPreferencePort
    private let registrar: any CaptureHotKeyRegistrarPort
    public private(set) var registered: [CaptureShortcutAction: CaptureKeyCombo] = [:]
    public private(set) var isSuspended = false
    /// What `suspend()` released; a combo refused on resume falls back to it, as a refused rebind does.
    private var released: [CaptureShortcutAction: CaptureKeyCombo] = [:]
    private var wantsSuspended = false
    private var needsApply = false
    private var driving = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var lastRecordingSequence: UInt64?

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
    /// between actions in one change (恢复默认). Does nothing while suspended; `resume()` applies.
    public func apply() async {
        needsApply = true
        await drive()
    }

    /// Releases every hotkey while Settings records a shortcut, so the pressed combo reaches the recorder.
    public func suspend() async {
        wantsSuspended = true
        await drive()
    }

    public func resume() async {
        wantsSuspended = false
        needsApply = true
        await drive()
    }

    /// Settings' recording began/ended notifications, numbered by the helper in the order it received them. One
    /// older than the last seen lost a race between the helper's tasks and is ignored.
    public func recordingChanged(_ recording: Bool, sequence: UInt64) async {
        if let last = lastRecordingSequence, sequence <= last { return }
        lastRecordingSequence = sequence
        if recording { await suspend() } else { await resume() }
    }

    /// Runs until the registrations match what the last calls asked for. A call made while it runs only waits.
    private func drive() async {
        if driving {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        driving = true
        while true {
            if wantsSuspended {
                if !isSuspended { await releaseAll(); continue }
            } else if isSuspended || needsApply {
                isSuspended = false
                needsApply = false
                await register()
                continue
            }
            break
        }
        driving = false
        let done = waiters
        waiters = []
        for waiter in done { waiter.resume() }
    }

    private func releaseAll() async {
        isSuspended = true
        let current = registered
        registered = [:]
        for (action, combo) in current {
            released[action] = combo
            await registrar.unregister(id: Self.hotKeyID(for: action))
        }
    }

    private func register() async {
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
}
