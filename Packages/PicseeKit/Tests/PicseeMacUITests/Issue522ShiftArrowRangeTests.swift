import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

/// #522 / GRID-04 / GRID-05: reproduction only. Native arrow delivery is real;
/// the preview command below checks session semantics, not the App's Space bridge.
@Test(arguments: [1, 3]) @MainActor
func issue522SingleSelectionShiftRightTwiceExtendsContiguousRange(start: Int) throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-issue522")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<7).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let ids = entries.map(\.itemID)
    let session = ViewerSession()
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[start])
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
    // NSWindow releases on close by default; ARC owns this fixture.
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = grid
    // Same public selection/focus callbacks used by CanvasWindowController.
    grid.onSelectionGesture = { id, modifier in
        session.select(id, modifier: modifier)
        return session.selection
    }
    grid.onSelect = { session.select($0) }
    grid.onCurrentChange = { session.focus($0) }
    grid.onDeselect = { session.clearSelection(); grid.synchronizeSelection(session.selection) }
    defer { grid.onDeselect = nil }
    grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true), selection: session.selection)
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    let tile = try #require(grid.collectionView.collectionViewLayout?
        .layoutAttributesForItem(at: IndexPath(item: start, section: 0))).frame
    let point = grid.collectionView.convert(NSPoint(x: tile.midX, y: tile.midY), to: nil)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    grid.collectionView.mouseDown(with: click)
    try #require(window.firstResponder === grid.collectionView)
    try #require(session.selection.selectedItemIDs == [ids[start]])
    try #require(grid.collectionView.selectionIndexPaths == [IndexPath(item: start, section: 0)])
    try #require(session.selection.anchorItemID == ids[start])

    for step in 1...2 {
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: Double(step), windowNumber: window.windowNumber, context: nil,
            characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
        window.sendEvent(right)
        let expected = Set(ids[start...start + step])
        let selectedIndexes = grid.collectionView.selectionIndexPaths.map(\.item).sorted()
        print("i522 start=\(start) step=\(step) native=\(selectedIndexes) session=\(ids.indices.filter { session.selection.selectedItemIDs.contains(ids[$0]) }) current=\(String(describing: session.selection.currentItemID.flatMap { ids.firstIndex(of: $0) })) anchor=\(String(describing: session.selection.anchorItemID.flatMap { ids.firstIndex(of: $0) }))")
        #expect(session.selection.selectedItemIDs == expected, "start=\(start) step=\(step): contiguous session selection")
        #expect(grid.selection.selectedItemIDs == expected, "start=\(start) step=\(step): contiguous grid selection")
        #expect(grid.collectionView.selectionIndexPaths == Set((start...start + step).map { IndexPath(item: $0, section: 0) }))
        #expect(session.selection.selectedItemIDs.count == step + 1)
        #expect(session.selection.anchorItemID == ids[start])
        #expect(grid.selection.anchorItemID == ids[start])
        #expect(session.selection.currentItemID == ids[start + step])
        #expect(grid.currentItemID == ids[start + step])
    }
    // No synthetic Space bridge: only the actual App can establish that wiring.
    #expect(CommandRouter().route(.preview, from: .key, to: session))
    #expect(session.previewSet?.itemIDs == Array(ids[start...start + 2]))
    #expect(CommandRouter().route(.escape, from: .key, to: session))
    #expect(session.selection.selectedItemIDs == Set(ids[start...start + 2]))
    #expect(session.selection.anchorItemID == ids[start])
}

@MainActor private final class Issue522RangeFixture {
    let ids: [ItemID]
    let session = ViewerSession()
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
    let window: NSWindow
    let hasCallbacks: Bool

