import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private struct GridArrowScrollFixture {
    let grid: GridBrowserView
    let window: NSWindow
    let columns: Int

    init(count: Int = 120) {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: "/tmp/mado-grid-arrow-scroll")
        let rootID = AccessRootID(rawValue: UUID())
        let root = ItemIdentityRoot(id: rootID, url: folder)
        let entries = (0..<count).map { $0 + 1 }.map {
            FolderEntry(url: folder.appendingPathComponent(String(format: "%03d.jpg", $0)), root: root)
        }
        let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
            entries: entries, isComplete: true)
        let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid
        grid.display(snapshot, selectedItemID: nil)
        grid.activate()
        grid.layoutSubtreeIfNeeded()
        let firstRow = count > 0 ? grid.collectionView.frameForItem(at: 0).minY : 0
        columns = (0..<count).prefix { grid.collectionView.frameForItem(at: $0).minY == firstRow }.count
        self.grid = grid
        self.window = window
    }

    var visible: NSRect { grid.collectionView.enclosingScrollView!.contentView.documentVisibleRect }
    var currentIndex: Int? { grid.currentItemID.flatMap(grid.index(for:)) }
    var currentFrame: NSRect { grid.collectionView.frameForItem(at: currentIndex!) }
    var currentFullyVisible: Bool { visible.contains(currentFrame) }

    func press(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = []) {
        let characters: [UInt16: String] = [123: "\u{F702}", 124: "\u{F703}", 125: "\u{F701}", 126: "\u{F700}"]
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: characters[keyCode]!, charactersIgnoringModifiers: characters[keyCode]!,
            isARepeat: false, keyCode: keyCode)!
        grid.collectionView.keyDown(with: event)
    }

    /// Presses an arrow and checks the scroll law: the Current Item ends fully visible; the offset moves only
    /// when the new Current Item was not fully visible before, and then to the nearest edge.
    func pressChecked(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags = [],
                      sourceLocation: SourceLocation = #_sourceLocation) {
        let before = visible, from = currentIndex
        press(keyCode, modifiers)
        let label = "key \(keyCode) \(modifiers.rawValue) from \(from.map(String.init) ?? "nil") to \(currentIndex.map(String.init) ?? "nil")"
        #expect(currentFullyVisible, "\(label): \(currentFrame) outside \(visible)", sourceLocation: sourceLocation)
        if before.contains(currentFrame) {
            #expect(visible.origin == before.origin, "\(label): scrolled although visible", sourceLocation: sourceLocation)
        } else if currentFrame.maxY > before.maxY {
            #expect(abs(currentFrame.maxY - visible.maxY) < 0.5, "\(label): not at bottom edge", sourceLocation: sourceLocation)
        } else {
            #expect(abs(currentFrame.minY - visible.minY) < 0.5, "\(label): not at top edge", sourceLocation: sourceLocation)
        }
    }
}

/// #187 AC-1: Down past the last visible row scrolls the minimum amount, to the bottom edge.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187DownPastVisibleRowsScrollsCurrentItemToBottomEdge() {
    let fixture = GridArrowScrollFixture()
    #expect(fixture.columns > 1)
    #expect(fixture.visible.origin.y == 0)
    for _ in 0..<30 { fixture.pressChecked(125) }
    #expect(fixture.currentIndex == 119)
    #expect(fixture.visible.origin.y > 0)
}

/// #187 AC-1: Up above the first visible row scrolls the minimum amount, to the top edge.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187UpAboveVisibleRowsScrollsCurrentItemToTopEdge() {
    let fixture = GridArrowScrollFixture()
    for _ in 0..<30 { fixture.press(125) }
    #expect(fixture.visible.origin.y > 0)
    for _ in 0..<30 { fixture.pressChecked(126) }
    #expect(fixture.currentIndex == 0)
    #expect(abs(fixture.visible.minY - fixture.currentFrame.minY) < 0.5)
}

