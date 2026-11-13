import AppKit
import Foundation
import Testing
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

@Test(.timeLimit(.minutes(2))) func sidebarHeadingIsCataloguedWithoutChineseLiteralInSource() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let root = tests.deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent(
        "Packages/MadoKit/Sources/MadoMacUI/Grid/GridSidebarTreeView.swift"), encoding: .utf8)
    #expect(!source.contains("文件夹"))
    let catalog = try String(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"), encoding: .utf8)
    #expect(catalog.contains("\"Folders\""))
    #expect(catalog.contains("\"文件夹\""))
    for file in ["GridSidebarTreeView.swift", "GridShellView.swift"] {
        let sidebar = try String(contentsOf: root.appendingPathComponent(
            "Packages/MadoKit/Sources/MadoMacUI/Grid/\(file)"), encoding: .utf8)
        let rawAccessibilityText = #"setAccessibility(?:Label|Value|Help|Title|Description)\s*\(\s*"[^"\\]*""#
        #expect(sidebar.range(of: rawAccessibilityText, options: .regularExpression) == nil,
                "\(file) passes a literal to a user-visible accessibility setter")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarTreeRowsFollowPinnedOptionAGeometryAndCounts() throws {
    _ = NSApplication.shared
    let design = try PinnedDesign.page("grid-light")
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    let root = URL(fileURLWithPath: "/tmp/Images")
    let longName = String(repeating: "长目录名", count: 20)
    let children = [GridSidebarFolder(url: root.appendingPathComponent(longName), count: 0),
                    GridSidebarFolder(url: root.appendingPathComponent("English folder with a long name"), count: 1234),
                    GridSidebarFolder(url: root.appendingPathComponent("Unknown"))]
    tree.show(current: GridSidebarFolder(url: root, count: 8), parent: nil, children: children)
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows.count == 4)
    let current = try #require(tree.rows.first)
    #expect(current.glyph.image != nil)
    #expect(current.countLabel.stringValue == "8")
    let rowHeight = try design.length(".ds-nav-row", "min-height", viewport: 1280)
    #expect(abs(Double(current.frame.height) - rowHeight) < 0.1)
    #expect(current.nameLabel.maximumNumberOfLines == 1)
    #expect(current.nameLabel.lineBreakMode == .byTruncatingTail)
    #expect(tree.rows[1].countLabel.stringValue == "0")
    #expect(tree.heading.stringValue == String(localized: "Folders"))
    #expect(tree.rows[0].accessibilityValue() as? String == String(localized: "Selected"))
    #expect(tree.rows[1].glyph.frame.width == 16)
    #expect(tree.rows[1].countLabel.alphaValue == 0.8)
    #expect(tree.rows[2].countLabel.stringValue == "1234")
    #expect(tree.rows[3].countLabel.stringValue.isEmpty)
    #expect(tree.rows[1].frame.minX > current.frame.minX)
    #expect(tree.guide.frame.width == 1)
    #expect(tree.guide.frame.minX < tree.rows[1].frame.minX)
    #expect(tree.rows.allSatisfy { $0.frame.maxX <= tree.bounds.maxX })
    #expect(tree.rows[1].accessibilityLabel()?.contains("0") == true)
    #expect(tree.rows[3].accessibilityLabel()?.contains("Unknown") == true)
    #expect(tree.rows[3].accessibilityLabel()?.contains("images") == false)
    tree.frame = NSRect(x: 0, y: 0, width: 160, height: 612)
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows.allSatisfy { $0.nameLabel.frame.maxX <= $0.countLabel.frame.minX || $0.countLabel.isHidden })
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarTreeParentAndKeyboardSelectionUseActualURLs() throws {
    _ = NSApplication.shared
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    let parent = URL(fileURLWithPath: "/tmp/Images")
    let current = parent.appendingPathComponent("Trip")
    let child = current.appendingPathComponent("Day 1")
    var chosen: URL?
    tree.onSelectFolder = { chosen = $0 }
    tree.show(current: .init(url: current), parent: .init(url: parent), children: [.init(url: child)])
    tree.layoutSubtreeIfNeeded()
    try #require(tree.rows.count == 3)
    #expect(tree.rows.map(\.folderURL) == [parent, current, child])
    #expect(tree.rows[1].current)
    #expect(tree.rows[0].acceptsFirstResponder)
    tree.rows[0].performClick(nil)
    #expect(chosen == parent)
    chosen = nil
    let returnKey = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36))
    tree.rows[2].keyDown(with: returnKey)
    #expect(chosen == child)
    chosen = nil
    let keypadEnter = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 76))
    tree.rows[2].keyDown(with: keypadEnter)
    #expect(chosen == child)
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarTreeCompactIndentUsesPinnedBreakpoint() throws {
    _ = NSApplication.shared
    let design = try PinnedDesign.page("compact-grid")
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 612))
    tree.viewportWidth = 800
    let root = URL(fileURLWithPath: "/tmp/Photos")
    tree.show(current: .init(url: root), parent: nil, children: [.init(url: root.appendingPathComponent("Long child"), count: 0)])
    tree.layoutSubtreeIfNeeded()
    let wideMargin = try design.edges(".folder-children", "margin", viewport: 800).left
    let widePadding = try design.length(".folder-children", "padding-left", viewport: 800)
    #expect(abs(Double(tree.rows[1].frame.minX) - (12 + wideMargin + 1 + widePadding)) < 0.1)
    #expect(tree.rows[1].nameLabel.font?.pointSize == 13)
    tree.viewportWidth = 700
    tree.layoutSubtreeIfNeeded()
    let narrowMargin = try design.edges(".folder-children", "margin", viewport: 700).left
    let narrowPadding = try design.length(".folder-children", "padding-left", viewport: 700)
    #expect(abs(Double(tree.rows[1].frame.minX) - (12 + narrowMargin + 1 + narrowPadding)) < 0.1)
    #expect(tree.rows[1].nameLabel.font?.pointSize == 12)
    #expect(tree.rows[1].frame.maxX <= tree.bounds.maxX)
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarTreeSelectedFillFollowsPinnedLightAndDarkCSS() throws {
    _ = NSApplication.shared
    for (name, appearanceName) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(name)
        let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
        tree.appearance = try #require(NSAppearance(named: appearanceName))
        tree.show(current: .init(url: URL(fileURLWithPath: "/tmp/Images"), count: 4), parent: nil, children: [])
        tree.layoutSubtreeIfNeeded()
        let row = try #require(tree.rows.first)
        let color = try #require(row.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        let pinned = try design.color(".ds-nav-row[aria-current=\"page\"]", "background", viewport: 1280)
        #expect(abs(Double(color.redComponent) - pinned.red) < 0.01)
        #expect(abs(Double(color.greenComponent) - pinned.green) < 0.01)
        #expect(abs(Double(color.blueComponent) - pinned.blue) < 0.01)
        #expect(abs(Double(color.alphaComponent) - pinned.alpha) < 0.01)
        let root = URL(fileURLWithPath: "/tmp/Images")
        tree.show(current: .init(url: root, count: 4), parent: nil,
            children: [.init(url: root.appendingPathComponent("Child"), count: 2)])
        tree.layoutSubtreeIfNeeded()
        var resolvedHeadingColor: NSColor?
        tree.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedHeadingColor = tree.heading.textColor?.usingColorSpace(.sRGB)
        }
        let headingColor = try #require(resolvedHeadingColor)
        let pinnedHeading = try design.color(".sidebar-heading", "color", viewport: 1280)
        #expect(abs(Double(headingColor.redComponent) - pinnedHeading.red) < 0.01)
        #expect(abs(Double(headingColor.greenComponent) - pinnedHeading.green) < 0.01)
        #expect(abs(Double(headingColor.blueComponent) - pinnedHeading.blue) < 0.01)
        let headerPadding = try design.edges(".sidebar-heading", "padding", viewport: 1280)
        #expect(abs(Double(tree.heading.frame.minX) - (12 + headerPadding.left)) < 0.1)
        let guideColor = try #require(tree.guide.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))?.usingColorSpace(.sRGB))
        let pinnedGuide = try design.color(".folder-children", "border-left", viewport: 1280)
        #expect(abs(Double(guideColor.redComponent) - pinnedGuide.red) < 0.01)
        #expect(abs(Double(guideColor.greenComponent) - pinnedGuide.green) < 0.01)
        #expect(abs(Double(guideColor.blueComponent) - pinnedGuide.blue) < 0.01)
        let count = tree.rows[1].countLabel
        var resolvedCountColor: NSColor?
        tree.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolvedCountColor = count.textColor?.usingColorSpace(.sRGB)
        }
        let countColor = try #require(resolvedCountColor)
        let pinnedCount = try design.color(".ds-nav-row .row-count", "color", viewport: 1280)
        #expect(abs(Double(countColor.redComponent) - pinnedCount.red) < 0.01)
        #expect(abs(Double(countColor.greenComponent) - pinnedCount.green) < 0.01)
        #expect(abs(Double(countColor.blueComponent) - pinnedCount.blue) < 0.01)
        #expect(count.font?.pointSize == 12)
        #expect(count.font?.familyName?.contains("Mono") == true)
        #expect(count.alphaValue == 0.8)
        #expect(tree.heading.attributedStringValue.attribute(.kern, at: 0, effectiveRange: nil) as? Double == 0.48)
    }
}
