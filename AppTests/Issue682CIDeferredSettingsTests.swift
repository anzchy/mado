import AppKit
import Testing

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CIDeferredCaptureControlsAreExactAndRejectUnknownDisabledControls() {
    // #689 slice B made the last deferred controls (云端识别, 服务) live.
    let expected: [String: Int] = [:]
    #expect(CaptureDeferredSettingsControls.tickets == expected)
    func disabled(_ id: String) -> NSButton {
        let button = NSButton(title: id, target: nil, action: nil)
        button.setAccessibilityIdentifier(id)
        button.isEnabled = false
        return button
    }
    let controls = [disabled("settings.capture.login"), disabled("settings.capture.extra"),
                    disabled("settings.display.extra")]
    #expect(CaptureDeferredSettingsControls.unexpectedDisabledIDs(controls)
            == ["settings.capture.extra", "settings.display.extra"])
}