/// #187 AC-1: moving within the visible rows does not scroll, at the top and at a scrolled offset.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187ArrowsWithinVisibleRowsDoNotScroll() {
    let fixture = GridArrowScrollFixture()
    for key: UInt16 in [124, 125, 123, 126] {
        fixture.press(key)
        #expect(fixture.visible.origin.y == 0)
    }
    #expect(fixture.currentIndex == 0)
    for _ in 0..<8 { fixture.press(125) }
    let scrolled = fixture.visible.origin
    #expect(scrolled.y > 0)
    // From column 0 of the bottom visible row: Right, Up, Left, Down all stay within the visible rows.
    for key: UInt16 in [124, 126, 123, 125] {
        fixture.press(key)
        #expect(fixture.currentFullyVisible)
        #expect(fixture.visible.origin == scrolled, "key \(key) scrolled within visible rows")
    }
}

/// #187 AC-1: an arrow that cannot move (clamped at either end) does not scroll, even with the Current Item off-screen.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187ClampedArrowDoesNotScroll() {
    let fixture = GridArrowScrollFixture()
    fixture.grid.restoreContentOffset(NSPoint(x: 0, y: 900))
    for key: UInt16 in [126, 123] {
        fixture.press(key)
        #expect(fixture.currentIndex == 0)
        #expect(fixture.grid.contentOffset.y == 900)
    }
    for _ in 0..<30 { fixture.press(125) }
    #expect(fixture.currentIndex == 119)
    fixture.grid.restoreContentOffset(NSPoint(x: 0, y: 900))
    for key: UInt16 in [125, 124] {
        fixture.press(key)
        #expect(fixture.currentIndex == 119)
        #expect(fixture.grid.contentOffset.y == 900)
    }
}

/// #187 AC-1: ⇧ and ⌘ arrows keep the Current Item visible too, and Left/Right wrap across rows into view.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187ModifiedAndHorizontalArrowsKeepCurrentItemVisible() {
    let fixture = GridArrowScrollFixture()
    for modifiers: NSEvent.ModifierFlags in [.shift, .command] {
        for _ in 0..<12 { fixture.pressChecked(125, modifiers) }
        #expect(fixture.visible.origin.y > 0)
        for _ in 0..<12 { fixture.pressChecked(126, modifiers) }
        #expect(fixture.currentIndex == 0)
    }
    for _ in 0..<(fixture.columns * 8) { fixture.pressChecked(124) }
    #expect(fixture.visible.origin.y > 0)
    for _ in 0..<(fixture.columns * 8) { fixture.pressChecked(123) }
    #expect(fixture.currentIndex == 0)
}

/// #187 AC-1: a seeded walk of mixed arrows keeps the scroll law at every step.
@Test(.timeLimit(.minutes(2)), arguments: [UInt64(1), 7, 187]) @MainActor func issue187SeededArrowWalkKeepsScrollLaw(seed: UInt64) {
    let fixture = GridArrowScrollFixture()
    var state = seed
    for _ in 0..<80 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let key = UInt16(123 + (state >> 33) % 4)
        fixture.pressChecked(key, (state >> 40) % 3 == 0 ? .shift : [])
    }
}

/// #187 AC-3: restore paths do not scroll into view: Esc-return's offset, activation, selection sync and scrollTo.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187RestoredOffsetSurvivesUntilAnArrowMove() {
    let fixture = GridArrowScrollFixture()
    fixture.grid.restoreContentOffset(NSPoint(x: 0, y: 900))
    fixture.grid.activate(currentItemID: fixture.grid.itemID(at: 0))
    fixture.grid.setCurrentItemID(fixture.grid.itemID(at: 0))
    var selection = BrowserSelection()
    selection.click(fixture.grid.itemID(at: 0)!, in: fixture.grid.displayedItemIDs)
    fixture.grid.synchronizeSelection(selection)
    #expect(fixture.grid.contentOffset.y == 900)
    #expect(!fixture.currentFullyVisible)
    // scrollTo keeps its top placement (Esc-return anchor), not the arrows' nearest edge (bottom from here).
    fixture.grid.scrollTo(fixture.grid.itemID(at: 40)!)
    let anchored = fixture.grid.collectionView.frameForItem(at: 40)
    #expect(fixture.visible.contains(anchored))
    #expect(anchored.minY - fixture.visible.minY < 30)
    fixture.grid.restoreContentOffset(NSPoint(x: 0, y: 900))
    fixture.pressChecked(124)
    #expect(fixture.currentIndex == 1)
    #expect(abs(fixture.currentFrame.minY - fixture.visible.minY) < 0.5)
}

