import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@Test @MainActor func sidebarOpenGlyphRendersAndRowsRespondToUpdates() throws {
    _ = NSApplication.shared
    let parent = URL(fileURLWithPath: "/tmp/Photos")
    let current = parent.appendingPathComponent("Travel")
    let child = current.appendingPathComponent("Day 1")
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    tree.show(current: .init(url: current), parent: .init(url: parent), children: [.init(url: child)])
    tree.layoutSubtreeIfNeeded()
    let openImage = try #require(tree.rows[1].glyph.image)
    let representation = try #require(openImage.tiffRepresentation)
    #expect(!representation.isEmpty)
    #expect(tree.rows[1].canBecomeKeyView)
    let coder = NSKeyedArchiver(requiringSecureCoding: false)
    #expect(GridSidebarFolderButton(coder: coder) == nil)
    #expect(GridSidebarTreeView(coder: coder) == nil)

    tree.updateCount(7, for: parent)
    tree.updateCount(0, for: current)
    tree.updateCount(1234, for: child)
    #expect(tree.rows.map(\.countLabel.stringValue) == ["7", "0", "1234"])
    tree.updateCount(nil, for: child)
    #expect(tree.rows[2].countLabel.isHidden)
    tree.updateCount(2, for: parent.appendingPathComponent("not listed"))
    #expect(tree.rows.map(\.countLabel.stringValue) == ["7", "0", ""])

    tree.viewportWidth = 700
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows[2].frame.minX > tree.rows[1].frame.minX)
    #expect(tree.guide.frame.minY == tree.rows.last?.frame.minY)

    let window = NSWindow(contentRect: tree.bounds, styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView!.addSubview(tree)
    var selected: URL?
    tree.onSelectFolder = { selected = $0 }
    let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: " ",
        charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
    tree.rows[0].keyDown(with: space)
    #expect(selected == parent)
    selected = nil
    let other = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "x",
        charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7))
    tree.rows[0].keyDown(with: other)
    #expect(selected == nil)
    window.close()
}

@Test @MainActor func sidebarShellRoutesRowAndKeepsKeyboardLoop() throws {
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: "/tmp/Photos")
    let child = root.appendingPathComponent("Trip")
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let anchor = NSView()
    shell.linkKeyViews(from: anchor)
    var selected: URL?
    shell.onSelectFolder = { selected = $0 }
    shell.showFolderTree(current: .init(url: root, count: 3), parent: nil, children: [.init(url: child)])
    shell.layoutSubtreeIfNeeded()
    #expect(shell.folderTree.rows.count == 2)
    #expect(shell.folderTree.rows[1].nextKeyView === shell.searchButton)
    #expect(shell.adjacentFooterKeyView(to: shell.folderTree.rows[0], reverse: false) === shell.folderTree.rows[1])
    shell.folderTree.rows[1].performClick(nil)
    #expect(selected == child)
    shell.updateFolderCount(4, for: child)
    #expect(shell.folderTree.rows[1].countLabel.stringValue == "4")
    shell.showFolder(nil)
    #expect(shell.folderTree.isHidden)
}
