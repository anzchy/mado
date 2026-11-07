import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

/// A watched refresh or a recents reload repeats the same page-22 request; keyboard focus must stay on its control.
@Test @MainActor func page22RepeatedRequestKeepsFocusedControl() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView?.addSubview(shell)
    let folder = URL(fileURLWithPath: "/focus/A")
    shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil,
                         children: ["x", "y"].map { GridSidebarFolder(url: folder.appendingPathComponent($0)) })
    let now = Date(timeIntervalSince1970: 1_615_809_600)
    let recent = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/focus/R"), displayName: "R",
                              openedAt: now.addingTimeInterval(-86_400))
    shell.setEmptyFolderState(true, recents: [recent], now: now)
    let tile = try #require(shell.emptyFolderView.tiles.last)
    #expect(window.makeFirstResponder(tile))
    shell.setEmptyFolderState(true, recents: [recent], now: now)
    shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil,
                         children: ["x", "y"].map { GridSidebarFolder(url: folder.appendingPathComponent($0)) })
    #expect(shell.emptyFolderView.tiles.last === tile)
    #expect(window.firstResponder === tile)
    shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil,
                         children: ["x", "y", "z"].map { GridSidebarFolder(url: folder.appendingPathComponent($0)) })
    #expect(shell.emptyFolderView.tiles.map { $0.url.lastPathComponent } == ["x", "y", "z"])
}

/// gpt M1: a live change (a child added or removed, a relative time ticking) keeps focus on the same folder's control,
/// and falls back to the control now at the focused position when that folder is gone.
@Test @MainActor func page22ChangedRequestKeepsFocusByFolderIdentity() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.borderless],
                          backing: .buffered, defer: false)
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    window.contentView?.addSubview(shell)
    let folder = URL(fileURLWithPath: "/focus/A")
    func tree(_ names: [String]) {
        shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: nil,
                             children: names.map { GridSidebarFolder(url: folder.appendingPathComponent($0)) })
    }
    let page = shell.emptyFolderView
    let now = Date(timeIntervalSince1970: 1_615_809_600)
    tree(["x", "y"])
    shell.setEmptyFolderState(true, recents: [], now: now)
    #expect(window.makeFirstResponder(try #require(page.tiles.last)))
    tree(["w", "x", "y", "z"])
    #expect((window.firstResponder as? EmptyFolderTile)?.url.lastPathComponent == "y", "added children")
    tree(["w", "y"])
    #expect((window.firstResponder as? EmptyFolderTile)?.url.lastPathComponent == "y", "removed children")
    tree(["w"])
    #expect(window.firstResponder === page.keyViews[1], "focused folder gone: the control at its position")
    #expect(window.makeFirstResponder(page.chooseButton))
    tree(["v", "w"])
    #expect(window.firstResponder === page.chooseButton)

    let recents = ["P", "Q"].enumerated().map { index, name in
        RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/focus/\(name)"), displayName: name,
                     openedAt: now.addingTimeInterval(-Double(index + 1) * 86_400))
    }
    tree([])
    shell.setEmptyFolderState(true, recents: recents, now: now)
    let q = try #require(page.recentRows.last)
    #expect(q.folder == recents[1] && window.makeFirstResponder(q))
    let shownBefore = q.whenLabel.stringValue
    let later = now.addingTimeInterval(7 * 86_400)
    shell.setEmptyFolderState(true, recents: recents, now: later)
    let focused = try #require(window.firstResponder as? EmptyFolderRecentButton, "relative time ticked")
    #expect(focused.folder == recents[1])
    #expect(focused.whenLabel.stringValue != shownBefore, "the row shows the new relative time")
    shell.setEmptyFolderState(true, recents: [recents[1], recents[0]].map {
        RecentFolder(rootID: $0.rootID, url: $0.url, displayName: $0.displayName, openedAt: later)
    }, now: later)
    #expect((window.firstResponder as? EmptyFolderRecentButton)?.folder.url == recents[1].url, "reopened: same folder")
}
