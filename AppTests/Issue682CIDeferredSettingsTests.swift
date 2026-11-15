import AppKit
import Testing

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CIDeferredCaptureControlsAreExactAndRejectUnknownDisabledControls() {
    let expected = [
        "settings.capture.ocr-cloud": 689,
        "settings.capture.ocr-service": 689,
    ]
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
