import AppKit
import Testing
import MadoApplication
@testable import MadoMacUI

@MainActor private func t232Color(_ color: NSColor?, equals expected: PinnedDesign.Color) throws {
    let actual = try #require(color?.usingColorSpace(.sRGB))
    print("t232 color actual=\(actual.redComponent),\(actual.greenComponent),\(actual.blueComponent),\(actual.alphaComponent) expected=\(expected)")
    #expect(abs(actual.redComponent - expected.red) < 0.01)
    #expect(abs(actual.greenComponent - expected.green) < 0.01)
    #expect(abs(actual.blueComponent - expected.blue) < 0.01)
    #expect(abs(actual.alphaComponent - expected.alpha) < 0.01)
}

@Test(arguments: [NSAppearance.Name.aqua, .darkAqua]) @MainActor
func t232LostSidebarRowMatchesPermissionDeniedRenderedFrames(_ appearanceName: NSAppearance.Name) throws {
    _ = NSApplication.shared
    let page = try PinnedDesign.page("permission-denied", appearance: appearanceName == .aqua ? "light" : "dark")
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    tree.appearance = try #require(NSAppearance(named: appearanceName))
    let parent = URL(fileURLWithPath: "/tmp/Photos")
    let current = parent.appendingPathComponent("Trip")
    tree.show(current: .init(url: current, count: 8), parent: .init(url: parent, count: 12),
        children: [.init(url: current.appendingPathComponent("Day 1"), count: 3)])
    tree.layoutSubtreeIfNeeded()
    let normalFrame = tree.rows[1].frame
    let normalGlyphFrame = tree.rows[1].glyph.frame
    let normalNameX = tree.rows[1].nameLabel.frame.minX

    tree.show(current: .init(url: current, count: 8, accessLossCause: .accessExpired),
        parent: .init(url: parent, count: 12),
        children: [.init(url: current.appendingPathComponent("Day 1"), count: 3)])
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows.map(\.folderURL) == [parent, current])
    #expect(tree.children.isEmpty)
    #expect(tree.guide.isHidden)
    let row = tree.rows[1]
    #expect(row.frame == normalFrame)
    #expect(row.glyph.frame == normalGlyphFrame)
    #expect(row.nameLabel.frame.minX == normalNameX)
    let pinnedRowHeight = CGFloat(try page.length(".ds-nav-row", "min-height", viewport: 1280))
    #expect(row.frame.height == pinnedRowHeight)
    #expect(row.countLabel.isHidden)
    #expect(!row.warningGlyph.isHidden)
    #expect(row.warningGlyph.frame.size == NSSize(width: 14, height: 14))
    #expect(row.warningGlyph.accessibilityLabel() == String(localized: "Unavailable"))
    #expect(!row.disclosureGlyph.isHidden)
    #expect(row.disclosureGlyph.frame.size == NSSize(width: 12, height: 12))
    let pinnedDisclosure = try #require(NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?.tiffRepresentation)
    #expect(row.disclosureGlyph.image?.tiffRepresentation == pinnedDisclosure)
    #expect(row.disclosureGlyph.frame.minX > row.warningGlyph.frame.maxX)
    #expect(row.nameLabel.frame.maxX <= row.warningGlyph.frame.minX)

    let unavailable = ".sidebar .ds-nav-row.is-unavailable[aria-current=\"page\"]"
    try t232Color(row.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)),
        equals: page.color(unavailable, "background", viewport: 1280))
    try t232Color(row.nameLabel.textColor, equals: page.color(unavailable, "color", viewport: 1280))
    try t232Color(row.glyph.contentTintColor,
        equals: page.color("\(unavailable) svg", "color", viewport: 1280))
    try t232Color(row.warningGlyph.contentTintColor,
        equals: page.color("\(unavailable) .row-warning svg", "color", viewport: 1280))
    try t232Color(row.disclosureGlyph.contentTintColor,
        equals: page.color(".sidebar .ds-nav-row .row-disclosure", "color", viewport: 1280))
    let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
    row.cacheDisplay(in: row.bounds, to: bitmap)
    #expect(bitmap.pixelsWide == Int(row.frame.width) && bitmap.pixelsHigh == 32)

    tree.show(current: .init(url: current, count: 8), parent: .init(url: parent, count: 12),
        children: [.init(url: current.appendingPathComponent("Day 1"), count: 3)])
    tree.layoutSubtreeIfNeeded()
    #expect(tree.rows.count == 3)
    #expect(tree.rows[1].warningGlyph.isHidden && tree.rows[1].disclosureGlyph.isHidden)
    #expect(!tree.rows[1].countLabel.isHidden)
}

@Test(arguments: [
    (AccessLossCause.accessExpired, "Access Has Expired"),
    (.diskNotConnected, "External Disk Is Not Connected"),
    (.notFound, "Not Found"),
    (.unknown, "Unable to Access This Folder"),
]) @MainActor
func t232LostSidebarAccessibilityUsesPage26CauseCopy(_ sample: (cause: AccessLossCause, title: String)) throws {
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    let folder = URL(fileURLWithPath: "/tmp/Trip")
    let expected = "\(String(localized: "Unavailable")), \(String(localized: String.LocalizationValue(sample.title)))"
    tree.show(current: .init(url: folder, count: 8, accessLossCause: sample.cause), parent: nil, children: [])
    let row = try #require(tree.rows.first)
    #expect(row.accessibilityLabel() == "Trip")
    #expect(row.accessibilityValue() as? String == expected)
    #expect(row.accessibilityHelp() == expected)
    #expect(row.warningGlyph.accessibilityLabel() == String(localized: "Unavailable"))
    #expect(!row.disclosureGlyph.isAccessibilityElement())
    var selected: URL?
    tree.onSelectFolder = { selected = $0 }
    row.performClick(nil)
    #expect(selected == nil)
    tree.updateCount(10, for: folder)
    #expect(row.accessibilityLabel() == "Trip")
    #expect(row.countLabel.isHidden)
}

@Test @MainActor func t238LostUnreadSidebarRowKeepsLostAccessAccessibility() throws {
    let tree = GridSidebarTreeView(frame: NSRect(x: 0, y: 0, width: 196, height: 732))
    let folder = URL(fileURLWithPath: "/tmp/Trip")
    tree.showsDashForCurrent = true
    tree.show(current: .init(url: folder, count: 8, accessLossCause: .accessExpired), parent: nil, children: [])
    let row = try #require(tree.rows.first)
    let expected = "\(String(localized: "Unavailable")), \(String(localized: "Access Has Expired"))"
    #expect(row.countLabel.isHidden)
    #expect(row.accessibilityLabel() == "Trip")
    #expect(row.accessibilityValue() as? String == expected)
    #expect(row.accessibilityHelp() == expected)
}

@Test @MainActor func t232NoncurrentLostRowUsesMutedWarning() throws {
    let page = try PinnedDesign.page("permission-denied")
    let row = GridSidebarFolderButton(folder: .init(url: URL(fileURLWithPath: "/tmp/Trip"),
        accessLossCause: .unknown), depth: 0, current: false)
    try t232Color(row.warningGlyph.contentTintColor,
        equals: page.color(".sidebar .ds-nav-row.is-unavailable svg", "color", viewport: 1280))
}

@Test func t232SidebarUnavailableCatalogHasPinnedChineseAndEnglishCopy() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings["Unavailable"] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    for (language, expected) in [("en", "Unavailable"), ("zh-Hans", "无法访问")] {
        let translation = try #require(localizations[language] as? [String: Any])
        let unit = try #require(translation["stringUnit"] as? [String: Any])
        #expect(unit["value"] as? String == expected)
    }
}
