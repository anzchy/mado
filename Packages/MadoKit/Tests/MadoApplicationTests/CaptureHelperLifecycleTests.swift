import Testing
import MadoApplication

private actor HelperPreferences: CaptureBarPreferencePort {
    private var enabled = true
    func isCaptureBarEnabled() -> Bool { enabled }
    func setCaptureBarEnabled(_ value: Bool) { enabled = value }
}

private actor HelperExit: CaptureBarExitPort {
    private var exits = 0
    func exitCaptureBar() { exits += 1 }
    func count() -> Int { exits }
}

@Test(.timeLimit(.minutes(2))) func captureHelperExitsOnStoredSwitchOffWithoutMadoSignal() async {
    let preferences = HelperPreferences()
    let exit = HelperExit()
    let lifecycle = CaptureHelperLifecycle(preferences: preferences, exit: exit)
    await preferences.setCaptureBarEnabled(false)
    await lifecycle.switchChanged()
    #expect(await exit.count() == 1)
}

@Test(.timeLimit(.minutes(2))) func captureHelperStaysRunningWhileStoredSwitchIsOn() async {
    let preferences = HelperPreferences()
    #expect(await preferences.capturePermissionState() == nil)
    let exit = HelperExit()
    let lifecycle = CaptureHelperLifecycle(preferences: preferences, exit: exit)
    await lifecycle.switchChanged()
    #expect(await exit.count() == 0)
}
