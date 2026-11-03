import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

// Owner decision 2026-11-03 (#405): no ✓ badge at any selection count. Pinned pages 11 (grid-light)
// and 32 (grid-multiselect) draw no `.selected-check` element on any `.photo-cell.is-selected` cell;
// selection is the 1pt accent outline plus the tinted name row (DESIGN.md L79).

/// Every "✓" text in the cell's view and layer trees, hidden or not.
@MainActor func gridCheckGlyphs(in view: NSView) -> [String] {
    var found: [String] = []
    func walk(_ layer: CALayer) {
        if let text = layer as? CATextLayer {
            let string = (text.string as? String) ?? (text.string as? NSAttributedString)?.string ?? ""
            if string.contains("✓") { found.append(string) }
        }
        layer.sublayers?.forEach(walk)
    }
    func walk(_ view: NSView) {
        if let field = view as? NSTextField, field.stringValue.contains("✓") { found.append(field.stringValue) }
        view.subviews.forEach(walk)
    }
    walk(view)
    if let layer = view.layer { walk(layer) }
    return found
}

/// The cell's layer tree rendered at 1x into sRGB. `layer.render(in:)` because cacheDisplay skips layer-backed
/// descendants; a cell outside a window is hosted in one so AppKit attaches its subviews' layers.
@MainActor func gridCellRaster(_ cell: GridPhotoItem) throws -> NSBitmapImageRep { try gridViewRaster(cell.view) }

@MainActor func gridViewRaster(_ view: NSView) throws -> NSBitmapImageRep {
    var host: NSWindow?
    if view.window == nil {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.frame.size),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView?.addSubview(view)
        host = window
    }
    defer { if host != nil { view.removeFromSuperview() } }
    view.layoutSubtreeIfNeeded()
    view.window?.displayIfNeeded()
    let size = view.bounds.size
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil, width: Int(size.width.rounded(.up)),
        height: Int(size.height.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let layer = try #require(view.layer)
    view.effectiveAppearance.performAsCurrentDrawingAppearance { layer.render(in: context) }
    return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
}

/// Pixels (view coordinates, y up) inside `rect` that satisfy `match`.
func gridRasterHits(_ bitmap: NSBitmapImageRep, in rect: NSRect, _ match: (NSColor) -> Bool) -> Int {
    var hits = 0
    for x in max(0, Int(rect.minX.rounded(.down)))..<min(bitmap.pixelsWide, Int(rect.maxX.rounded(.up))) {
        for y in max(0, Int(rect.minY.rounded(.down)))..<min(bitmap.pixelsHigh, Int(rect.maxY.rounded(.up))) {
            guard let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh - 1 - y)?.usingColorSpace(.sRGB) else { continue }
            if match(color) { hits += 1 }
        }
    }
    return hits
}

/// grid-multiselect.html `.selected-check{right:8px;top:8px;width:19px;height:19px}`, measured in the tile.
func gridSelectedCheckRegion(tile: NSRect) throws -> NSRect {
    let design = try PinnedDesign.page("grid-multiselect")
    let right = try design.length(".selected-check", "right", viewport: 1280)
    let top = try design.length(".selected-check", "top", viewport: 1280)
    let width = try design.length(".selected-check", "width", viewport: 1280)
    let height = try design.length(".selected-check", "height", viewport: 1280)
    return NSRect(x: tile.maxX - right - width, y: tile.maxY - top - height, width: width, height: height)
}

/// A pinned colour as this raster path renders it: hosted layers are colour-matched on the way out, so a plain
/// layer filled with the CSS value is the reference, not the raw CSS components.
@MainActor func gridRenderedColor(_ color: PinnedDesign.Color) throws -> NSColor {
    let swatch = NSView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    swatch.wantsLayer = true
    swatch.layer?.backgroundColor = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    return try #require(gridViewRaster(swatch).colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
}

