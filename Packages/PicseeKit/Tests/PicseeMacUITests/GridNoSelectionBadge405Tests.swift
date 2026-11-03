import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

// Owner decision 2026-11-03 (#405, 1B): no ✓ badge at any selection count. This deviates from pinned page 32
// (grid-multiselect), whose `.photo-cell.is-selected .thumbnail-wrap:after{content:"✓"}` draws one on every
// selected cell. Native selection is the 1pt accent stroke plus the tinted name row.

/// Page 32's live badge rule.
let gridBadgeSelector = ".photo-cell.is-selected .thumbnail-wrap:after"

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

/// Page 32's badge box `right:7px;top:7px;width:18px;height:18px` (border-box), measured in the tile.
func gridSelectedCheckRegion(tile: NSRect) throws -> NSRect {
    let design = try PinnedDesign.page("grid-multiselect")
    let right = try design.length(gridBadgeSelector, "right", viewport: 1280)
    let top = try design.length(gridBadgeSelector, "top", viewport: 1280)
    let width = try design.length(gridBadgeSelector, "width", viewport: 1280)
    let height = try design.length(gridBadgeSelector, "height", viewport: 1280)
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

/// Pixels in page 32's badge box within 3/255 of its pinned `background` (badge fill) as rendered.
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

/// Page 32's badge `background` per appearance, resolved through page 32's own `.theme-light`/`.theme-dark` tokens.
func gridSelectedCheckFill(_ appearance: NSAppearance.Name) throws -> PinnedDesign.Color {
    try PinnedDesign.page("grid-multiselect", appearance: appearance == .darkAqua ? "dark" : "light")
        .color(gridBadgeSelector, "background", viewport: 1280)
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

// The deviation, pinned both ways: page 32 does draw the badge, and the native cell does not.
@Test @MainActor func issue405Page32DrawsBadgeButNativeCellOmitsItByOwnerDecision() throws {
    let page32 = try PinnedDesign.page("grid-multiselect")
    #expect(page32.classCount("is-selected") == 3, "page 32 has three selected cells")
    #expect(try page32.raw(gridBadgeSelector, "content", viewport: 1280) == "\"✓\"", "page 32 draws ✓ per selected cell")
    #expect(try page32.raw(gridBadgeSelector, "position", viewport: 1280) == "absolute")
    #expect(try page32.length(gridBadgeSelector, "right", viewport: 1280) == 7)
    #expect(try page32.length(gridBadgeSelector, "top", viewport: 1280) == 7)
    #expect(try page32.length(gridBadgeSelector, "width", viewport: 1280) == 18)
    #expect(try page32.length(gridBadgeSelector, "height", viewport: 1280) == 18)
    #expect(try page32.border(gridBadgeSelector).width == 1, "1px on-accent border")
    let onAccent = try page32.color(":root", "--color-on-accent", viewport: 1280)
    let border = try page32.color(gridBadgeSelector, "border", viewport: 1280)
    #expect(border.red == onAccent.red && border.green == onAccent.green && border.blue == onAccent.blue)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let fill = try gridSelectedCheckFill(appearance)
        let accent = try PinnedDesign.page("grid-multiselect", appearance: appearance == .darkAqua ? "dark" : "light")
            .color(":root", "--color-accent-fill", viewport: 1280)
        #expect(fill.alpha > 0.9, "\(appearance.rawValue) fill is opaque")
        #expect(fill.red == accent.red && fill.green == accent.green && fill.blue == accent.blue,
            "\(appearance.rawValue) fill is the accent fill")
        let (grid, window, entries, root, folder) = badgeGrid(3, folderName: "picsee-405-deviation")
        _ = window
        grid.appearance = NSAppearance(named: appearance)
        let ids = entries.map(\.itemID)
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
            entries: entries, isComplete: true), selection: BrowserSelection())
        var selection = BrowserSelection()
        for (count, step) in [(0, { (_: inout BrowserSelection) in }),
                              (1, { $0.click(ids[0], in: ids) }),
                              (3, { $0.click(ids[2], modifier: .shift, in: ids) })] as [(Int, (inout BrowserSelection) -> Void)] {
            step(&selection)
            grid.synchronizeSelection(selection)
            #expect(grid.selection.selectedItemIDs.count == count, "\(appearance.rawValue) count \(count)")
            for cell in visibleCells(grid) {
                #expect(gridCheckGlyphs(in: cell.view).isEmpty, "\(appearance.rawValue) count \(count): no ✓ in tree")
                #expect(try gridCheckRegionHits(cell, fill: fill) == 0, "\(appearance.rawValue) count \(count): badge fill drawn")
                #expect(try gridTileSurfaceHits(cell) > 300, "\(appearance.rawValue) count \(count): raster sees subview layers")
            }
        }
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
                    "\(appearance.rawValue) count \(count) selected \(selected): badge fill drawn")
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
            #expect(try gridCheckRegionHits(cell, fill: fill) == 0, "\(phase): badge fill drawn")
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
                #expect(try gridCheckRegionHits(cell, fill: fill) == 0, "\(state): badge fill drawn")
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
