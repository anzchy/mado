import AppKit
import Testing

/// Eligibility opens on later run-loop turns after an explicit stopped-host key request,
/// following the first order-front. Automatic activation during the old pump cannot open it.
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
        // Initial order-front and automatic key delivery during run() cannot unlock this gate.
        // The old fixture only arms it at its explicit post-pump makeKey(), too late to wait.
        if firstFrontRequestCompleted && !NSApp.isRunning && turnsRemaining > 0 && eligibilityTimer == nil {
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

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] != "1"),
      .timeLimit(.minutes(3))) @MainActor
func issue564KeyWindowFixturePassesInIsolatedProcess() async throws {
    try await issue521RunNativeTest(filter: "issue564KeyWindowFixtureHandlesDelayedAndNeverKey\\b",
        summary: "Test issue564KeyWindowFixtureHandlesDelayedAndNeverKey() passed")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["PICSEE_ISSUE521_NATIVE_CHILD"] == "1"),
      .timeLimit(.minutes(1))) @MainActor
func issue564KeyWindowFixtureHandlesDelayedAndNeverKey() throws {
    _ = NSApplication.shared
    let previousPolicy = NSApp.activationPolicy()
    _ = NSApp.setActivationPolicy(.regular)
    defer { _ = NSApp.setActivationPolicy(previousPolicy) }
    try #require(!NSApp.isRunning)
    // One quarter of this child's one-minute time limit leaves room for the negative cases.
    let acquisitionBudget: Duration = .seconds(60) / 4

    // Keep the existing fixture order: front request, native pump, explicit key request.
    // The gate arms after that pump, so the immediate precondition is deterministically false.
    let old = DeferredKeyFixtureWindow(turns: 4, title: "ikw-old-sequence")
    NSApp.activate(ignoringOtherApps: true)
    old.makeKeyAndOrderFront(nil)
    issue521StartNativeDispatch()
    old.makeKey()
    #expect(!(NSApp.keyWindow === old && old.isKeyWindow))
    old.close()

    let delayed = DeferredKeyFixtureWindow(turns: 4, title: "ikw-delayed")
    defer { delayed.close() }
    try makeFixtureWindowKey(delayed, timeout: acquisitionBudget)
    #expect(NSApp.keyWindow === delayed && delayed.isKeyWindow)
    #expect(delayed.eligibilityOpenedWhileRunning)
    #expect(!NSApp.isRunning)
    var readyWindowRanNativeDispatch = false
    let probe = Timer(timeInterval: 0, repeats: false) { _ in
        MainActor.assumeIsolated { readyWindowRanNativeDispatch = NSApp.isRunning }
    }
    RunLoop.main.add(probe, forMode: .common)
    defer { probe.invalidate() }
    try makeFixtureWindowKey(delayed, timeout: acquisitionBudget)
    #expect(readyWindowRanNativeDispatch, "ready-window acquisition still initializes native dispatch")
    #expect(NSApp.keyWindow === delayed && delayed.isKeyWindow)
    #expect(!NSApp.isRunning)
    delayed.close()

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
        #expect(!NSApp.isRunning)
    }
}