/// Pixels in the `.selected-check` region within 3/255 of its pinned `background` (badge fill) as rendered.
@MainActor func gridCheckRegionHits(_ cell: GridPhotoItem, fill: PinnedDesign.Color) throws -> Int {
    let tile = try #require(cell.tileLayer).frame
    let target = try gridRenderedColor(fill)
    let tolerance = 3.0 / 255
    return gridRasterHits(try gridCellRaster(cell), in: try gridSelectedCheckRegion(tile: tile)) { color in
        color.alphaComponent > 0.5 && abs(color.redComponent - target.redComponent) <= tolerance
            && abs(color.greenComponent - target.greenComponent) <= tolerance
            && abs(color.blueComponent - target.blueComponent) <= tolerance
    }
}

/// Positive control: the raster composites the cell's subview layers (the opaque tile surface under the region).
@MainActor func gridTileSurfaceHits(_ cell: GridPhotoItem) throws -> Int {
    let tile = try #require(cell.tileLayer).frame
    return gridRasterHits(try gridCellRaster(cell), in: try gridSelectedCheckRegion(tile: tile)) { $0.alphaComponent > 0.99 }
}

/// `.selected-check` background per appearance: page 32 is light-only, so dark comes from page 12.
func gridSelectedCheckFill(_ appearance: NSAppearance.Name) throws -> PinnedDesign.Color {
    try PinnedDesign.page(appearance == .darkAqua ? "grid-dark" : "grid-multiselect")
        .color(".selected-check", "background", viewport: 1280)
}

@MainActor private func badgeGrid(_ count: Int, folderName: String)
    -> (GridBrowserView, NSWindow, [FolderEntry], ItemIdentityRoot, URL) {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/\(folderName)")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<count).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
    let window = NSWindow(contentRect: grid.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    return (grid, window, entries, root, folder)
}

@MainActor private func visibleCells(_ grid: GridBrowserView) -> [GridPhotoItem] {
    grid.layoutSubtreeIfNeeded()
    grid.collectionView.layoutSubtreeIfNeeded()
    return grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }
}

@MainActor private func treeSize(_ view: NSView) -> (views: Int, layers: Int) {
    func layers(_ layer: CALayer) -> Int { 1 + (layer.sublayers ?? []).reduce(0) { $0 + layers($1) } }
    func views(_ view: NSView) -> Int { 1 + view.subviews.reduce(0) { $0 + views($1) } }
    return (views(view), view.layer.map(layers) ?? 0)
}

@Test func issue405PinnedPagesDrawNoSelectedCheckElement() throws {
    for (page, minimumSelected) in [("grid-light", 1), ("grid-dark", 1), ("grid-multiselect", 2)] {
        let design = try PinnedDesign.page(page)
        #expect(design.classCount("selected-check") == 0, "\(page): no .selected-check element")
        #expect(design.classCount("is-selected") >= minimumSelected, "\(page): .photo-cell.is-selected present")
    }
    let page32 = try PinnedDesign.page("grid-multiselect")
    #expect(page32.classCount("is-selected") == 3, "page 32 has three selected cells")
    // grid-multiselect.html `.selected-check` right/top 8px, width/height 19px: the region the raster samples.
    #expect(try page32.length(".selected-check", "right", viewport: 1280) == 8)
    #expect(try page32.length(".selected-check", "top", viewport: 1280) == 8)
    #expect(try page32.length(".selected-check", "width", viewport: 1280) == 19)
    #expect(try page32.length(".selected-check", "height", viewport: 1280) == 19)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        #expect(try gridSelectedCheckFill(appearance).alpha > 0.9, "\(appearance.rawValue) fill is opaque")
    }
}

