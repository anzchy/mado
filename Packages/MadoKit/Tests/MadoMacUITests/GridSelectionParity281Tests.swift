import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) @MainActor func issue281CurrentRingIsOutsideThumbnailAndNameRowMatchesPinnedSelection() throws {
    for (page, appearanceName) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(page)
        let cell = GridPhotoItem()
        cell.view.frame = NSRect(x: 0, y: 0, width: 247, height: 224.16)
        cell.view.appearance = try #require(NSAppearance(named: appearanceName))
        let folder = URL(fileURLWithPath: "/tmp/mado-grid-281-selection")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
        let longName = String(repeating: "旅行Photo", count: 20) + ".jpg"
        cell.configure(FolderEntry(url: folder.appendingPathComponent(longName), root: root))
        cell.view.layoutSubtreeIfNeeded()
        cell.isCurrent = true
        cell.isSelected = true
        let tile = try #require(cell.tileLayer)
        let ring = cell.currentRingLayer
        let name = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == longName })

        // grid-light.html: outline-width 2 and outline-offset 2 put painted edges at +2 and +4.
        #expect(ring.superlayer === cell.view.layer, "current ring is outside the thumbnail's clipped layer")
        #expect(ring.frame == tile.frame.insetBy(dx: -4, dy: -4), "2px clear gap plus 2px stroke")
        #expect(ring.frame.minX == tile.frame.minX - 4, "painted inner edge at tile - 2")
        #expect(ring.frame.maxX == tile.frame.maxX + 4, "painted outer edge at tile + 4")
        #expect(ring.borderWidth == 2)
        let selection = try #require(cell.view.layer?.sublayers?.first {
            $0 !== ring && $0.borderWidth == 1 && !$0.isHidden
        })
        #expect(selection.frame == tile.frame, "Selection stays distinct at the thumbnail edge")
        let expectedAccent = try design.color(":root", "--color-accent", viewport: 1280)
        let ringColor = try #require(ring.borderColor)
        let accent = try #require(NSColor(cgColor: ringColor)?.usingColorSpace(.sRGB))
        #expect(abs(accent.redComponent - expectedAccent.red) < 0.01)
        #expect(abs(accent.greenComponent - expectedAccent.green) < 0.01)
        #expect(abs(accent.blueComponent - expectedAccent.blue) < 0.01)

        // grid-light.html: .photo-name has margin 7px 0 0, padding 2px 5px and line-height 17px.
        #expect(name.frame.height == 21)
        #expect(tile.frame.minY - name.frame.maxY == 7)
        #expect(Double(name.layer?.cornerRadius ?? 0) == DesignMetrics.radii["inner"]!)
        #expect(name.maximumNumberOfLines == 1)
        #expect(name.lineBreakMode == .byTruncatingTail)
        #expect(name.frame.maxX <= cell.view.bounds.maxX)
        let expectedFill = try design.color(".layout-exploration .photo-cell.is-selected .photo-name",
            "background", viewport: 1280)
        let fillColor = try #require(name.layer?.backgroundColor)
        let fill = try #require(NSColor(cgColor: fillColor)?.usingColorSpace(.sRGB))
        #expect(abs(fill.redComponent - expectedFill.red) < 0.01)
        #expect(abs(fill.greenComponent - expectedFill.green) < 0.01)
        #expect(abs(fill.blueComponent - expectedFill.blue) < 0.01)
        #expect(abs(fill.alphaComponent - expectedFill.alpha) < 0.01)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue281CurrentItemAloneHasTintedNameRowAndNoSelectionBadge() throws {
    for (page, appearanceName) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(page)
        let cell = GridPhotoItem()
        cell.view.frame = NSRect(x: 0, y: 0, width: 247, height: 224.16)
        cell.view.appearance = try #require(NSAppearance(named: appearanceName))
        let folder = URL(fileURLWithPath: "/tmp/mado-grid-281-current")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
        cell.configure(FolderEntry(url: folder.appendingPathComponent("DSC_0342.jpg"), root: root))
        cell.view.layoutSubtreeIfNeeded()
        // Folder open: Current Item set, nothing selected yet (device shot 11-grid-light: ring, white name row).
        cell.isCurrent = true
        cell.isSelected = false
        let name = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "DSC_0342.jpg" })
        // grid-light.html: the single .is-selected cell is the Current Item: ring plus tinted name row, no ✓.
        #expect(!cell.currentRingLayer.isHidden)
        // Owner decision 2026-11-03 (#405): no ✓ badge at any selection count.
        #expect(gridCheckGlyphs(in: cell.view).isEmpty)
        let expectedFill = try design.color(".layout-exploration .photo-cell.is-selected .photo-name",
            "background", viewport: 1280)
        let fillColor = try #require(name.layer?.backgroundColor)
        let fill = try #require(NSColor(cgColor: fillColor)?.usingColorSpace(.sRGB))
        #expect(abs(fill.redComponent - expectedFill.red) < 0.01, "\(page)")
        #expect(abs(fill.greenComponent - expectedFill.green) < 0.01, "\(page)")
        #expect(abs(fill.blueComponent - expectedFill.blue) < 0.01, "\(page)")
        #expect(abs(fill.alphaComponent - expectedFill.alpha) < 0.01, "\(page)")

        cell.isCurrent = false
        #expect(name.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }?.alphaComponent ?? 0 == 0,
                "a cell that is neither Current nor selected has no tint")
    }
}
