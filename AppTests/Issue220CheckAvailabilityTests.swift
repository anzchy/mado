import AppKit
import Testing
import MadoApplication

// Audit r1 M1: 立即检查 follows the updater's canCheckForUpdates, as Sparkle's own menu validation would.
@MainActor @Test(.timeLimit(.minutes(3))) func issue220CheckNowFollowsUpdaterAvailability() throws {
    let port = FakeUpdatePort()
    port.canCheckForUpdates = false
    let panel = issue220Panel(port)
    defer { panel.window.close() }
    let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
    let automatic = try #require(issue220View("settings.update.automatic", in: panel) as? NSButton)
    #expect(!check.isEnabled, "unavailable at build")
    #expect(automatic.isEnabled, "the toggle does not depend on check availability")
    check.performClick(nil)
    #expect(port.checkCount == 0)

    port.simulateExternal(canCheck: true)
    #expect(check.isEnabled, "available after the change notification")
    check.performClick(nil)
    #expect(port.checkCount == 1)

    port.simulateExternal(canCheck: false)
    #expect(!check.isEnabled, "unavailable again after the change notification")

    port.canCheckForUpdates = true
    panel.select(.general)
    panel.select(.update)
    #expect(check.isEnabled, "refreshed when the section is shown")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue220CheckNowAvailabilityIsIgnoredWithoutPort() throws {
    let panel = issue220Panel(nil)
    defer { panel.window.close() }
    let check = try #require(issue220View("settings.update.now", in: panel) as? NSButton)
    panel.select(.general)
    panel.select(.update)
    #expect(!check.isEnabled)
    #expect(check.accessibilityLabel() == check.title)
}
