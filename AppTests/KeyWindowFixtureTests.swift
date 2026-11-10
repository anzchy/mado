import AppKit
@testable import Mado
import Testing

/// Eligibility opens only on later run-loop turns after the first explicit key request.
@MainActor private final class DeferredKeyFixtureWindow: NSWindow {
    private var eligibilityTimer: Timer?
    private var turnsRemaining: Int
    private(set) var eligibilityOpenedWhileRunning = false
    private var eligible = false
    private var firstFrontRequestCompleted = false

    init(turns: Int, title: String) {
        turnsRemaining = turns
        super.init(contentRect: NSRect(x: 80, y: 80, width: 240, height: 160),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        self.title = title
    }

    override var canBecomeKey: Bool { eligible }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        firstFrontRequestCompleted = true
    }

    override func makeKey() {
        // Initial order-front cannot unlock this gate; later native timer turns are required.
        if firstFrontRequestCompleted && turnsRemaining > 0 && eligibilityTimer == nil {
            eligibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.turnsRemaining -= 1
                    if self.turnsRemaining == 0 {
                        self.eligible = true
                        self.eligibilityOpenedWhileRunning = NSApp.isRunning
                        self.eligibilityTimer?.invalidate()
                    }
                }
            }
        }
        super.makeKey()
    }

    override func close() {
        eligibilityTimer?.invalidate()
        super.close()
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func issue564KeyWindowFixtureHandlesDelayedAndNeverKey() async throws {
    _ = NSApplication.shared
    let previousPolicy = NSApp.activationPolicy()
    _ = NSApp.setActivationPolicy(.regular)
    defer { _ = NSApp.setActivationPolicy(previousPolicy) }
    try #require(NSApp.isRunning)
    // One quarter of the existing one-minute limit leaves room for the negative cases.
    let acquisitionBudget: Duration = .seconds(60) / 4

    // The initial synchronous request cannot satisfy deferred native readiness.
    let old = DeferredKeyFixtureWindow(turns: 4, title: "ikw-old-sequence")
    NSApp.activate(ignoringOtherApps: true)
    old.makeKeyAndOrderFront(nil)
    old.makeKey()
    #expect(!(NSApp.keyWindow === old && old.isKeyWindow))
    old.close()

    let delayed = DeferredKeyFixtureWindow(turns: 4, title: "ikw-delayed")
    defer { delayed.close() }
    try makeFixtureWindowKey(delayed, timeout: acquisitionBudget)
    #expect(NSApp.keyWindow === delayed && delayed.isKeyWindow)
    #expect(delayed.eligibilityOpenedWhileRunning)
    #expect(NSApp.isRunning)
    var readyWindowRanNativeDispatch = false
    var readyWindowCallbackDidRun = false
    let probe = Timer(timeInterval: 0, repeats: false) { _ in
        MainActor.assumeIsolated { readyWindowRanNativeDispatch = NSApp.isRunning }
        MainActor.assumeIsolated { readyWindowCallbackDidRun = true }
    }
    RunLoop.main.add(probe, forMode: .common)
    defer { probe.invalidate() }
    try makeFixtureWindowKey(delayed, timeout: acquisitionBudget)
    #expect(readyWindowRanNativeDispatch, "ready-window acquisition preserves live native dispatch")
    #expect(readyWindowCallbackDidRun, "the original ready-window probe actually executes")
    #expect(NSApp.keyWindow === delayed && delayed.isKeyWindow)
    #expect(NSApp.isRunning)
    delayed.close()

    // Repeat the actual delayed-to-ready transition, retaining callback entry separately
    // from the running-state observation so an intermittent failure has a precise witness.
    var missedReadyCallbacks = 0
    var callbacksOutsideRunningApp = 0
    for index in 0..<100 {
        try autoreleasepool {
            let candidate = DeferredKeyFixtureWindow(turns: 4, title: "ikw-ready-transition-\(index)")
            defer { candidate.close() }
            try makeFixtureWindowKey(candidate, timeout: acquisitionBudget)
            var callbackDidRun = false
            var callbackSawRunningApp = false
            let transitionProbe = Timer(timeInterval: 0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    callbackDidRun = true
                    callbackSawRunningApp = NSApp.isRunning
                }
            }
            RunLoop.main.add(transitionProbe, forMode: .common)
            defer { transitionProbe.invalidate() }
            try makeFixtureWindowKey(candidate, timeout: acquisitionBudget)
            if !callbackDidRun { missedReadyCallbacks += 1 }
            if callbackDidRun && !callbackSawRunningApp { callbacksOutsideRunningApp += 1 }
            #expect(NSApp.keyWindow === candidate && candidate.isKeyWindow)
            #expect(NSApp.isRunning)
        }
    }
    #expect(missedReadyCallbacks == 0, "each delayed-to-ready acquisition services its pending native callback")
    #expect(callbacksOutsideRunningApp == 0, "native callbacks keep the actual App event loop running")

    let other = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 220, height: 140),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    other.title = "ikw-other-key"
    defer { other.close() }
    try makeFixtureWindowKey(other, timeout: acquisitionBudget)
    try #require(NSApp.keyWindow === other && other.isKeyWindow)

    var acquisitionEnteredUncancelled = false
    var cancellationCallbackRan = false
    var inFlightFailure: KeyWindowFixtureError?
    var inFlightAcquisition: Task<Void, Error>?
    inFlightAcquisition = Task { @MainActor in
        acquisitionEnteredUncancelled = !Task.isCancelled
        let cancellationProbe = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                cancellationCallbackRan = true
                inFlightAcquisition?.cancel()
            }
        }
        RunLoop.main.add(cancellationProbe, forMode: .common)
        defer { cancellationProbe.invalidate() }
        try makeFixtureWindowKey(other, timeout: acquisitionBudget)
    }
    let acquisition = try #require(inFlightAcquisition)
    do {
        try await acquisition.value
        Issue.record("native callback cancellation must prevent a ready-window success")
    } catch let error as KeyWindowFixtureError {
        inFlightFailure = error
    }
    #expect(acquisitionEnteredUncancelled)
    #expect(cancellationCallbackRan)
    #expect(inFlightFailure?.reason == "cancelled waiting for target window")

    // Zero turns means eligibility never opens. Vary the caller budget to reject a fixed wait.
    for milliseconds in [30, 90, 0] {
        let never = DeferredKeyFixtureWindow(turns: 0, title: "ikw-never-\(milliseconds)")
        defer { never.close() }
        let budget = Duration.milliseconds(milliseconds)
        let started = ContinuousClock.now
        var failure: KeyWindowFixtureError?
        do {
            try makeFixtureWindowKey(never, timeout: budget)
            Issue.record("a never-key window must time out")
        } catch let error as KeyWindowFixtureError {
            failure = error
        }
        let elapsed = started.duration(to: .now)
        let error = try #require(failure)
        #expect(error.reason == "timed out waiting for target window")
        #expect(error.description.contains("NSApp.isActive="))
        #expect(error.description.contains("keyWindow="))
        #expect(error.description.contains("mainWindow="))
        #expect(error.description.contains(never.title))
        #expect(elapsed >= budget)
        #expect(elapsed < budget + .seconds(1), "caller budget must replace the historical fixed wait")
        #expect(!never.isKeyWindow && NSApp.keyWindow !== never)
        #expect(NSApp.keyWindow === other && other.isKeyWindow)
        #expect(NSApp.isRunning)
    }

    // Pair the short budgets above with a longer one: a fixed subsecond wait must fail
    // the lower bound, while the historical two-second wait must fail the upper bound.
    do {
        let never = DeferredKeyFixtureWindow(turns: 0, title: "ikw-never-long-budget")
        defer { never.close() }
        let budget: Duration = .milliseconds(1500)
        let started = ContinuousClock.now
        var failure: KeyWindowFixtureError?
        do {
            try makeFixtureWindowKey(never, timeout: budget)
            Issue.record("a never-key window must respect the longer caller budget")
        } catch let error as KeyWindowFixtureError {
            failure = error
        }
        let elapsed = started.duration(to: .now)
        let error = try #require(failure)
        #expect(error.reason == "timed out waiting for target window")
        #expect(error.description.contains(never.title))
        #expect(elapsed >= budget)
        #expect(elapsed < budget + .milliseconds(250), "caller budget bounds the wait with 250 ms slack")
        #expect(!never.isKeyWindow && NSApp.keyWindow !== never)
        #expect(NSApp.keyWindow === other && other.isKeyWindow)
        #expect(NSApp.isRunning)
    }
    let cancelledWindow = DeferredKeyFixtureWindow(turns: 0, title: "ikw-cancelled")
    defer { cancelledWindow.close() }
    let cancelled = Task { @MainActor in
        try makeFixtureWindowKey(cancelledWindow, timeout: acquisitionBudget)
    }
    cancelled.cancel()
    do { try await cancelled.value; Issue.record("cancelled acquisition must fail") }
    catch let error as KeyWindowFixtureError {
        #expect(error.reason == "cancelled waiting for target window")
        #expect(NSApp.isRunning)
    }

}
