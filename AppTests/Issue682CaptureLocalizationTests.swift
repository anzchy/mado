import AppKit
import Testing

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureLabelsUseLocalizedValues() throws {
    #expect(SettingsSection.capture.title == String(localized: "Screenshots"))
    let bar = CaptureBarView(captureAction: {})
    let region = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.region" } as? NSButton)
    let screen = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.screen" } as? NSButton)
    #expect(region.title == String(localized: "Region Capture"))
    #expect(screen.title == String(localized: "Full Screen Capture"))
    #expect(region.toolTip == String(localized: "Region Capture"))
}
