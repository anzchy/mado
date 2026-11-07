import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

@MainActor private func parityGrid(width: CGFloat, count: Int = 12) -> (GridBrowserView, [FolderEntry], NSWindow) {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-parity")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entries = (0..<count).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: width, height: 800))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [], backing: .buffered, defer: false)
    window.contentView = grid
    grid.display(FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: entries, isComplete: true), selectedItemID: nil)
    grid.activate()
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    return (grid, entries, window)
}

@MainActor private func parityArrow(_ code: UInt16, in grid: GridBrowserView, window: NSWindow) throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    grid.collectionView.keyDown(with: event)
}

@Test @MainActor func gridArrowSequenceDrawsOnlyModelSelection() throws {
    let (grid, entries, window) = parityGrid(width: 700)
    var modelSelection: ItemID?
    grid.onSelect = { modelSelection = $0 }
    for key in [UInt16(124), 125, 125, 126] {
        try parityArrow(key, in: grid, window: window)
        let selected = try #require(modelSelection)
        let index = try #require(grid.index(for: selected))
        #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: index, section: 0)])
        #expect(grid.currentItemID == selected)
        for case let cell as GridPhotoItem in grid.collectionView.visibleItems() {
            let shouldSelect = cell.representedItemID == selected
            #expect(cell.isSelected == shouldSelect)
            let outline = cell.view.layer?.sublayers?.first { $0.borderWidth == 2 }
            #expect(outline?.isHidden == !shouldSelect)
        }
    }
    #expect(entries.contains { $0.itemID == modelSelection })
}

@Test @MainActor func gridResponsiveGeometryMatchesPageElevenAndTwelve() throws {
    let (grid, _, window) = parityGrid(width: 1280)
    let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
    scroll.scrollerStyle = .overlay
    scroll.tile()
    let cases: [(CGFloat, Int, CGFloat, CGFloat, CGFloat)] = [
        (1280.0, 5, 16.0, 24.0, 188.16),
        (1036.0, 4, 12.0, 16.0, 165.0),
        (720.0, 4, 12.0, 16.0, 150.0),
        (480.0, 1, 12.0, 16.0, 150.0),
        (1600.0, 6, 22.0, 32.0, 200.0)
    ]
    for (width, columns, gap, inset, tileHeight) in cases {
        window.setContentSize(NSSize(width: width, height: 800))
        grid.frame = NSRect(x: 0, y: 0, width: width, height: 800)
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        let cellWidth = (width - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns)
        #expect(abs(layout.itemSize.width - cellWidth) < 0.02)
        #expect(abs(layout.itemSize.height - (tileHeight + 36)) < 0.02)
        #expect(abs(layout.sectionInset.left - inset) < 0.02)
        #expect(abs(layout.sectionInset.top - 16) < 0.02)
        #expect(abs(layout.minimumInteritemSpacing - gap) < 0.02)
        #expect(abs(layout.minimumLineSpacing - (width >= 1600 ? 22 : (width > 1050 ? 18 : 12))) < 0.02)
        let cell = try #require(grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }.first)
        let tile = try #require(cell.tileLayer)
        #expect(abs(tile.frame.width - (cellWidth - 8)) < 0.02)
        #expect(abs(tile.frame.height - tileHeight) < 0.02)
    }
}

