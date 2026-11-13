import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2)), arguments: [DesignTheme.light, .dark]) @MainActor
func t229LostAccessTextActionUsesPinnedForeground(_ theme: DesignTheme) throws {
    _ = NSApplication.shared
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    view.appearance = NSAppearance(named: theme == .dark ? .darkAqua : .aqua)
    let text = LostAccessStateText(title: "Unable to Access This Folder", detail: "Choose this folder again, or choose another folder to continue.",
        waiting: "Waiting for the disk…", reselect: "Choose Folder Again…", chooseOther: "Choose Another Folder…")
    let page = try PinnedDesign.page("permission-denied")
    let expected = try page.color(theme == .dark ? ".theme-dark" : ".theme-light", "--color-accent-text", viewport: 800)
    for cause in [AccessLossCause.unknown, .diskNotConnected] {
        view.display(cause: cause, text: text)
        view.layoutSubtreeIfNeeded()
        let title = view.chooseOtherButton.attributedTitle
        try #require(title.length > 0)
        let color = try #require(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        var resolved: NSColor?
        view.effectiveAppearance.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        let rgb = try #require(resolved)
        #expect(abs(rgb.redComponent - expected.red) < 0.001)
        #expect(abs(rgb.greenComponent - expected.green) < 0.001)
        #expect(abs(rgb.blueComponent - expected.blue) < 0.001)
    }
}
