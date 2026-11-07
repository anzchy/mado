import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class CurrentItemHost: ViewerSessionHost {
    var hasImage = true
    var opened: [ItemID] = []
    var returns = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { opened.append(id) }
    func returnToGrid() { returns += 1 }
}

@MainActor private struct CurrentItemScene {
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-current")
    let rootID = AccessRootID(rawValue: UUID())
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 760, height: 480))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
        styleMask: [.titled], backing: .buffered, defer: false)
    init() { window.contentView = grid }
    func entry(_ name: String) -> FolderEntry {
        FolderEntry(url: folder.appendingPathComponent(name), root: .init(id: rootID, url: folder))
    }
    func snapshot(_ entries: [FolderEntry], generation: UInt64 = 1) -> FolderSnapshot {
        FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: generation), entries: entries, isComplete: true)
    }
    /// The App's wiring: grid selection and Current Item both reach the Session.
    func wire(_ session: ViewerSession) {
        grid.onSelect = { session.select($0) }
        grid.onCurrentChange = { session.focus($0) }
    }
}

@Test @MainActor func gridCurrentItemReachesSessionForSpaceAndFallsBackToFirst() throws {
    _ = NSApplication.shared
    let scene = CurrentItemScene(), router = CommandRouter()
    let a = scene.entry("A.jpg"), b = scene.entry("B.jpg"), c = scene.entry("C.jpg")
    let ids = [a, b, c].map(\.itemID)

    let host = CurrentItemHost(), session = ViewerSession(host: host)
    scene.wire(session)
    session.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    scene.grid.display(scene.snapshot([a, b, c]), selectedItemID: nil)
    scene.grid.activate(currentItemID: b.itemID)
    #expect(session.selection.currentItemID == b.itemID)
    #expect(session.selection.selectedItemIDs.isEmpty)
    #expect(scene.grid.collectionView.selectionIndexPaths.isEmpty)
    #expect(router.route(.preview, from: .key, to: session))
    #expect(host.opened == [b.itemID], "Space opens the image the user came from")
    #expect(router.route(.escape, from: .key, to: session))
    #expect(host.returns == 1)
    #expect(session.selection.currentItemID == b.itemID)
    #expect(session.selection.selectedItemIDs.isEmpty)

    let missingHost = CurrentItemHost(), missing = ViewerSession(host: missingHost)
    scene.wire(missing)
    missing.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    scene.grid.activate(currentItemID: .ephemeral(UUID()))
    #expect(scene.grid.currentItemID == a.itemID)
    #expect(missing.selection.currentItemID == a.itemID)
    #expect(router.route(.enter, from: .key, to: missing))
    #expect(missingHost.opened == [a.itemID])

    let removalHost = CurrentItemHost(), removal = ViewerSession(host: removalHost)
    scene.wire(removal)
    removal.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    scene.grid.activate(currentItemID: b.itemID)
    #expect(removal.selection.currentItemID == b.itemID)
    let z = scene.entry("0.jpg")
    removal.updateItems([z, a, c].map(\.itemID), sourceVersion: .init(2))
    scene.grid.display(scene.snapshot([z, a, c], generation: 2), selectedItemID: nil)
    #expect(scene.grid.currentItemID == z.itemID)
    #expect(removal.selection.currentItemID == z.itemID)
    #expect(router.route(.preview, from: .key, to: removal))
    #expect(removalHost.opened == [z.itemID])

    let kept = ViewerSession()
    kept.beginBrowsing(items: ids, sourceVersion: .init(1), scrollAnchor: nil)
    kept.select(a.itemID)
    kept.focus(c.itemID)
    #expect(kept.selection.currentItemID == c.itemID)
    #expect(kept.selection.selectedItemIDs == [a.itemID])
    #expect(kept.selection.anchorItemID == a.itemID)
    kept.focus(.ephemeral(UUID()))
    #expect(kept.selection.currentItemID == c.itemID)
}