/// #187: arrows in an empty grid neither crash nor scroll.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187ArrowsInEmptyGridDoNothing() {
    let fixture = GridArrowScrollFixture(count: 0)
    for key: UInt16 in [123, 124, 125, 126] { fixture.press(key) }
    #expect(fixture.grid.currentItemID == nil)
    #expect(fixture.visible.origin.y == 0)
}

/// #187 AC-1: with scroll view content insets (a titlebar or bar over the grid), the tile clears the insets too.
@Test(.timeLimit(.minutes(2))) @MainActor func issue187ArrowScrollClearsContentInsets() {
    let fixture = GridArrowScrollFixture()
    let scrollView = fixture.grid.collectionView.enclosingScrollView!
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 24, right: 0)
    fixture.grid.layoutSubtreeIfNeeded()
    var inset: NSRect {
        let visible = fixture.visible
        return NSRect(x: visible.minX, y: visible.minY + 40, width: visible.width, height: visible.height - 64)
    }
    var scrolledDown = false
    for _ in 0..<12 {
        fixture.press(125)
        #expect(inset.contains(fixture.currentFrame), "Down to \(fixture.currentIndex!): \(fixture.currentFrame) outside \(inset)")
        scrolledDown = scrolledDown || abs(fixture.currentFrame.maxY - inset.maxY) < 0.5
    }
    #expect(scrolledDown)
    for _ in 0..<12 {
        fixture.press(126)
        #expect(inset.contains(fixture.currentFrame), "Up to \(fixture.currentIndex!): \(fixture.currentFrame) outside \(inset)")
    }
    #expect(abs(fixture.currentFrame.minY - inset.minY) < 0.5)
}

/// #345 / GRID-02: id-based reveal follows the same minimum-distance law as arrows.
@Test(.timeLimit(.minutes(2))) @MainActor func issue345IDRevealIsMinimalAndIdempotent() {
    let fixture = GridArrowScrollFixture()
    let grid = fixture.grid, scroll = grid.collectionView.enclosingScrollView!
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentInsets = NSEdgeInsets(top: 40, left: 0, bottom: 24, right: 0)
    grid.layoutSubtreeIfNeeded()
    func effectiveVisible() -> NSRect {
        var visible = fixture.visible
        visible.origin.y += 40
        visible.size.height -= 64
        return visible
    }
    let selection = grid.selection, current = grid.currentItemID
    let saved = NSPoint(x: 0, y: 900.25)
    for (index, id) in grid.displayedItemIDs.enumerated() {
        grid.restoreContentOffset(saved)
        let before = effectiveVisible(), tile = grid.collectionView.frameForItem(at: index)
        let shift = tile.minY < before.minY ? tile.minY - before.minY : max(0, tile.maxY - before.maxY)
        grid.reveal(id)
        #expect(effectiveVisible().contains(tile))
        #expect(abs(grid.contentOffset.y - saved.y - shift) < 0.0001)
        #expect(grid.contentOffset.x == saved.x)
        if before.contains(tile) { #expect(grid.contentOffset == saved) }
        let revealed = grid.contentOffset
        grid.reveal(id)
        #expect(grid.contentOffset == revealed, "reveal is idempotent")
        #expect(grid.selection == selection)
        #expect(grid.currentItemID == current)
    }
    grid.restoreContentOffset(saved)
    grid.reveal(.ephemeral(UUID()))
    #expect(grid.contentOffset == saved)
    #expect(grid.selection == selection)
    #expect(grid.currentItemID == current)
}
