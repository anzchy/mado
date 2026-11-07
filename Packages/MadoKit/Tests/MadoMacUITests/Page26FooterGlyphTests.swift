import AppKit
import CryptoKit
import Testing
import MadoApplication
@testable import MadoMacUI

/// #354 F1: the Unicode oracle comes from the pinned HTML, not native code.
private func fix1PinnedFooterGlyphs(_ name: String) throws -> [String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL
    let states = root.appendingPathComponent("design/prototypes/picsee-browser/states")
    let data = try Data(contentsOf: states.appendingPathComponent("manifest.json"))
    let manifest = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let entries = try #require(manifest["states"] as? [[String: Any]])
    let entry = try #require(entries.first { $0["name"] as? String == name })
    let file = try #require(entry["file"] as? String)
    let bytes = try Data(contentsOf: states.appendingPathComponent(file))
    #expect(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry["sha256"] as? String)
    let html = String(decoding: bytes, as: UTF8.self)
    let pattern = #"<div\b[^>]*class="grid-file-status"[^>]*>\s*<span[^>]*>([^<]*)</span>"#
    let regex = try NSRegularExpression(pattern: pattern)
    return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
        guard let range = Range($0.range(at: 1), in: html) else { return nil }
        let value = String(html[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["—", "–", "-"].contains(value) ? value : nil
    }
}

@MainActor private func fix1FooterName(_ root: NSView) -> NSTextField? {
    if root.accessibilityIdentifier() == "grid.current-file-status" { return root as? NSTextField }
    return root.subviews.lazy.compactMap { fix1FooterName($0) }.first
}

@Test @MainActor func i354Fix1FooterUsesPinnedEmDashAcrossLostTransitions() async throws {
    for (name, count) in [("empty-folder", 1), ("search-empty", 1), ("folder-loading", 2), ("permission-denied", 1)] {
        let glyphs = try fix1PinnedFooterGlyphs(name)
        #expect(glyphs.count == count)
        #expect(glyphs.allSatisfy { $0.unicodeScalars.map(\.value) == [0x2014] })
    }
    let glyph = try #require(try fix1PinnedFooterGlyphs("permission-denied").first)
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    let folder = URL(fileURLWithPath: "/fix1/待整理")
    for width in [1280, 800] {
        window.setContentSize(NSSize(width: width, height: 680))
        for cause: AccessLossCause in [.notFound, .accessExpired, .diskNotConnected, .unknown] {
            for _ in 0..<2 {
                shell.showFolderTree(current: GridSidebarFolder(url: folder, count: 3), parent: nil, children: [])
                shell.setCurrentFile("before.jpg")
                shell.showFolderTree(current: GridSidebarFolder(url: folder, accessLossCause: cause), parent: nil, children: [])
                shell.setCurrentFile("late.jpg")
                shell.setSearchStatus(resultCount: 9, term: "")
                shell.layoutSubtreeIfNeeded()
                let status = try #require(fix1FooterName(shell))
                #expect(status.stringValue == glyph)
                #expect(!status.isHidden && status.frame.width >= ceil(status.cell?.cellSize.width ?? .infinity))
                shell.toggleSidebar()
                #expect(status.stringValue == glyph)
                shell.showFolderTree(current: GridSidebarFolder(url: folder, count: 3), parent: nil, children: [])
                shell.layoutSubtreeIfNeeded()
                #expect(status.stringValue == "late.jpg")
            }
            await Task.yield()
        }
    }
}
