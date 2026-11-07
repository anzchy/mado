import AppKit
import Foundation
import Testing
import MadoApplication
@testable import MadoMacUI

/// #443: the pinned design follows the App's existing action focus, including 24F's retry.
@Test func i443PinnedActiveStatesHaveExactlyOneInitialAction() throws {
    let loading = try i443HTML("folder-loading")
    #expect(try i443FocusLabels(String(loading.components(separatedBy: "<template")[0])) == ["取消读取"])
    #expect(try i443FocusLabels(i443Template("failed", in: loading)) == ["重试"])
    #expect(try i443FocusLabels(i443Template("volume", in: i443HTML("permission-denied"))) == ["选择其他文件夹…"])
}

/// Component focus capability, not App-controller initial-focus routing. Browser checks cover initial HTML focus.
@Test(arguments: [false, true]) @MainActor
func i443PinnedActionsSupportNativeFocusInBothAppearances(dark: Bool) throws {
    _ = NSApplication.shared
    let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

    let loading = ViewerStateHost(frame: frame, session: ViewerSession())
    window.contentView = loading
    loading.display(.readingFolder)
    loading.layoutSubtreeIfNeeded()
    let cancel = try #require(loading.buttons.first)
    #expect(cancel.accessibilityIdentifier() == "state.cancel-folder")
    #expect(try i443FocusLabels(String(i443HTML("folder-loading").components(separatedBy: "<template")[0])) == ["取消读取"])
    try i443ExpectNativeFocus(cancel, in: window)

    let recovery = LostAccessStateView(frame: frame)
    window.contentView = recovery
    let label = "选择其他文件夹…"
    recovery.display(cause: .diskNotConnected, text: .init(title: "外接磁盘“T7”未连接",
        detail: "连接磁盘后恢复。", waiting: "等待磁盘连接…", reselect: "重新选择文件夹…", chooseOther: label))
    recovery.layoutSubtreeIfNeeded()
    let other = try #require(recovery.buttons.first)
    #expect(other.accessibilityIdentifier() == "access.lost.chooseOther")
    #expect(recovery.buttons.count == 1)
    #expect(try i443FocusLabels(i443Template("volume", in: i443HTML("permission-denied"))) == [other.title])
    try i443ExpectNativeFocus(other, in: window)
}

@MainActor private func i443ExpectNativeFocus(_ button: NSButton, in window: NSWindow) throws {
    #expect(button.isEnabled && !button.isHiddenOrHasHiddenAncestor)
    #expect(button.acceptsFirstResponder)
    #expect(window.makeFirstResponder(button))
    #expect(window.firstResponder === button)
    #expect(button.focusRingType == .exterior)
}

private func i443HTML(_ name: String) throws -> String {
    _ = try PinnedDesign.page(name) // Verify the actual fixture bytes against manifest SHA256 first.
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL
    return try String(contentsOf: root.appendingPathComponent("design/prototypes/picsee-browser/states/\(name).html"), encoding: .utf8)
}

private func i443Template(_ id: String, in html: String) throws -> String {
    let start = try #require(html.range(of: "<template id=\"case-\(id)\">"))
    let tail = html[start.upperBound...]
    let end = try #require(tail.range(of: "</template>"))
    return String(tail[..<end.lowerBound])
}

private func i443FocusLabels(_ html: String) throws -> [String] {
    let buttons = try NSRegularExpression(pattern: #"(?s)<button\b([^>]*)>(.*?)</button>"#)
    let autofocus = try NSRegularExpression(pattern: #"\bdata-autofocus(?:\s|=|$)"#)
    return try buttons.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
        let attributes = String(html[try #require(Range(match.range(at: 1), in: html))])
        guard autofocus.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)) != nil else { return nil }
        return String(html[try #require(Range(match.range(at: 2), in: html))]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
