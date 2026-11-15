import Testing
import MadoApplication

// #685 AC-4 (logic part): the 「登录时启动」 switch reflects SMAppService.status, shows the approval state, is greyed
// while the bar is off (grilling 5.2), and turning the bar off removes the login item.

@Test(.timeLimit(.minutes(2))) func issue685LoginPresentationFollowsTheSystemStatus() {
    #expect(CaptureLoginPresentation.make(status: .enabled, barEnabled: true)
            == CaptureLoginPresentation(isOn: true, isEditable: true, needsApproval: false))
    #expect(CaptureLoginPresentation.make(status: .notRegistered, barEnabled: true)
            == CaptureLoginPresentation(isOn: false, isEditable: true, needsApproval: false))
    #expect(CaptureLoginPresentation.make(status: .requiresApproval, barEnabled: true)
            == CaptureLoginPresentation(isOn: true, isEditable: true, needsApproval: true))
    #expect(CaptureLoginPresentation.make(status: .notFound, barEnabled: true)
            == CaptureLoginPresentation(isOn: false, isEditable: false, needsApproval: false))
    for status: CaptureLoginItemStatus in [.enabled, .notRegistered, .requiresApproval, .notFound] {
        #expect(!CaptureLoginPresentation.make(status: status, barEnabled: false).isEditable)
        #expect(!CaptureLoginPresentation.make(status: status, barEnabled: false).needsApproval)
    }
    #expect(CaptureLoginPresentation.make(status: .enabled, barEnabled: false).isOn)
}

private actor Switch: CaptureBarPreferencePort {
    var enabled = false
    func isCaptureBarEnabled() -> Bool { enabled }
    func setCaptureBarEnabled(_ value: Bool) { enabled = value }
}

private actor Process: CaptureBarProcessPort {
    func startCaptureBar() {}
    func stopCaptureBar() {}
}

private enum Refused: Error { case refused }

private actor LoginItem: CaptureLoginItemPort {
    var current = CaptureLoginItemStatus.enabled
    var unregisterCalls = 0
    var failUnregister = false
    func status() -> CaptureLoginItemStatus { current }
    func register() { current = .enabled }
    func unregister() throws {
        unregisterCalls += 1
        if failUnregister { throw Refused.refused }
        current = .notRegistered
    }
    func openLoginItemsSettings() {}
    func failNextUnregister() { failUnregister = true }
}

@Test(.timeLimit(.minutes(2))) func issue685TurningTheBarOffRemovesTheLoginItem() async throws {
    let login = LoginItem()
    let control = CaptureBarControl(preferences: Switch(), process: Process(), loginItem: login)
    try await control.setEnabled(true)
    #expect(await login.unregisterCalls == 0)
    try await control.setEnabled(false)
    #expect(await login.unregisterCalls == 1)
    #expect(await login.current == .notRegistered)
    // A refused unregister does not undo turning the bar off.
    await login.register()
    await login.failNextUnregister()
    let preferences = Switch()
    let other = CaptureBarControl(preferences: preferences, process: Process(), loginItem: login)
    try await other.setEnabled(false)
    #expect(await preferences.enabled == false)
    #expect(await login.unregisterCalls == 2)
}
