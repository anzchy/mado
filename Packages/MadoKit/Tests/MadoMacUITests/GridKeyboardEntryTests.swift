import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class GridKeyboardHost: ViewerSessionHost {
    var hasImage = true
    var opened: [ItemID] = []
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { opened.append(id) }
    func returnToGrid() {}
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridEntryDefinesCurrentWithoutSelectionThenArrowsPreviewAndEscUseIt() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-keyboard")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let a = FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: root)
    let b = FolderEntry(url: folder.appendingPathComponent("B.jpg"), root: root)
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [a, b], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 300, height: 480))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.display(snapshot, selectedItemID: nil)
    grid.activate()
    #expect(window.firstResponder === grid.collectionView)
    #expect(grid.currentItemID == a.itemID)
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)

    let session = ViewerSession(), host = GridKeyboardHost()
    session.host = host
    session.beginBrowsing(items: [a.itemID, b.itemID], sourceVersion: .init(1), scrollAnchor: a.itemID)
    var selections: [ItemID] = []
    grid.onSelect = { id in
        selections.append(id)
        session.select(id)
    }
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
        isARepeat: false, keyCode: 124))
    grid.collectionView.keyDown(with: right)
    #expect(grid.currentItemID == b.itemID)
    #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 1, section: 0)])
    #expect(selections == [b.itemID])
    #expect(session.selection.currentItemID == b.itemID)
    let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
        isARepeat: false, keyCode: 125))
    let up = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F700}", charactersIgnoringModifiers: "\u{F700}",
        isARepeat: false, keyCode: 126))
    grid.collectionView.keyDown(with: up)
    #expect(grid.currentItemID == a.itemID)
    grid.collectionView.keyDown(with: down)
    #expect(grid.currentItemID == b.itemID)
    grid.collectionView.keyDown(with: right)
    #expect(selections == [b.itemID, a.itemID, b.itemID])
    #expect(session.selection.currentItemID == b.itemID)

    #expect(CommandRouter().route(.enter, from: .key, to: session))
    #expect(host.opened == [b.itemID])
    #expect(CommandRouter().route(.escape, from: .key, to: session))
    grid.activate(currentItemID: session.selection.currentItemID)
    #expect(window.firstResponder === grid.collectionView)
    #expect(grid.currentItemID == b.itemID)

    let unactivated = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 300, height: 480))
    unactivated.display(snapshot, selectedItemID: nil)
    let left = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
        isARepeat: false, keyCode: 123))
    unactivated.collectionView.keyDown(with: left)
    #expect(unactivated.currentItemID == a.itemID)
}
