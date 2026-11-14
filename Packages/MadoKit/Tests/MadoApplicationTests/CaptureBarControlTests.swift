import Testing
import MadoApplication

private actor CaptureBarMemoryPreferences: CaptureBarPreferencePort {
    private var enabled = false
    func isCaptureBarEnabled() -> Bool { enabled }
    func setCaptureBarEnabled(_ value: Bool) { enabled = value }
}

private actor CaptureBarMemoryProcess: CaptureBarProcessPort {
    private var running = false
    private var starts = 0
    private var shouldFailStart = false
    func startCaptureBar() throws {
        if shouldFailStart { throw CaptureBarProcessFailure.failed }
        running = true
        starts += 1
    }
    func stopCaptureBar() { running = false }
    func setStartFailure(_ fail: Bool) { shouldFailStart = fail }
    func state() -> (Bool, Int) { (running, starts) }
}

private enum CaptureBarProcessFailure: Error { case failed }

private actor DelayedRestoreProcess: CaptureBarProcessPort {
    private var continuation: CheckedContinuation<Void, Never>?
    private var running = false
    func startCaptureBar() async {
        await withCheckedContinuation { continuation = $0 }
        running = true
    }
    func stopCaptureBar() { running = false }
    func finishStart() { continuation?.resume(); continuation = nil }
    func hasStarted() -> Bool { continuation != nil }
    func isRunning() -> Bool { running }
}

@Test(.timeLimit(.minutes(2))) func captureBarToggleDuringRestoreEndsConsistent() async throws {
    let preferences = CaptureBarMemoryPreferences()
    await preferences.setCaptureBarEnabled(true)
    let process = DelayedRestoreProcess()
    let control = CaptureBarControl(preferences: preferences, process: process)
    let restoring = Task { try await control.restoreOnMadoLaunch() }
    while !(await process.hasStarted()) { await Task.yield() }
    let toggling = Task { try await control.setEnabled(false) }
    await process.finishStart()
    try await restoring.value
    try await toggling.value
    #expect(await preferences.isCaptureBarEnabled() == false)
    #expect(await process.isRunning() == false)
}

@Test(.timeLimit(.minutes(2))) func captureBarSwitchOffOnOffOnAndRestoreAfterRelaunch() async throws {
    let preferences = CaptureBarMemoryPreferences()
    let process = CaptureBarMemoryProcess()
    let control = CaptureBarControl(preferences: preferences, process: process)
    try await control.restoreOnMadoLaunch()
    #expect(await process.state().0 == false)
    try await control.setEnabled(true)
    #expect(await preferences.isCaptureBarEnabled())
    #expect(await process.state().0)
    try await control.setEnabled(false)
    #expect(await preferences.isCaptureBarEnabled() == false)
    #expect(await process.state().0 == false)
    try await control.setEnabled(true)
    let relaunched = CaptureBarControl(preferences: preferences, process: process)
    try await relaunched.restoreOnMadoLaunch()
    #expect(await process.state().0)
    #expect(await process.state().1 == 3)
}

@Test(.timeLimit(.minutes(2))) func captureBarFailedStartLeavesSwitchOffAndNoProcess() async throws {
    let preferences = CaptureBarMemoryPreferences()
    let process = CaptureBarMemoryProcess()
    await process.setStartFailure(true)
    let control = CaptureBarControl(preferences: preferences, process: process)
    await #expect(throws: CaptureBarProcessFailure.self) { try await control.setEnabled(true) }
    #expect(await preferences.isCaptureBarEnabled() == false)
    #expect(await process.state().0 == false)
}

private actor FailingStopProcess: CaptureBarProcessPort {
    private var running = false
    func startCaptureBar() { running = true }
    func stopCaptureBar() throws { throw CaptureBarProcessFailure.failed }
    func isRunning() -> Bool { running }
}

@Test(.timeLimit(.minutes(2))) func captureBarFailedStopKeepsSwitchOnWhileProcessSurvives() async throws {
    let preferences = CaptureBarMemoryPreferences()
    let process = FailingStopProcess()
    let control = CaptureBarControl(preferences: preferences, process: process)
    try await control.setEnabled(true)
    await #expect(throws: CaptureBarProcessFailure.self) { try await control.setEnabled(false) }
    #expect(await process.isRunning())
    #expect(await preferences.isCaptureBarEnabled())
}