@Test @MainActor func issue405SelectionCountWalkNeverRendersBadge() throws {
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let (grid, window, entries, root, folder) = badgeGrid(6, folderName: "picsee-405-walk")
        _ = window
        grid.appearance = NSAppearance(named: appearance)
        let ids = entries.map(\.itemID)
        let fill = try gridSelectedCheckFill(appearance)
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
            entries: entries, isComplete: true), selection: BrowserSelection())
        var selection = BrowserSelection()
        let steps: [(Int, (inout BrowserSelection) -> Void)] = [
            (0, { _ in }),
            (1, { $0.click(ids[0], in: ids) }),
            (2, { $0.click(ids[2], modifier: .command, in: ids) }),
            (6, { $0.click(ids[0], in: ids); $0.click(ids[5], modifier: .shift, in: ids) }),
            (1, { $0.click(ids[3], in: ids) }),
            (0, { $0.clearSelection() })
        ]
        for (count, step) in steps {
            step(&selection)
            grid.synchronizeSelection(selection)
            #expect(grid.selection.selectedItemIDs.count == count, "\(appearance.rawValue) step \(count)")
            let cells = visibleCells(grid)
            #expect(cells.count == 6)
            for cell in cells {
                let id = try #require(cell.representedItemID)
                let selected = grid.selection.selectedItemIDs.contains(id)
                #expect(cell.isSelected == selected)
                #expect(gridCheckGlyphs(in: cell.view).isEmpty, "\(appearance.rawValue) count \(count): no ✓ in tree")
                #expect(try gridCheckRegionHits(cell, fill: fill) == 0,
                    "\(appearance.rawValue) count \(count) selected \(selected): .selected-check fill drawn")
                #expect(try gridTileSurfaceHits(cell) > 300, "\(appearance.rawValue) count \(count): raster sees subview layers")
            }
        }
    }
}

@Test @MainActor func issue405ReloadedAndRedisplayedCellsStayBadgeFree() throws {
    let (grid, window, entries, root, folder) = badgeGrid(3, folderName: "picsee-405-reuse")
    _ = window
    grid.appearance = NSAppearance(named: .aqua)
    let fill = try gridSelectedCheckFill(.aqua)
    let ids = entries.map(\.itemID)
    var selection = BrowserSelection()
    selection.click(ids[0], in: ids)
    selection.click(ids[2], modifier: .command, in: ids)
    func check(_ phase: String) throws {
        for cell in visibleCells(grid) {
            let id = try #require(cell.representedItemID)
            let selected = grid.selection.selectedItemIDs.contains(id)
            #expect(cell.isSelected == selected, "\(phase)")
            #expect(gridCheckGlyphs(in: cell.view).isEmpty, "\(phase): no ✓ in tree")
            #expect(try gridCheckRegionHits(cell, fill: fill) == 0, "\(phase): .selected-check fill drawn")
            #expect(try gridTileSurfaceHits(cell) > 300, "\(phase): raster sees subview layers")
        }
    }
    grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true), selection: selection)
    try check("display gen1")
    let added = FolderEntry(url: folder.appendingPathComponent("new.jpg"), root: root)
    grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 2),
        entries: [entries[2], entries[0], entries[1], added], isComplete: true), selection: selection)
    #expect(grid.selection.selectedItemIDs == [ids[0], ids[2]])
    try check("display gen2 reordered")
    grid.collectionView.reloadItems(at: Set((0..<4).map { IndexPath(item: $0, section: 0) }))
    try check("reloaded")
    grid.synchronizeSelection(selection)
    let before = visibleCells(grid).map { treeSize($0.view) }
    grid.synchronizeSelection(selection)
    let after = visibleCells(grid).map { treeSize($0.view) }
    #expect(before.map(\.views) == after.map(\.views), "identical sync adds no views")
    #expect(before.map(\.layers) == after.map(\.layers), "identical sync adds no layers")
    try check("synced twice")
    selection.click(ids[2], modifier: .command, in: grid.displayedItemIDs)
    grid.synchronizeSelection(selection)
    #expect(grid.selection.selectedItemIDs.count == 1)
    try check("reused down to 1")
    selection.clearSelection()
    grid.synchronizeSelection(selection)
    try check("reused down to 0")
}

