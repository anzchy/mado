import AppKit
import os
import Testing

@Test @MainActor func issue606FailureHookPrintsRedactedAlertStateSynchronouslyAndAsynchronously() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 480, height: 320),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.title = "/Users/i606-secret/Private/photo.jpg"
    let alert = NSAlert()
    alert.messageText = "Grant “/Users/i606-secret/Private/photo.jpg”"
    alert.informativeText = "Open “/Users/i606-secret/Private/Folder”"
    alert.accessoryView = NSTextField(string: "editable-accessory-secret")
    defer {
        if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
        alert.window.orderOut(nil)
        window.close()
    }
    alert.beginSheetModal(for: window, completionHandler: { _ in })
    alert.window.contentView?.layoutSubtreeIfNeeded()
    let output = OSAllocatedUnfairLock(initialState: [String]())
    let sink: @Sendable (String) -> Void = { text in output.withLock { $0.append(text) } }
    let error = conditionWaitFailure("original error", printSink: sink)
    #expect(error.description == "original error")
    let synchronous = try #require(output.withLock { $0.first })
    #expect(synchronous.contains("  appkit: NSApp.isActive="))
    #expect(synchronous.contains("title=\"photo.jpg\""))
    #expect(synchronous.contains("alertText="))
    #expect(synchronous.contains("Grant “photo.jpg”"))
    #expect(synchronous.contains("Open “Folder”"))
    #expect(!synchronous.contains("i606-secret"))
    #expect(!synchronous.contains("/Users/"))
    #expect(!synchronous.contains("editable-accessory-secret"))
    #expect(synchronous.split(separator: "\n").allSatisfy { $0.count <= 1024 })
    output.withLock { $0.removeAll() }
    let backgroundError = await Task.detached { conditionWaitFailure("background error", printSink: sink) }.value
    #expect(backgroundError.description == "background error")
    try await waitUntil("async snapshot reaches the sink", timeout: .seconds(5)) {
        output.withLock { !$0.isEmpty }
    }
    let asynchronous = try #require(output.withLock { $0.first })
    #expect(asynchronous.contains("  appkit(async): NSApp.isActive="))
    #expect(!asynchronous.contains("/Users/"))
}

@Test func issue606StateOutputBoundsWindowsLinesAndAlertFields() {
    let windows = (0..<23).map { index in
        ConditionWaitWindowState(className: "NSWindow", title: "/Users/i606-secret/" + String(repeating: "x", count: 5000),
            isVisible: true, level: index, alertText: ["message", "informative", "third-static-secret"])
    }
    let text = conditionWaitFormatState(active: false, key: nil, main: nil, windows: windows)
    let lines = text.split(separator: "\n")
    #expect(lines.count == 22) // header + 20 windows + omitted-window marker
    #expect(lines.last == "+3 more windows")
    #expect(lines.allSatisfy { $0.count <= 1024 })
    #expect(!text.contains("third-static-secret"))
    #expect(!text.contains("i606-secret"))
    #expect(!text.contains("/Users/"))
    #expect(text.contains("…"))
}
