import AppKit
import Foundation
import Testing
import MadoCore
@testable import MadoMacUI

@Test @MainActor func gridCellReuseAndSnapshotOrderKeepTruthfulIdentity() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-ui")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let a = FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: root)
    let b = FolderEntry(url: folder.appendingPathComponent("B.png"), root: root)
    let cell = GridPhotoItem()
    cell.configure(a)
    #expect(cell.representedItemID == a.itemID)
    #expect(cell.filename == "A.jpg")
    #expect(cell.view.accessibilityLabel() == "A.jpg, thumbnail pending")
    cell.configure(b)
    #expect(cell.representedItemID == b.itemID)
    #expect(cell.filename == "B.png")
    #expect(cell.view.accessibilityLabel() == "B.png, thumbnail pending")
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let first = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1), entries: [a, b], isComplete: true)
    grid.display(first, selectedItemID: b.itemID)
    #expect(grid.itemID(at: 1) == b.itemID)
    let zero = FolderEntry(url: folder.appendingPathComponent("0.jpg"), root: root)
    let next = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 2), entries: [zero, a, b], isComplete: true)
    grid.display(next, selectedItemID: b.itemID)
    #expect(grid.index(for: b.itemID) == 2)
    #expect(grid.collectionView.selectionIndexPaths == [IndexPath(item: 2, section: 0)])
}

@Test @MainActor func gridViewSelectionAndScrollUseCurrentIdentity() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-secondary")
    let rootID = AccessRootID(rawValue: UUID())
    let entry = FolderEntry(url: folder.appendingPathComponent("Current.heic"),
        root: .init(id: rootID, url: folder))
    let snapshot = FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [entry], isComplete: true)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
        styleMask: [], backing: .buffered, defer: false)
    window.contentView = grid
    grid.display(snapshot, selectedItemID: nil)
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    #expect(grid.collectionView.selectionIndexPaths.isEmpty)
    #expect(grid.entry(for: entry.itemID) == entry)
    #expect(grid.itemID(at: 9) == nil)
    var selected: ItemID?
    grid.onSelect = { selected = $0 }
    grid.collectionView(grid.collectionView, didSelectItemsAt: [IndexPath(item: 0, section: 0)])
    #expect(selected == entry.itemID)
    let item = grid.collectionView(grid.collectionView, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
    #expect((item as? GridPhotoItem)?.filename == "Current.heic")
    grid.scrollTo(entry.itemID)
    #expect(grid.firstVisibleItemID() == entry.itemID)
    grid.scrollTo(.ephemeral(UUID()))
    #expect(GridBrowserView(coder: NSCoder()) == nil)
}

@Test @MainActor func gridSelectedCellUsesSemanticAccentAndFilenameFillAcrossAppearances() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-colors")
    let id = AccessRootID(rawValue: UUID())
    let entry = FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: .init(id: id, url: folder))
    let cell = GridPhotoItem()
    cell.configure(entry)
    cell.view.appearance = NSAppearance(named: .aqua)
    cell.isSelected = true
    let filename = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }
        .first { $0.stringValue == "A.jpg" })
    func rgba(_ color: CGColor?) -> [CGFloat] { color?.components ?? [] }
    let outline = try #require(cell.view.layer?.sublayers?.first { $0.borderWidth == 2 })
    let lightBorder = rgba(outline.borderColor)
    let lightFill = rgba(filename.layer?.backgroundColor)
    #expect(lightBorder == DesignColor.accent.components(.light).map { CGFloat($0) })
    #expect(lightFill == DesignColor.selectionFill.components(.light).map { CGFloat($0) })
    cell.view.appearance = NSAppearance(named: .darkAqua)
    let darkBorder = rgba(outline.borderColor)
    let darkFill = rgba(filename.layer?.backgroundColor)
    #expect(darkBorder == DesignColor.accent.components(.dark).map { CGFloat($0) })
    #expect(darkFill == DesignColor.selectionFill.components(.dark).map { CGFloat($0) })
    #expect(lightBorder != darkBorder && lightFill != darkFill)
    #expect(cell.isSelected && cell.view.window?.firstResponder !== cell.view)
}

@Test @MainActor func gridTileSurfaceDiffersFromGridBackgroundAcrossAppearances() throws {
    let application = NSApplication.shared
    let previous = application.appearance
    defer { application.appearance = previous }
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-tile")
    let entry = FolderEntry(url: folder.appendingPathComponent("A.jpg"),
        root: .init(id: AccessRootID(rawValue: UUID()), url: folder))
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    let cell = GridPhotoItem()
    cell.configure(entry)
    grid.addSubview(cell.view)
    func rgba(_ color: NSColor?) -> [CGFloat] {
        guard let color = color?.usingColorSpace(.sRGB) else { return [] }
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
    func resolved(_ color: NSColor?, in view: NSView) -> [CGFloat] {
        var value: [CGFloat] = []
        view.effectiveAppearance.performAsCurrentDrawingAppearance { value = rgba(color.flatMap { NSColor(cgColor: $0.cgColor) }) }
        return value
    }
    func close(_ actual: [CGFloat], _ token: DesignColor, _ theme: DesignTheme) -> Bool {
        let expected = token.components(theme).map { CGFloat($0) }
        return actual.count == 4 && zip(actual, expected).allSatisfy { abs($0 - $1) < 0.002 }
    }
    for (override, inherited, theme) in [(NSAppearance.Name?.some(.aqua), NSAppearance.Name.aqua, DesignTheme.light),
        (.some(.darkAqua), .aqua, .dark), (nil, .darkAqua, .dark)] {
        application.appearance = try #require(NSAppearance(named: inherited))
        window.appearance = override.flatMap(NSAppearance.init(named:))
        cell.view.viewDidChangeEffectiveAppearance()
        let tileLayer = try #require(cell.tileLayer)
        let tile = rgba(tileLayer.backgroundColor.flatMap { NSColor(cgColor: $0) })
        let background = resolved(grid.collectionView.backgroundColors.first, in: grid)
        let scroll = resolved(grid.collectionView.enclosingScrollView?.backgroundColor, in: grid)
        #expect(tile != background, "\(theme): tile must separate from the grid background")
        #expect(close(tile, .sidebarBackground, theme), "\(theme): tile \(tile)")
        #expect(close(background, .canvasBackground, theme), "\(theme): collection background \(background)")
        #expect(close(scroll, .canvasBackground, theme), "\(theme): scroll background \(scroll)")
        #expect(tileLayer !== cell.view.layer)
        #expect(tileLayer.cornerRadius == CGFloat(DesignMetrics.radii["inner"] ?? 0))
        #expect(cell.view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent } ?? 0 == 0,
            "the cell plate stays transparent; only the tile is drawn")
    }
}
