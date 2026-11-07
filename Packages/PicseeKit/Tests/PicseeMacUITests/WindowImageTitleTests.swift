import AppKit
import Testing
@testable import PicseeMacUI

@MainActor @Test func windowImageTitleFollowsInstallOpeningAndEmptyRescan() {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 100, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
    defer { window.representedURL = nil }
    let first = URL(fileURLWithPath: "/nested/only.png")
    let replacement = URL(fileURLWithPath: "/flat/next.jpg")

    WindowImageTitle.apply(to: window, imageURL: first)
    #expect(window.title == "only.png")
    #expect(window.representedURL == first)

    WindowImageTitle.apply(to: window, imageURL: nil)
    #expect(window.title == "Mado")
    #expect(window.representedURL == nil)

    WindowImageTitle.apply(to: window, imageURL: replacement)
    #expect(window.title == "next.jpg")
    #expect(window.representedURL == replacement)

    WindowImageTitle.apply(to: window, imageURL: nil)
    #expect(window.title == "Mado")
    #expect(window.representedURL == nil)
}