@Test @MainActor func gridRenderedColumnsAndArrowFollowClipWidth() throws {
    for (width, style, columns, gap, inset, tileHeight) in [
        (1280.0, NSScroller.Style.overlay, 5, 16.0, 24.0, 188.16),
        (1280.0, .legacy, 5, 16.0, 24.0, 188.16),
        (1036.0, .overlay, 4, 12.0, 16.0, 165.0),
        (1036.0, .legacy, 4, 12.0, 16.0, 165.0),
        (1280.0, .overlay, 5, 16.0, 24.0, 188.16)
    ] {
        let (grid, entries, window) = parityGrid(width: width)
        let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.scrollerStyle = style
        scroll.tile()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        let clipWidth = scroll.contentSize.width
        let expectedWidth = (clipWidth - 2 * inset - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let second = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 1, section: 0)))
        let nextRow = try #require(layout.layoutAttributesForItem(at: IndexPath(item: columns, section: 0)))
        #expect(abs(first.frame.minX - inset) < 0.1)
        #expect(abs(second.frame.minX - (inset + expectedWidth + gap)) < 0.1)
        #expect(abs(nextRow.frame.minX - inset) < 0.1)
        #expect(abs(nextRow.frame.minY - first.frame.minY) >= tileHeight + 36 + 12)
        #expect(abs(layout.itemSize.width - expectedWidth) < 0.1)
        try parityArrow(125, in: grid, window: window)
        #expect(grid.currentItemID == entries[columns].itemID)
    }
}

@Test @MainActor func gridArrowStepMatchesRenderedColumnsAtFractionalWidths() throws {
    for (width, style) in [(789.0, NSScroller.Style.overlay), (804.0, .legacy)] {
        let (grid, entries, window) = parityGrid(width: width)
        let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
        scroll.scrollerStyle = style
        scroll.tile()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
        let first = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)))
        let rowTwo = try #require(layout.layoutAttributesForItem(at: IndexPath(item: 3, section: 0)))
        #expect(abs(rowTwo.frame.minX - first.frame.minX) < 0.1)
        #expect(rowTwo.frame.minY > first.frame.minY)
        try parityArrow(125, in: grid, window: window)
        #expect(grid.currentItemID == entries[3].itemID)
        try parityArrow(126, in: grid, window: window)
        #expect(grid.currentItemID == entries[0].itemID)
    }
}

@Test @MainActor func gridRelayoutsWhenScrollerOrClipChangesWithoutOuterResize() throws {
    let (grid, _, _) = parityGrid(width: 1280)
    let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
    let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
    scroll.scrollerStyle = .overlay
    scroll.tile()
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    let overlayWidth = layout.itemSize.width

    // Suppress the clip notification so only the scroller-style handler can relayout.
    scroll.contentView.postsFrameChangedNotifications = false
    scroll.scrollerStyle = .legacy
    scroll.tile()
    #expect(layout.itemSize.width == overlayWidth)
    NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
    #expect(scroll.contentSize.width < grid.bounds.width)
    #expect(layout.itemSize.width < overlayWidth)

    scroll.contentView.postsFrameChangedNotifications = true
    let legacyWidth = layout.itemSize.width
    scroll.contentView.setFrameSize(NSSize(width: 1250, height: scroll.contentView.frame.height))
    #expect(scroll.contentSize.width == 1250)
    #expect(layout.itemSize.width < legacyWidth)
}

@Test @MainActor func gridSelectionOutlinesTileOnlyAndCurrentRingIsDistinct() throws {
    let cell = GridPhotoItem()
    _ = cell.view
    cell.view.frame = NSRect(x: 0, y: 0, width: 233.6, height: 224.16)
    cell.view.layoutSubtreeIfNeeded()
    cell.isCurrent = true
    cell.isSelected = true
    let tile = try #require(cell.tileLayer)
    let outline = try #require(cell.view.layer?.sublayers?.first { $0.borderWidth == 1 && !$0.isHidden })
    #expect(cell.view.layer?.borderWidth == 0)
    #expect(outline !== cell.currentRingLayer)
    #expect(outline.frame == tile.frame)
    #expect(cell.currentRingLayer.frame == tile.frame.insetBy(dx: -4, dy: -4))
    #expect(!cell.currentRingLayer.isHidden)
    cell.isSelected = false
    #expect(outline.isHidden)
    #expect(!cell.currentRingLayer.isHidden)
}

@Test @MainActor func gridFilenameTruncatesAtEnd() throws {
    let cell = GridPhotoItem()
    _ = cell.view
    let name = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }
        .first { $0.stringValue.isEmpty })
    #expect(name.lineBreakMode == .byTruncatingTail)
    #expect(name.maximumNumberOfLines == 1)
}