@Test @MainActor func gridDrawsCurrentItemRingDistinctFromSelection() throws {
    _ = NSApplication.shared
    let scene = CurrentItemScene()
    let a = scene.entry("A.jpg"), b = scene.entry("B.jpg"), c = scene.entry("C.jpg")
    func rgba(_ color: CGColor?) -> [CGFloat] {
        guard let color = color.flatMap({ NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
    func close(_ actual: [CGFloat], _ token: DesignColor, _ theme: DesignTheme) -> Bool {
        let expected = token.components(theme).map { CGFloat($0) }
        return actual.count == 4 && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.002 }
    }

    let cell = GridPhotoItem()
    cell.configure(a)
    cell.view.appearance = NSAppearance(named: .aqua)
    #expect(cell.currentRingLayer.isHidden)
    cell.isSelected = true
    let outline = cell.view.layer?.sublayers?.first { $0.borderWidth == 1 }
    #expect(outline?.isHidden == false)
    #expect(cell.currentRingLayer.isHidden, "Selection alone draws no Current Item ring")
    cell.isSelected = false
    cell.isCurrent = true
    #expect(!cell.currentRingLayer.isHidden)
    #expect(cell.currentRingLayer.borderWidth == 2)
    #expect(cell.currentRingLayer.frame == cell.tileLayer?.frame.insetBy(dx: -4, dy: -4))
    #expect(close(rgba(cell.currentRingLayer.borderColor), .focusRing, .light))
    #expect(outline?.isHidden == true, "Current Item alone keeps the Selection outline off")
    cell.isSelected = true
    #expect(!cell.currentRingLayer.isHidden && outline?.isHidden == false)
    cell.view.appearance = NSAppearance(named: .darkAqua)
    cell.view.viewDidChangeEffectiveAppearance()
    #expect(close(rgba(cell.currentRingLayer.borderColor), .focusRing, .dark))
    cell.isCurrent = false
    #expect(cell.currentRingLayer.isHidden)

    let grid = scene.grid
    func current() -> [String] {
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        let items = grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.isCurrent == !$0.currentRingLayer.isHidden })
        return items.filter(\.isCurrent).map(\.filename).sorted()
    }
    grid.display(scene.snapshot([a, b, c]), selectedItemID: nil)
    grid.activate()
    #expect(current() == ["A.jpg"], "after entry")
    grid.activate(currentItemID: b.itemID)
    #expect(current() == ["B.jpg"], "after Esc return")
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: scene.window.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    grid.collectionView.keyDown(with: right)
    #expect(current() == ["C.jpg"], "while moving with arrows")
    grid.collectionView(grid.collectionView, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    #expect(current() == ["A.jpg"], "after a click")
    grid.display(scene.snapshot([a, b, c], generation: 2), selectedItemID: a.itemID)
    #expect(current() == ["A.jpg"], "after a reload")
    let made = try #require(grid.collectionView(grid.collectionView,
        itemForRepresentedObjectAt: IndexPath(item: 1, section: 0)) as? GridPhotoItem)
    #expect(!made.isCurrent && made.currentRingLayer.isHidden)
    let madeCurrent = try #require(grid.collectionView(grid.collectionView,
        itemForRepresentedObjectAt: IndexPath(item: 0, section: 0)) as? GridPhotoItem)
    #expect(madeCurrent.isCurrent && !madeCurrent.currentRingLayer.isHidden)
}

private func gridCellAccessibilityValue(selected: Bool, current: Bool) -> String {
    switch (selected, current) {
    case (true, true): String(localized: "Selected, Current")
    case (true, false): String(localized: "Selected")
    case (false, true): String(localized: "Current")
    case (false, false): ""
    }
}

@Test @MainActor func gridCellAccessibilityValueIsAFunctionOfFinalState() {
    _ = NSApplication.shared
    let scene = CurrentItemScene()
    let states = [(false, false), (true, false), (false, true), (true, true)]
    for start in states {
        for target in states {
            for selectedFirst in [true, false] {
                let cell = GridPhotoItem()
                _ = cell.view
                cell.configure(scene.entry("A.jpg"))
                cell.isSelected = start.0; cell.isCurrent = start.1
                if selectedFirst { cell.isSelected = target.0; cell.isCurrent = target.1 }
                else { cell.isCurrent = target.1; cell.isSelected = target.0 }
                #expect(cell.view.accessibilityValue() as? String
                    == gridCellAccessibilityValue(selected: target.0, current: target.1),
                    "from \(start) to \(target)")
                #expect(cell.currentRingLayer.isHidden == !target.1)
            }
        }
    }
}

