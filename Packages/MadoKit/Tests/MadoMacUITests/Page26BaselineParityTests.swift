import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

/// #354 rows 6/7: permission-denied.html footer and .mock-primary.
/// This baseline runs before production changes; one window per test, yielding between cases.
@Test @MainActor func i354LostFooterAndAppearanceAlreadyMatch() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView = shell
    let folder = URL(fileURLWithPath: "/page26/待整理")
    for width in [1280, 800] {
        window.setContentSize(NSSize(width: width, height: 680))
        for cause: AccessLossCause in [.notFound, .accessExpired, .diskNotConnected, .unknown] {
            shell.showFolderTree(current: GridSidebarFolder(url: folder, count: 2), parent: nil, children: [])
            shell.setCurrentFile("before.jpg")
            shell.setSearchStatus(resultCount: 2, term: "")
            shell.setFooterActionsEnabled(false) // Production lost page inherits reading-disabled search/sort.
            for _ in 0..<2 {
                shell.showFolderTree(current: GridSidebarFolder(url: folder, accessLossCause: cause), parent: nil, children: [])
                shell.setSearchTerm("")
                shell.setReadingStatus(false)
                shell.setCurrentFile("late.jpg")
                shell.setSearchStatus(resultCount: 99, term: "")
                shell.layoutSubtreeIfNeeded()
                let name = try #require(i354FindField("grid.current-file-status", in: shell))
                let count = try #require(i354FindField("grid.folder-count", in: shell))
                #expect(name.stringValue == "\u{2014}" && !name.isHidden)
                #expect(count.stringValue == "Unavailable" && !count.isHidden)
                #expect(name.frame.width >= ceil(name.cell?.cellSize.width ?? .infinity))
                #expect(count.frame.width >= ceil(count.cell?.cellSize.width ?? .infinity))
                #expect(!shell.searchButton.isEnabled && !shell.sortButton.isEnabled)
                #expect(shell.displayButton.isEnabled)
                shell.displayButton.performClick(nil)
                #expect(shell.isDisplayPanelOpen && shell.displayPanel.superview === shell)
                #expect(shell.displayButton.state == .on)
                #expect((shell.displayButton.accessibilityValue() as? NSNumber)?.intValue == 1)
                shell.displayButton.performClick(nil)
                #expect(!shell.isDisplayPanelOpen && shell.displayPanel.superview == nil)
                #expect(shell.displayButton.state == .off)
                shell.toggleSidebar()
                #expect(count.stringValue == "Unavailable")
                shell.showFolderTree(current: GridSidebarFolder(url: folder, count: 2), parent: nil, children: [])
                shell.layoutSubtreeIfNeeded()
                #expect(count.stringValue != "Unavailable")
            }
            await Task.yield()
        }
    }
}

@MainActor private func i354FindField(_ identifier: String, in view: NSView) -> NSTextField? {
    if view.accessibilityIdentifier() == identifier { return view as? NSTextField }
    return view.subviews.lazy.compactMap { i354FindField(identifier, in: $0) }.first
}

@Test @MainActor func i354PrimaryButtonAlreadyUsesRegular13AndEightSixteenPadding() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = LostAccessStateView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    window.contentView = view
    let font = NSFont.systemFont(ofSize: 13, weight: .regular)
    for width in [1280, 800] {
        window.setContentSize(NSSize(width: width, height: 680))
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for (cause, label) in [(AccessLossCause.notFound, "在新位置选择…"), (.accessExpired, "重新选择文件夹…"),
                                   (.notFound, "Choose at New Location…"), (.accessExpired, "Choose Folder Again…")] {
                view.display(cause: cause, text: .init(title: "Title", detail: "Detail", waiting: "Waiting…",
                                                     reselect: label, chooseOther: "Other…"))
                view.layoutSubtreeIfNeeded()
                let button = view.reselectButton
                let titleFont = try #require(button.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
                #expect(button.font == font && titleFont == font)
                #expect(button.attributedTitle.string == label)
                let textWidth = (label as NSString).size(withAttributes: [.font: titleFont]).width
                #expect(abs(button.frame.width - (ceil(textWidth) + 32)) < 0.5)
                #expect(abs(button.frame.height - (ceil(font.ascender - font.descender) + 16)) < 0.5)
                #expect(button.superview === view && !button.isHiddenOrHasHiddenAncestor)
                #expect(button.frame.width >= textWidth)
                await Task.yield()
            }
        }
    }
}
