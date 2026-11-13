import AppKit
import Testing

/// Reuse the unchanged output assertions with both an empty fixture and a cap-filling backlog.
/// Existing windows belonging to other tests are deliberately left alone.
@Test(.timeLimit(.minutes(3)), .serialized, arguments: [0, 25]) @MainActor
func issue606FailureHookIncludesCurrentWindowsWithPreexistingWindows(preexistingWindowCount: Int) async throws {
    _ = NSApplication.shared
    var olderWindows: [NSWindow] = []
    defer {
        for window in olderWindows {
            window.orderOut(nil)
            window.close()
        }
    }
    for index in 0..<preexistingWindowCount {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 160, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "issue606-older-window-\(index)"
        window.orderFront(nil)
        olderWindows.append(window)
    }
    if preexistingWindowCount > 20 {
        #expect(NSApp.windows.count > 20)
        #expect(olderWindows.allSatisfy { $0.windowNumber > 0 })
        let backlog = conditionWaitAppKitState().split(separator: "\n")
        #expect(backlog.filter { $0.hasPrefix("class=") }.count == 20)
        #expect(backlog.last?.hasSuffix(" more windows") == true)
    }
    // This creates its own newer window and alert, and checks actual sync/async hook output,
    // redacted title, both alert labels, accessory exclusion and line bounds.
    try await issue606FailureHookPrintsRedactedAlertStateSynchronouslyAndAsynchronously()
}
