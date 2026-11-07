import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #405 WI-2: with the ✓ badge gone, a selected cell that is not the Current Item is marked by the 1pt
// Selection stroke at the tile edge, and that stroke must render above the opaque tile, not under it. The 1pt
// width comes from the base rule `.photo-cell.is-selected .thumbnail-wrap{box-shadow:inset 0 0 0 1px …}`, which
// `.layout-exploration` overrides on pages 11, 12 and 32 with a 2px offset ring on every selected cell; the
// native split (2pt ring on Current Item only, 1pt edge on other selected cells) is the model the owner kept
// (#405, 2B), an owner-chosen deviation from those pages.

/// The 2pt band inside the tile's right edge, mid-height (clear of the corner radius).
@MainActor private func edgeBand(_ cell: GridPhotoItem) throws -> NSRect {
    let tile = try #require(cell.tileLayer).frame
    return NSRect(x: tile.maxX - 2, y: tile.midY - 10, width: 2, height: 20)
}

/// Strongly accent pixels on the tile's inner edge band. The threshold sits above the faint fringe an
/// occluded stroke leaks at a fractional tile edge, and below a stroke split across two pixels.
@MainActor private func outlineHits(_ cell: GridPhotoItem) throws -> Int {
    gridRasterHits(try gridCellRaster(cell), in: try edgeBand(cell)) {
        $0.alphaComponent > 0.5 && $0.blueComponent - $0.redComponent > 0.4
    }
}

@Test @MainActor func issue405OutlineRendersAboveTileOnlyWhenSelected() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: "/tmp/mado-405-outline-walk")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
        let entries = (0..<6).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
        let ids = entries.map(\.itemID)
        let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = grid
        grid.appearance = NSAppearance(named: appearance)
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
            entries: entries, isComplete: true), selection: BrowserSelection())
        var selection = BrowserSelection()
        let steps: [(String, (inout BrowserSelection) -> Void)] = [
            ("none", { _ in }),
            ("one", { $0.click(ids[1], in: ids) }),
            ("two", { $0.click(ids[4], modifier: .command, in: ids) }),
            ("focus moved", { $0.focus(ids[0], in: ids) }),
            ("all", { $0.click(ids[0], in: ids); $0.click(ids[5], modifier: .shift, in: ids) }),
            ("cleared", { $0.clearSelection() })
        ]
        func check(_ phase: String) throws {
            grid.layoutSubtreeIfNeeded()
            grid.collectionView.layoutSubtreeIfNeeded()
            let cells = grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }
            #expect(cells.count == 6)
            for cell in cells {
                let id = try #require(cell.representedItemID)
                let selected = grid.selection.selectedItemIDs.contains(id)
                #expect((try outlineHits(cell) > 0) == selected,
                    "\(appearance.rawValue) \(phase) \(id == grid.currentItemID ? "current" : "other"): outline ⇔ selected")
            }
        }
        for (phase, step) in steps {
            step(&selection)
            grid.synchronizeSelection(selection)
            try check(phase)
            if phase == "two" {
                grid.collectionView.reloadItems(at: Set((0..<6).map { IndexPath(item: $0, section: 0) }))
                try check("two reloaded")
            }
        }
    }
}

@Test @MainActor func issue405OutlineAndNameTintFollowStateAcrossCellDomain() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/mado-405-outline-domain")
    let entry = FolderEntry(url: folder.appendingPathComponent("DSC_0342.jpg"),
        root: ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder))
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        for selected in [false, true] { for current in [false, true] { for names in [true, false] {
            for width: CGFloat in [120, 220, 400] {
                let state = "\(appearance.rawValue) sel=\(selected) cur=\(current) names=\(names) w=\(width)"
                let cell = GridPhotoItem()
                cell.view.frame = NSRect(x: 0, y: 0, width: width, height: width * 184 / 220)
                cell.apply(GridDisplayOptions(showFileNames: names))
                cell.configure(entry)
                cell.view.appearance = NSAppearance(named: appearance)
                cell.isSelected = selected
                cell.isCurrent = current
                #expect((try outlineHits(cell) > 0) == selected, "\(state): outline ⇔ selected")
                let name = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == "DSC_0342.jpg" })
                let tint = name.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.alphaComponent ?? 0
                #expect((tint > 0) == (selected || current), "\(state): name tint ⇔ selected ∨ current")
            }
        } } }
    }
}

@Test @MainActor func issue405OutlineRenderedColourMatchesPinnedAccent() throws {
    for (page, appearance) in [("grid-multiselect", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(page)
        // `.photo-cell.is-selected .thumbnail-wrap{box-shadow:inset 0 0 0 1px var(--color-accent)}`.
        #expect(try design.exactDeclaration(".photo-cell.is-selected .thumbnail-wrap", "box-shadow")
            == "inset 0 0 0 1px var(--color-accent)")
        let accent = try gridRenderedColor(try design.color(":root", "--color-accent", viewport: 1280))
        let cell = GridPhotoItem()
        cell.view.frame = NSRect(x: 0, y: 0, width: 247, height: 224)
        cell.view.appearance = NSAppearance(named: appearance)
        let folder = URL(fileURLWithPath: "/tmp/mado-405-outline-colour")
        cell.configure(FolderEntry(url: folder.appendingPathComponent("A.jpg"),
            root: ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)))
        cell.isSelected = true
        cell.view.layoutSubtreeIfNeeded()
        let tile = try #require(cell.tileLayer).frame
        let bitmap = try gridCellRaster(cell)
        let tolerance = 3.0 / 255
        func isAccent(_ color: NSColor) -> Bool {
            abs(color.redComponent - accent.redComponent) <= tolerance
                && abs(color.greenComponent - accent.greenComponent) <= tolerance
                && abs(color.blueComponent - accent.blueComponent) <= tolerance
        }
        // 1px inset stroke: the outermost tile column is accent along the band; one column in is not.
        let stroke = NSRect(x: tile.maxX - 1, y: tile.midY - 10, width: 1, height: 20)
        let inside = NSRect(x: tile.maxX - 2, y: tile.midY - 10, width: 1, height: 20)
        #expect(gridRasterHits(bitmap, in: stroke, isAccent) == 20, "\(page): 1px accent stroke")
        #expect(gridRasterHits(bitmap, in: inside, isAccent) == 0, "\(page): stroke is 1px")
    }
}
