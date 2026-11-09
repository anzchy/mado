import AppKit

struct KeyWindowFixtureError: Error, CustomStringConvertible {
    let reason: String
    let state: String
    var description: String { "Key-window fixture: \(reason)\n\(state)" }
}

/// For the stopped, isolated native test host. Callers reserve this budget inside their timeLimit.
/// NSApplication.run() performs permanent launch/event-routing initialization that a bare RunLoop
/// pump does not provide. Always enter it once, even if the window is already key.
@MainActor func makeFixtureWindowKey(_ window: NSWindow, timeout: Duration) throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    guard !NSApp.isRunning else {
        throw KeyWindowFixtureError(reason: "requires a stopped native test host", state: conditionWaitAppKitState())
    }
    guard timeout > .zero else {
        throw KeyWindowFixtureError(reason: "timed out waiting for target window", state: conditionWaitAppKitState())
    }

    var acquired = false
    func requestKey() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
    }
    func stopDispatch() {
        NSApp.stop(nil)
        // stop() alone does not wake nextEvent's blocking wait inside run().
        if let idle = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(idle, atStart: true)
        }
    }
    requestKey()
    // A slice is a retry cadence, never a readiness assumption or a separate timeout budget.
    let remaining = ContinuousClock.now.duration(to: deadline)
    let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
    let timer = Timer(timeInterval: max(0.0001, min(0.01, seconds)), repeats: true) { _ in
        MainActor.assumeIsolated {
            guard ContinuousClock.now < deadline else { stopDispatch(); return }
            requestKey()
            acquired = NSApp.keyWindow === window && window.isKeyWindow
            if acquired { stopDispatch() }
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    NSApp.run()
    guard acquired && NSApp.keyWindow === window && window.isKeyWindow else {
        throw KeyWindowFixtureError(reason: "timed out waiting for target window", state: conditionWaitAppKitState())
    }
}
