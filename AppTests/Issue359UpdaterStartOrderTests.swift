import AppKit
import Testing

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

/// Runs the real launch hook, then closes the windows it opened and restores the main menu it replaced.
@MainActor private func issue359Launch(_ delegate: AppDelegate, then body: () throws -> Void) rethrows {
    let previousMenu = NSApp.mainMenu
    let existing = Set(NSApp.windows.map(\.windowNumber))
    defer {
        NSApp.windows.filter { !existing.contains($0.windowNumber) }.forEach { $0.close() }
        NSApp.mainMenu = previousMenu
    }
    delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
    try body()
}

@MainActor private func visibleViewerWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.windowController is CanvasWindowController && $0.isVisible }
}

@MainActor @Test func issue359LaunchStartsUpdaterOnceAfterFirstWindowIsVisible() {
    _ = NSApplication.shared
    let port = FakeUpdatePort()
    let delegate = AppDelegate()
    delegate.updates = port
    let before = Set(visibleViewerWindows().map(\.windowNumber))
    var newViewerVisibleAtStart: [Bool] = []
    port.onStart = {
        newViewerVisibleAtStart.append(visibleViewerWindows().contains { !before.contains($0.windowNumber) })
    }
    issue359Launch(delegate) {
        #expect(port.startCount == 1)
        #expect(newViewerVisibleAtStart == [true], "the updater starts only once the main window is on screen")
    }
}

@MainActor @Test func issue359ActivationAndRelaunchDoNotStartUpdaterAgain() {
    _ = NSApplication.shared
    let port = FakeUpdatePort()
    let delegate = AppDelegate()
    delegate.updates = port
    issue359Launch(delegate) {
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(port.startCount == 1)
    }
}

@MainActor @Test func issue359LaunchWithoutUpdatePortShowsWindowAndStartsNothing() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    delegate.updates = nil
    let before = Set(visibleViewerWindows().map(\.windowNumber))
    issue359Launch(delegate) {
        #expect(visibleViewerWindows().contains { !before.contains($0.windowNumber) })
        // A port that appears after launch (it never does in the fixture build) is not started by activation either.
        let late = FakeUpdatePort()
        delegate.updates = late
        delegate.applicationDidBecomeActive(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(late.startCount == 0)
    }
}

// The compiled adapter tests cover feed availability. This supplemental source guard pins native forwarding:
// the controller is built stopped, and its start operation uses startUpdater() to preserve Sparkle's alert.
@Test func issue359SparklePortIsBuiltStoppedAndStartsThroughStartUpdater() throws {
    let source = try String(contentsOf: repository.appendingPathComponent("App/Updates/SparkleUpdatePort.swift"),
                            encoding: .utf8)
    #expect(source.contains("startingUpdater: false"))
    #expect(!source.contains("startingUpdater: true"))
    let start = try #require(source.range(of: "func startUpdater() {"))
    let next = try #require(source.range(of: "func ", range: start.upperBound..<source.endIndex))
    let body = source[start.upperBound..<next.lowerBound]
    #expect(body.contains("controller.startUpdater()"))
}
