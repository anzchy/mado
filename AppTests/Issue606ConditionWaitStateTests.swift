import AppKit
import Testing

@Test func issue606StateFormatterRedactsPathsAndPreservesWindowFields() {
    let windows = [ConditionWaitWindowState(className: "NSWindow", title: "/Users/alice/Private Photos/photo.jpg",
        isVisible: true, level: 3, attachedSheet: "_NSAlertPanel /tmp/secret/Grant",
        alertText: ["Access /Users/alice/Private Photos/photo.jpg", "Open “file:///home/bob/private/Folder”"])]
    let formatted = conditionWaitFormatState(active: false, key: "/Users/alice/Private Photos/photo.jpg", main: nil, windows: windows)
    #expect(formatted.contains("NSApp.isActive=false"))
    #expect(formatted.contains("keyWindow=\"photo.jpg\" mainWindow=nil"))
    #expect(formatted.contains("class=NSWindow title=\"photo.jpg\" isVisible=true level=3"))
    #expect(formatted.contains("attachedSheet=\"_NSAlertPanel Grant\""))
    #expect(formatted.contains("Access photo.jpg"))
    #expect(formatted.contains("Folder"))
    #expect(!formatted.contains("alice"))
    #expect(!formatted.contains("bob"))
    #expect(!formatted.contains("/"))
    #expect(formatted.split(separator: "\n").count == 2)
}

@Test func issue606StateRedactionIsIdempotentAndKeepsSafeText() {
    for text in ["Browsing Needs Folder Access", "/tmp/private/photo.jpg", "~/Photos/photo.jpg",
                 "file:///Users/alice/Private%20Photos/photo.jpg", "Open “/home/bob/Private Photos/Folder”",
                 "/Users/alice", "first\nsecond\tthird"] {
        let redacted = conditionWaitRedact(text)
        #expect(conditionWaitRedact(redacted) == redacted)
        #expect(!redacted.contains("/"))
        #expect(!redacted.contains("alice"))
        #expect(!redacted.contains("bob"))
        #expect(!redacted.contains("\n"))
    }
    #expect(conditionWaitRedact("Browsing Needs Folder Access") == "Browsing Needs Folder Access")
    #expect(conditionWaitRedact("MadoAppTests/File.swift:12") == "MadoAppTests/File.swift:12")
    #expect(conditionWaitRedact("/tmp/a/photo.jpg") == conditionWaitRedact("/Users/alice/Other/photo.jpg"))
    #expect(conditionWaitFormatState(active: true, key: nil, main: nil, windows: []).contains("NSApp.isActive=true keyWindow=nil mainWindow=nil"))
}

// Catch expected helper failures: this tests the integration without leaving a failing test on main.
@Test @MainActor func issue606WaitFailuresIncludeAppKitState() async throws {
    _ = NSApplication.shared
    do {
        try await Task.detached {
            try await waitUntil("issue606 async", timeout: .zero, fileID: "fixture", line: 606) { false }
        }.value
        Issue.record("expected wait failure")
    } catch let error as ConditionWaitError {
        #expect(error.description == "wait timed out after 0.0 seconds at fixture:606 (issue606 async)")
        print(error.description)
    }
    do {
        try runLoopUntil("issue606 run loop", timeout: .zero, fileID: "fixture", line: 606) { false }
        Issue.record("expected run loop failure")
    } catch let error as ConditionWaitError {
        #expect(error.description == "run loop wait timed out after 0.0 seconds at fixture:606 (issue606 run loop)")
        print(error.description)
    }
}
