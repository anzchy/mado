import AppKit
import Testing

@MainActor @Test(.timeLimit(.minutes(3))) func issue683CaptureBarEnablesRegionAndWindowButLeavesTextDisabled() throws {
    let bar = CaptureBarView(captureAction: {})
    let region = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.region" } as? NSButton)
    let window = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.window" } as? NSButton)
    let text = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.text" } as? NSButton)
    #expect(region.isEnabled)
    #expect(window.isEnabled)
    #expect(!text.isEnabled)
    #expect(region.toolTip?.contains("⌃") != true)
    #expect(window.toolTip?.contains("⌃") != true)
}
