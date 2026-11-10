import AppKit

struct KeyWindowFixtureError: Error, CustomStringConvertible {
    let reason: String
    let state: String
    var description: String { "Key-window fixture: \(reason)\n\(state)" }
}

/// Acquire this exact window inside the running App, without owning or stopping its lifecycle.
/// The caller reserves this monotonic budget within the test's existing time limit.
@MainActor func makeFixtureWindowKey(_ window: NSWindow, timeout: Duration) throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    guard NSApp.isRunning else {
        throw KeyWindowFixtureError(reason: "requires a running App host", state: conditionWaitAppKitState())
    }
    guard timeout > .zero else {
        throw KeyWindowFixtureError(reason: "timed out waiting for target window", state: conditionWaitAppKitState())
    }
    // A short run-loop call can return without servicing a pending native callback.
    // Require a real native turn before claiming readiness; it shares the caller budget.
    var nativeDispatchServiced = false
    let dispatchCheckpoint = Timer(timeInterval: 0, repeats: false) { _ in
        MainActor.assumeIsolated { nativeDispatchServiced = NSApp.isRunning }
    }
    RunLoop.main.add(dispatchCheckpoint, forMode: .common)
    defer { dispatchCheckpoint.invalidate() }
    repeat {
        if Task.isCancelled {
            throw KeyWindowFixtureError(reason: "cancelled waiting for target window", state: conditionWaitAppKitState())
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeKey()
        // Even already-key acquisition services pending native callbacks. This is
        // a retry cadence bounded by the caller deadline, never a readiness delay.
        let remaining = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        RunLoop.current.run(until: Date(timeIntervalSinceNow: max(0, min(0.005, seconds))))
        if Task.isCancelled {
            throw KeyWindowFixtureError(reason: "cancelled waiting for target window", state: conditionWaitAppKitState())
        }
        if ContinuousClock.now >= deadline { break }
        if nativeDispatchServiced && NSApp.keyWindow === window && window.isKeyWindow { return }
    } while ContinuousClock.now < deadline
    throw KeyWindowFixtureError(reason: "timed out waiting for target window", state: conditionWaitAppKitState())
}