    init(start: Int, callbacks: Bool = true) throws {
        _ = NSApplication.shared
        hasCallbacks = callbacks
        let folder = URL(fileURLWithPath: "/tmp/picsee-issue522-range")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
        let entries = (0..<24).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
        ids = entries.map(\.itemID)
        session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: ids[start])
        window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = grid
        if callbacks {
            grid.onSelectionGesture = { [session] id, modifier in
                session.select(id, modifier: modifier)
                return session.selection
            }
            grid.onSelect = { [session] in session.select($0) }
            grid.onCurrentChange = { [session] in session.focus($0) }
        }
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
            entries: entries, isComplete: true), selection: session.selection)
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        let tile = try #require(grid.collectionView.collectionViewLayout?
            .layoutAttributesForItem(at: IndexPath(item: start, section: 0))).frame
        let point = grid.collectionView.convert(NSPoint(x: tile.midX, y: tile.midY), to: nil)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        grid.collectionView.mouseDown(with: click)
        try #require(window.firstResponder === grid.collectionView)
        expectSelection(start...start, current: start, anchor: start)
    }

    func press(_ key: UInt16, modifiers: NSEvent.ModifierFlags = .shift) throws {
        let character: String
        switch key {
        case 123: character = "\u{F702}"
        case 124: character = "\u{F703}"
        case 125: character = "\u{F701}"
        default: character = "\u{F700}"
        }
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: modifiers, timestamp: 1, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: key))
        // Command navigation is specified at the existing native keyDown seam;
        // NSWindow's Command key-equivalent routing is outside this Shift fix.
        if modifiers.contains(.command) { grid.collectionView.keyDown(with: event) }
        else { window.sendEvent(event) }
    }

    func expectSelection(_ range: ClosedRange<Int>, current: Int, anchor: Int) {
        let expected = Set(range.map { ids[$0] })
        #expect(grid.selection.selectedItemIDs == expected)
        #expect(grid.selection.selectedItemIDs.count == range.count)
        #expect(grid.selection.currentItemID == ids[current])
        #expect(grid.currentItemID == ids[current])
        #expect(grid.selection.anchorItemID == ids[anchor])
        #expect(grid.collectionView.selectionIndexPaths == Set(range.map { IndexPath(item: $0, section: 0) }))
        if hasCallbacks {
            #expect(session.selection.selectedItemIDs == expected)
            #expect(session.selection.selectedItemIDs.count == range.count)
            #expect(session.selection.currentItemID == ids[current])
            #expect(session.selection.anchorItemID == ids[anchor])
        }
    }
}

@Test @MainActor func issue522ShiftRangeShrinksAndCrossesAnchor() throws {
    let fixture = try Issue522RangeFixture(start: 1)
    defer { fixture.window.close() }
    for endpoint in [2, 3, 2, 1, 0, 1] {
        try fixture.press(endpoint > (fixture.ids.firstIndex(of: fixture.grid.currentItemID!)!) ? 124 : 123)
        fixture.expectSelection(min(1, endpoint)...max(1, endpoint), current: endpoint, anchor: 1)
    }
}

@Test @MainActor func issue522VerticalRangeUsesLayoutColumnsAndClampsAtEdge() throws {
    let fixture = try Issue522RangeFixture(start: 1)
    defer { fixture.window.close() }
    let layout = try #require(fixture.grid.collectionView.collectionViewLayout)
    let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))).frame
    let columns = fixture.ids.indices.prefix { index in
        layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))?.frame.minY == first.minY
    }.count
    try #require(columns > 1 && columns + 1 < fixture.ids.count)
    try fixture.press(125)
    fixture.expectSelection(1...1 + columns, current: 1 + columns, anchor: 1)
    try fixture.press(126)
    fixture.expectSelection(1...1, current: 1, anchor: 1)
    for _ in 0..<2 {
        try fixture.press(126)
        fixture.expectSelection(0...1, current: 0, anchor: 1)
    }
}

@Test @MainActor func issue522CommandPreservesAndPlainReplacesRange() throws {
    let fixture = try Issue522RangeFixture(start: 3)
    defer { fixture.window.close() }
    try fixture.press(124)
    fixture.expectSelection(3...4, current: 4, anchor: 3)
    try fixture.press(124)
    fixture.expectSelection(3...5, current: 5, anchor: 3)
    try fixture.press(123, modifiers: .command)
    fixture.expectSelection(3...5, current: 4, anchor: 3)
    try fixture.press(123, modifiers: [])
    fixture.expectSelection(3...3, current: 3, anchor: 3)
    try fixture.press(124)
    fixture.expectSelection(3...4, current: 4, anchor: 3)
}

@Test @MainActor func issue522PlainArrowEstablishesDifferentRangeAnchor() throws {
    let fixture = try Issue522RangeFixture(start: 3)
    defer { fixture.window.close() }
    try fixture.press(124)
    fixture.expectSelection(3...4, current: 4, anchor: 3)
    try fixture.press(124)
    fixture.expectSelection(3...5, current: 5, anchor: 3)
    try fixture.press(123, modifiers: [])
    fixture.expectSelection(4...4, current: 4, anchor: 4)
    try fixture.press(124)
    fixture.expectSelection(4...5, current: 5, anchor: 4)
}

@Test @MainActor func issue522StandaloneGridExtendsWithoutCallbacks() throws {
    let fixture = try Issue522RangeFixture(start: 1, callbacks: false)
    defer { fixture.window.close() }
    for endpoint in [2, 3, 2] {
        try fixture.press(endpoint > (fixture.ids.firstIndex(of: fixture.grid.currentItemID!)!) ? 124 : 123)
        fixture.expectSelection(1...endpoint, current: endpoint, anchor: 1)
    }
}
