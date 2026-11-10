import AppKit
@testable import Mado
import Darwin
import Testing

/// This must fail under bare xctest even when an NSApplication singleton can be created.
@Test(.timeLimit(.minutes(3))) @MainActor
func issue393RunsInsideRealAppWithLiveDispatchAndActivation() async throws {
    print("[issue393-host] pid=\(getpid()) ppid=\(getppid()) pgid=\(getpgrp()) executable=\(Bundle.main.executableURL?.path ?? "nil")")
    #expect(ProcessInfo.processInfo.environment["SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"] == "1")
    #expect(Bundle.main.bundleIdentifier == "io.github.anzchy.mado")
    let executable = try #require(Bundle.main.executableURL)
    let runningApplication = NSRunningApplication.current
    #expect(runningApplication.processIdentifier == getpid())
    #expect(runningApplication.executableURL?.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath())
    #expect(ProcessInfo.processInfo.processName == "Mado")
    #expect(executable.lastPathComponent == "Mado")
    #expect(executable.deletingLastPathComponent().lastPathComponent == "MacOS")
    #expect(executable.path.contains("Mado.app/Contents/MacOS/Mado"))
    _ = NSApplication.shared
    #expect(NSApp.delegate is AppDelegate)
    try #require(NSApp.isRunning)
    let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 240, height: 160),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    var callbackWhileRunning = false
    let timer = Timer(timeInterval: 0.001, repeats: false) { _ in
        MainActor.assumeIsolated { callbackWhileRunning = NSApp.isRunning }
    }
    RunLoop.main.add(timer, forMode: .common)
    defer { timer.invalidate() }
    try await waitUntil { callbackWhileRunning }
    #expect(callbackWhileRunning)
    try makeFixtureWindowKey(window, timeout: .seconds(15))
    #expect(NSApp.isActive)
    #expect(NSApp.keyWindow === window && window.isKeyWindow)
    #expect(NSApp.isRunning)
}