@Test @MainActor func gridCellAccessibilityValueMovesWithCurrentItem() throws {
    _ = NSApplication.shared
    let scene = CurrentItemScene(), grid = scene.grid
    let a = scene.entry("A.jpg"), b = scene.entry("B.jpg"), c = scene.entry("C.jpg")
    func announcedCurrent() -> [String] {
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        let items = grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }
        #expect(items.count == 3)
        for item in items {
            #expect(item.view.accessibilityValue() as? String
                == gridCellAccessibilityValue(selected: item.isSelected, current: item.isCurrent), "\(item.filename)")
        }
        let current = String(localized: "Current")
        return items.filter { ($0.view.accessibilityValue() as? String)?.hasSuffix(current) == true }
            .map(\.filename).sorted()
    }
    grid.display(scene.snapshot([a, b, c]), selectedItemID: nil)
    grid.activate()
    #expect(announcedCurrent() == ["A.jpg"])
    grid.activate(currentItemID: b.itemID)
    #expect(announcedCurrent() == ["B.jpg"])
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: scene.window.windowNumber, context: nil,
        characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    grid.collectionView.keyDown(with: right)
    #expect(announcedCurrent() == ["C.jpg"])
    grid.collectionView(grid.collectionView, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    #expect(announcedCurrent() == ["A.jpg"])
}

@Test func gridCellAccessibilityValueUsesWholeStringKey() throws {
    let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/MadoMacUI/Grid/GridBrowserView.swift"), encoding: .utf8)
    // zh-Hans needs the full-width comma of 「已选中，当前」, so the pair is one catalog key, never a join.
    #expect(source.contains("String(localized: \"Selected, Current\")"))
    #expect(!source.contains(".joined(separator: \", \")"))
}

extension CurrentItemScene {
    func emptied(generation: UInt64) -> FolderSnapshot {
        FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: generation), entries: [], isComplete: false)
    }
    func ringed() -> [String] {
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        return grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }
            .filter { $0.isCurrent && !$0.currentRingLayer.isHidden }.map(\.filename).sorted()
    }
}

@Test @MainActor func gridKeepsRequestedCurrentUntilAnEmptiedGridIsRefilled() throws {
    _ = NSApplication.shared
    let scene = CurrentItemScene()
    let a = scene.entry("A.jpg"), b = scene.entry("B.jpg"), c = scene.entry("C.jpg")
    let session = ViewerSession()
    var changes: [ItemID] = []
    scene.grid.onSelect = { session.select($0) }
    scene.grid.onCurrentChange = { session.focus($0); changes.append($0) }
    session.beginBrowsing(items: [a, b, c].map(\.itemID), sourceVersion: .init(1), scrollAnchor: nil)
    scene.grid.display(scene.snapshot([a, b, c]), selectedItemID: nil)
    scene.grid.activate(currentItemID: c.itemID)
    #expect(session.selection.currentItemID == c.itemID)
    // A folder entry empties the grid; Cancel restores a preview; the Current Item is requested before the refill.
    scene.grid.display(scene.emptied(generation: 2), selectedItemID: nil)
    scene.grid.activate(currentItemID: c.itemID)
    #expect(scene.grid.currentItemID == nil, "an empty grid has no Current Item to draw")
    // Esc (returnToGrid → GridWatchedSearchRefresh.restoreGrid) refills from the Session's selection, then activates.
    scene.grid.display(scene.snapshot([a, b, c], generation: 3), selection: session.selection)
    scene.grid.activate(currentItemID: session.selection.currentItemID)
    #expect(scene.grid.currentItemID == c.itemID)
    #expect(session.selection.currentItemID == c.itemID)
    #expect(scene.ringed() == ["C.jpg"])
    let delivered = changes.count
    scene.grid.collectionView(scene.grid.collectionView, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    scene.grid.display(scene.snapshot([a, b, c], generation: 4), selection: session.selection)
    #expect(scene.grid.currentItemID == a.itemID, "an applied request is not replayed")
    #expect(session.selection.currentItemID == a.itemID)
    #expect(scene.ringed() == ["A.jpg"])
    #expect(!changes[delivered...].contains(c.itemID))
}