@Test @MainActor func issue405ExhaustiveCellStateDomainHasNoBadge() throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-405-domain")
    let entry = FolderEntry(url: folder.appendingPathComponent("DSC_0342.jpg"),
        root: ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder))
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let fill = try gridSelectedCheckFill(appearance)
        for selected in [false, true] { for current in [false, true] { for names in [true, false] {
            for width: CGFloat in [120, 220, 400] { for setBeforeLoad in [false, true] {
                let state = "\(appearance.rawValue) sel=\(selected) cur=\(current) names=\(names) w=\(width) early=\(setBeforeLoad)"
                let cell = GridPhotoItem()
                if setBeforeLoad { cell.isSelected = selected; cell.isCurrent = current }
                cell.view.frame = NSRect(x: 0, y: 0, width: width, height: width * 184 / 220)
                cell.apply(GridDisplayOptions(showFileNames: names))
                cell.configure(entry)
                cell.view.appearance = NSAppearance(named: appearance)
                if !setBeforeLoad { cell.isSelected = selected; cell.isCurrent = current }
                cell.view.layoutSubtreeIfNeeded()
                #expect(gridCheckGlyphs(in: cell.view).isEmpty, "\(state): no ✓ in tree")
                #expect(try gridCheckRegionHits(cell, fill: fill) == 0, "\(state): .selected-check fill drawn")
                #expect(try gridTileSurfaceHits(cell) > 300, "\(state): raster sees subview layers")
                #expect(cell.currentRingLayer.isHidden == !current, "\(state): ring ⇔ current")
                let expected = selected && current ? "Selected, Current" : selected ? "Selected" : current ? "Current" : ""
                #expect(cell.view.accessibilityValue() as? String == String(localized: String.LocalizationValue(expected)),
                    "\(state): AX value")
            } }
        } } }
    }
}

@Test @MainActor func issue405SelectedCellKeepsPinnedOutlineAndNameRow() throws {
    for (page, appearance) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(page)
        let cell = GridPhotoItem()
        cell.view.frame = NSRect(x: 0, y: 0, width: 247, height: 224.16)
        cell.view.appearance = NSAppearance(named: appearance)
        let folder = URL(fileURLWithPath: "/tmp/picsee-405-outline")
        cell.configure(FolderEntry(url: folder.appendingPathComponent("DSC_0342.jpg"),
            root: ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)))
        cell.isSelected = true
        cell.view.layoutSubtreeIfNeeded()
        #expect(gridCheckGlyphs(in: cell.view).isEmpty, "\(page)")
        #expect(try gridCheckRegionHits(cell, fill: try gridSelectedCheckFill(appearance)) == 0, "\(page)")
        let tile = try #require(cell.tileLayer)
        let outline = try #require(cell.view.layer?.sublayers?.first {
            $0 !== cell.currentRingLayer && $0.borderWidth == 1 && !$0.isHidden
        })
        #expect(outline.frame == tile.frame, "\(page): outline at the tile edge")
        let accent = try design.color(":root", "--color-accent", viewport: 1280)
        let border = try #require(outline.borderColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(abs(border.redComponent - accent.red) < 0.01, "\(page)")
        #expect(abs(border.greenComponent - accent.green) < 0.01, "\(page)")
        #expect(abs(border.blueComponent - accent.blue) < 0.01, "\(page)")
        let name = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "DSC_0342.jpg" })
        let expectedFill = try design.color(".layout-exploration .photo-cell.is-selected .photo-name",
            "background", viewport: 1280)
        let fill = try #require(name.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        #expect(abs(fill.redComponent - expectedFill.red) < 0.01, "\(page)")
        #expect(abs(fill.greenComponent - expectedFill.green) < 0.01, "\(page)")
        #expect(abs(fill.blueComponent - expectedFill.blue) < 0.01, "\(page)")
        #expect(abs(fill.alphaComponent - expectedFill.alpha) < 0.01, "\(page)")
        #expect(cell.view.accessibilityValue() as? String == String(localized: "Selected"))
    }
}

