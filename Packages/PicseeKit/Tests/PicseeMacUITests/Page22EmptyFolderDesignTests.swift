import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

/// empty-folder.html (light, main / ?case=no-subfolders / ?drag=over) with grid-dark.html `:root` tokens for dark,
/// at the manifest viewport 1280×800 (main 1084 beside the 196 sidebar) and a compact 800×680.
private let page22Sizes = [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)]
private let page22Appearances: [(NSAppearance.Name, Bool)] = [(.aqua, false), (.darkAqua, true)]
private let page22Folder = URL(fileURLWithPath: "/design/待整理")

@MainActor private func page22Shell(_ size: NSSize, _ appearance: NSAppearance.Name, children: [String],
                                    recents: [RecentFolder] = []) throws -> GridShellView {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height - 28),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    shell.appearance = try #require(NSAppearance(named: appearance))
    shell.showFolderTree(current: GridSidebarFolder(url: page22Folder), parent: nil,
        children: children.map { GridSidebarFolder(url: page22Folder.appendingPathComponent($0)) })
    shell.setEmptyFolderState(true, recents: recents, now: page22Now)
    shell.layoutSubtreeIfNeeded()
    shell.emptyFolderView.layoutSubtreeIfNeeded()
    return shell
}

private func page22Recents() -> [RecentFolder] {
    [("日本 · 山海之间", 1), ("2024 家庭", 3), ("壁纸", 8)].map { name, days in
        RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/\(name)"), displayName: name,
            openedAt: page22Now.addingTimeInterval(-Double(days) * 86_400))
    }
}

@MainActor private func rect(_ view: NSView, in page: NSView) -> NSRect { page.convert(view.bounds, from: view) }

@MainActor private func resolved(_ color: NSColor?, _ appearance: NSAppearance) -> NSColor? {
    var result: NSColor?
    appearance.performAsCurrentDrawingAppearance { result = color?.usingColorSpace(.sRGB) }
    return result
}

@MainActor private func expectColor(_ actual: NSColor?, _ expected: PinnedDesign.Color, _ label: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
    guard let color = actual?.usingColorSpace(.sRGB) else {
        Issue.record("\(label): no colour", sourceLocation: sourceLocation); return
    }
    let differences = [Double(color.redComponent) - expected.red, Double(color.greenComponent) - expected.green,
                       Double(color.blueComponent) - expected.blue, Double(color.alphaComponent) - expected.alpha]
    #expect(differences.allSatisfy { abs($0) < 0.01 }, "\(label): expected \(expected), actual \(color)",
            sourceLocation: sourceLocation)
}

private func cgColor(_ value: CGColor?) -> NSColor? { value.flatMap(NSColor.init(cgColor:)) }

@MainActor private func firstAttribute(_ field: NSTextField, _ key: NSAttributedString.Key) -> Any? {
    let text = field.attributedStringValue
    return text.length == 0 ? nil : text.attribute(key, at: 0, effectiveRange: nil)
}

private func firstLength(_ design: PinnedDesign, _ selector: String, _ property: String, _ width: Double) throws -> Double {
    let raw = try design.raw(selector, property, viewport: width)
    return try design.lengthValue(String(raw.split(separator: " ")[0]), viewport: width)
}

private func weight(_ css: String) -> NSFont.Weight {
    switch css { case "500": .medium; case "600": .semibold; default: .regular }
}

/// The design colour: the light page's own selector, or the dark page's `:root` token.
private func designColor(_ light: PinnedDesign, _ dark: PinnedDesign, darkMode: Bool, _ selector: String,
                         _ property: String, token: String, _ width: Double) throws -> PinnedDesign.Color {
    darkMode ? try dark.color(":root", token, viewport: width) : try light.color(selector, property, viewport: width)
}

@Test @MainActor func page22TypographyAndSpacingFollowPinnedCSS() throws {
    let light = try PinnedDesign.page("empty-folder"), dark = try PinnedDesign.page("grid-dark")
    for (name, darkMode) in page22Appearances {
        for size in page22Sizes {
            let width = Double(size.width)
            for children in [["2024 冲绳", "手机备份", "扫描件"], []] {
                let shell = try page22Shell(size, name, children: children, recents: page22Recents())
                let page = shell.emptyFolderView, appearance = page.effectiveAppearance
                let label = "\(name.rawValue) \(Int(size.width)) \(children.isEmpty ? "recents" : "subfolders")"
                let icon = rect(page.icon, in: page), heading = rect(page.heading, in: page)
                let detail = rect(page.detail, in: page)
                let h2 = try light.font(".empty-state h2", viewport: width)
                #expect(page.heading.font == NSFont.systemFont(ofSize: h2.size, weight: weight("\(h2.weight)")), "\(label): h2 font")
                #expect(icon.width == 32 && icon.height == 32, "\(label): 32pt folder icon (svg width/height)")
                #expect(abs(icon.minY - heading.maxY - (try light.length(".empty-state h2", "margin-top", viewport: width))) < 0.5,
                        "\(label): h2 margin-top")
                #expect(page.detail.font?.pointSize == CGFloat(try light.length(".empty-state p", "font-size", viewport: width)))
                let lineHeight = try light.lineHeight(".empty-state p", viewport: width)
                let paragraph = firstAttribute(page.detail, .paragraphStyle) as? NSParagraphStyle
                #expect(abs(Double(paragraph?.minimumLineHeight ?? 0) - lineHeight) < 0.01, "\(label): p line-height")
                #expect(abs(heading.minY - detail.maxY - (try light.length(".empty-state p", "margin-top", viewport: width))) < 0.5,
                        "\(label): p margin-top")
                let padding = try light.edges(".empty-state", "padding", viewport: width)
                let maxWidth = try light.length(".recovery-state p", "max-width", viewport: width)
                let available = Double(page.bounds.width) - padding.left - padding.right
                #expect(abs(Double(detail.width) - min(maxWidth, available)) < 0.5, "\(label): p max-width")
                try #require(children.isEmpty || page.tiles.count == 3, "\(label): three tiles")
                let middle = children.isEmpty ? rect(page.recentsGroup, in: page) : rect(page.tiles[2], in: page)
                let actions = rect(page.chooseButton, in: page)
                #expect(abs(middle.minY - actions.maxY - (try light.length(".mock-actions", "margin-top", viewport: width))) < 0.5,
                        "\(label): actions margin-top")
                if !children.isEmpty {
                    let primary = rect(page.primaryButton, in: page)
                    #expect(abs(actions.minX - primary.maxX - (try light.length(".mock-actions", "gap", viewport: width))) < 0.5,
                            "\(label): actions gap")
                    #expect(abs((primary.minX + actions.maxX) / 2 - page.bounds.midX) < 0.5, "\(label): actions centred")
                } else {
                    #expect(abs(actions.midX - page.bounds.midX) < 0.5, "\(label): action centred")
                }
                let bottom = try light.length(".recovery-state", "padding-bottom", viewport: width)
                let outerTop = try light.length(".layout-exploration.is-grid .grid-scroll", "padding-top", viewport: width)
                let outerBottom = try light.length(".grid-scroll", "padding-bottom", viewport: width)
                    - light.length(".grid-bottom-bar", "height", viewport: width)
                let expectedMid = outerBottom + bottom
                    + (Double(page.bounds.height) - outerTop - outerBottom - padding.top - bottom) / 2
                #expect(abs(Double(icon.maxY + actions.minY) / 2 - expectedMid) < 0.5, "\(label): group centred")
                #expect(abs(icon.midX - page.bounds.midX) < 0.5 && abs(detail.midX - page.bounds.midX) < 0.5,
                        "\(label): horizontally centred")
                expectColor(resolved(page.heading.textColor, appearance), try designColor(light, dark, darkMode: darkMode,
                    ".empty-state h2", "color", token: "--color-text", width), "\(label): h2 colour")
                expectColor(resolved(firstAttribute(page.detail, .foregroundColor) as? NSColor, appearance), try designColor(light, dark, darkMode: darkMode, ".empty-state", "color",
                    token: "--color-muted", width), "\(label): p colour")
                expectColor(resolved(page.icon.contentTintColor, appearance), try designColor(light, dark,
                    darkMode: darkMode, ".recovery-state>svg", "color", token: "--color-muted", width), "\(label): icon")
            }
        }
    }
}

@Test @MainActor func page22SubfolderTilesFollowPinnedCSS() throws {
    let light = try PinnedDesign.page("empty-folder"), dark = try PinnedDesign.page("grid-dark")
    for (name, darkMode) in page22Appearances {
        for size in page22Sizes {
            let width = Double(size.width), label = "\(name.rawValue) \(Int(size.width))"
            let shell = try page22Shell(size, name, children: ["2024 冲绳", "手机备份", "扫描件", "旧照片"])
            let page = shell.emptyFolderView, appearance = page.effectiveAppearance
            let columns = try light.raw(".subfolder-tiles", "grid-template-columns", viewport: width)
            let match = try #require(columns.firstMatch(of: /repeat\((\d+),\s*(\d+)px\)/), "\(label): columns")
            let columnCount = Int(match.1)!, column = Double(match.2)!
            let gap = try light.length(".subfolder-tiles", "gap", viewport: width)
            let tiles = page.tiles.map { rect($0, in: page) }
            try #require(tiles.count == 4, "\(label): four tiles")
            for index in 0..<columnCount {
                #expect(abs(Double(tiles[index].width) - column) < 0.5, "\(label): tile width")
                #expect(abs(Double(tiles[index].minX - tiles[0].minX) - Double(index) * (column + gap)) < 0.5, "\(label): column \(index)")
            }
            #expect(abs(Double(tiles[0].minY - tiles[3].maxY) - gap) < 0.5, "\(label): row gap")
            let gridWidth = Double(columnCount) * column + Double(columnCount - 1) * gap
            #expect(abs(Double(tiles[0].minX) + gridWidth / 2 - Double(page.bounds.midX)) < 0.5, "\(label): grid centred")
            #expect(abs(Double(rect(page.detail, in: page).minY - tiles[0].maxY)
                - (try light.length(".subfolder-tiles", "margin-top", viewport: width))) < 0.5, "\(label): margin-top")
            let padding = try light.edges(".subfolder-tile", "padding", viewport: width)
            let innerGap = try light.length(".subfolder-tile", "gap", viewport: width)
            let tileBorder = try firstLength(light, ".subfolder-tile", "border", width)
            let tile = page.tiles[0]
            let icon = rect(tile.icon, in: tile), nameFrame = rect(tile.nameLabel, in: tile), meta = rect(tile.metaLabel, in: tile)
            let box = tile.bounds
            #expect(abs(Double(box.maxY - icon.maxY) - padding.top - tileBorder) < 0.5, "\(label): padding-top")
            #expect(abs(Double(icon.minX - box.minX) - padding.left - tileBorder) < 0.5 && abs(Double(nameFrame.minX) - padding.left - tileBorder) < 0.5,
                    "\(label): padding-left")
            #expect(abs(Double(meta.minY - box.minY) - padding.bottom - tileBorder) < 0.5, "\(label): padding-bottom")
            #expect(abs(Double(box.maxX - nameFrame.maxX) - padding.right - tileBorder) < 0.5, "\(label): padding-right")
            #expect(abs(Double(icon.minY - nameFrame.maxY) - innerGap) < 0.5 && abs(Double(nameFrame.minY - meta.maxY) - innerGap) < 0.5,
                    "\(label): tile gap")
            let layer = try #require(tile.layer)
            #expect(abs(Double(layer.borderWidth) - (try firstLength(light, ".subfolder-tile", "border", width))) < 0.01)
            #expect(abs(Double(layer.cornerRadius) - (try light.length(".subfolder-tile", "border-radius", viewport: width))) < 0.01)
            expectColor(cgColor(layer.borderColor), try designColor(light, dark, darkMode: darkMode, ".subfolder-tile", "border",
                token: "--color-border", width), "\(label): tile border")
            expectColor(cgColor(layer.backgroundColor), try designColor(light, dark, darkMode: darkMode, ".subfolder-tile",
                "background", token: "--color-bg", width), "\(label): tile background")
            let tileFont = try firstLength(light, ".subfolder-tile", "font", width)
            #expect(tile.nameLabel.font == NSFont.systemFont(ofSize: tileFont,
                weight: weight(try light.raw(".subfolder-tile .tile-name", "font-weight", viewport: width))), "\(label): name font")
            #expect(try light.raw(".subfolder-tile .tile-name", "text-overflow", viewport: width) == "ellipsis")
            #expect(tile.nameLabel.lineBreakMode == .byTruncatingTail && tile.nameLabel.maximumNumberOfLines == 1)
            #expect(tile.metaLabel.font?.pointSize == CGFloat(try light.length(".subfolder-tile .tile-meta", "font-size", viewport: width)))
            expectColor(resolved(tile.nameLabel.textColor, appearance), try designColor(light, dark, darkMode: darkMode,
                ".subfolder-tile", "color", token: "--color-text", width), "\(label): name colour")
            expectColor(resolved(tile.metaLabel.textColor, appearance), try designColor(light, dark, darkMode: darkMode,
                ".subfolder-tile .tile-meta", "color", token: "--color-muted", width), "\(label): meta colour")
            expectColor(resolved(tile.icon.contentTintColor, appearance), try designColor(light, dark, darkMode: darkMode,
                ".subfolder-tile svg", "color", token: "--color-accent", width), "\(label): tile icon")
        }
    }
}

@Test @MainActor func page22RecentsAndButtonsFollowPinnedCSS() throws {
    let light = try PinnedDesign.page("empty-folder"), dark = try PinnedDesign.page("grid-dark")
    for (name, darkMode) in page22Appearances {
        for size in page22Sizes {
            let width = Double(size.width), label = "\(name.rawValue) \(Int(size.width))"
            func color(_ selector: String, _ property: String, _ token: String) throws -> PinnedDesign.Color {
                try designColor(light, dark, darkMode: darkMode, selector, property, token: token, width)
            }
            let shell = try page22Shell(size, name, children: [], recents: page22Recents())
            let page = shell.emptyFolderView, appearance = page.effectiveAppearance
            let group = rect(page.recentsGroup, in: page)
            #expect(abs(Double(group.width) - (try light.length(".recent-folders", "width", viewport: width))) < 0.5)
            #expect(abs(Double(rect(page.detail, in: page).minY - group.maxY)
                - (try light.length(".recent-folders", "margin-top", viewport: width))) < 0.5, "\(label): margin-top")
            let groupLayer = try #require(page.recentsGroup.layer)
            #expect(abs(Double(groupLayer.cornerRadius) - (try light.length(".recent-folders", "border-radius", viewport: width))) < 0.01)
            #expect(abs(Double(groupLayer.borderWidth) - (try firstLength(light, ".recent-folders", "border", width))) < 0.01)
            expectColor(cgColor(groupLayer.borderColor), try color(".recent-folders", "border", "--color-border"), "\(label): group border")
            let box = page.recentsHeadingBox, headingLabel = page.recentsHeading
            let headingPadding = try light.edges(".recent-heading", "padding", viewport: width)
            let text = rect(headingLabel, in: box), rule = rect(page.recentsHeadingRule, in: box)
            #expect(abs(Double(text.minX) - headingPadding.left) < 0.5 && abs(Double(box.bounds.maxY - text.maxY) - headingPadding.top) < 0.5,
                    "\(label): heading padding")
            #expect(abs(Double(text.minY - rule.maxY) - headingPadding.bottom) < 0.5, "\(label): heading padding-bottom")
            #expect(abs(Double(rule.height) - (try firstLength(light, ".recent-heading", "border-bottom", width))) < 0.01)
            expectColor(cgColor(page.recentsHeadingRule.layer?.backgroundColor), try color(".recent-heading", "border-bottom",
                "--color-border"), "\(label): heading rule")
            expectColor(cgColor(box.layer?.backgroundColor), try color(".recent-heading", "background", "--color-surface"),
                "\(label): heading background")
            expectColor(resolved(headingLabel.textColor, appearance), try color(".recent-heading", "color", "--color-muted"),
                "\(label): heading colour")
            #expect(headingLabel.font?.pointSize == CGFloat(try light.length(".recent-heading", "font-size", viewport: width)))
            let rowPadding = try light.edges(".recent-folder", "padding", viewport: width)
            let rowGap = try light.length(".recent-folder", "gap", viewport: width)
            for (index, row) in page.recentRows.enumerated() {
                let icon = rect(row.icon, in: row), nameFrame = rect(row.nameLabel, in: row), when = rect(row.whenLabel, in: row)
                #expect(abs(Double(icon.minX) - rowPadding.left) < 0.5 && abs(Double(row.bounds.maxX - when.maxX) - rowPadding.right) < 0.5,
                        "\(label): row \(index) padding")
                let borderTop = row.separator.isHidden ? 0 : row.separator.frame.height
                #expect(abs(Double(row.bounds.maxY - borderTop - nameFrame.maxY) - rowPadding.top) < 0.5
                    && abs(Double(nameFrame.minY) - rowPadding.bottom) < 0.5, "\(label): row \(index) vertical padding")
                #expect(abs(Double(nameFrame.minX - icon.maxX) - rowGap) < 0.5 && abs(Double(when.minX - nameFrame.maxX) - rowGap) < 0.5,
                        "\(label): row \(index) gap")
                #expect(row.separator.isHidden == (index == 0), "\(label): row \(index) separator")
                #expect(row.whenLabel.font?.pointSize == CGFloat(try light.length(".recent-when", "font-size", viewport: width)))
                expectColor(resolved(row.whenLabel.textColor, appearance), try color(".recent-when", "color", "--color-muted"),
                    "\(label): when colour")
                expectColor(resolved(row.icon.contentTintColor, appearance), try color(".recent-folder svg", "color", "--color-muted"),
                    "\(label): row icon")
                expectColor(cgColor(row.layer?.backgroundColor), try color(".recent-folder", "background", "--color-bg"),
                    "\(label): row background")
                if index > 0 {
                    #expect(abs(Double(row.separator.frame.height) - (try firstLength(light, ".recent-folder+.recent-folder",
                        "border-top", width))) < 0.01)
                    expectColor(cgColor(row.separator.layer?.backgroundColor), try color(".recent-folder+.recent-folder",
                        "border-top", "--color-border-subtle"), "\(label): separator")
                }
            }
            let secondary = page.chooseButton
            #expect(secondary.style == .secondary)
            let secondaryPadding = try light.edges(".secondary-button", "padding", viewport: width)
            #expect(Double(secondary.padding.left) == secondaryPadding.left && Double(secondary.padding.top) == secondaryPadding.top)
            #expect(abs(Double(secondary.frame.width - secondary.titleWidth) - secondaryPadding.left - secondaryPadding.right
                - 2 * (try firstLength(light, ".secondary-button", "border", width))) < 0.5, "\(label): secondary width")
            let secondaryLayer = try #require(secondary.layer)
            #expect(abs(Double(secondaryLayer.borderWidth) - (try firstLength(light, ".secondary-button", "border", width))) < 0.01)
            #expect(abs(Double(secondaryLayer.cornerRadius) - (try light.length(".secondary-button", "border-radius", viewport: width))) < 0.01)
            expectColor(cgColor(secondaryLayer.borderColor), try color(".secondary-button", "border", "--color-border"), "\(label): secondary border")
            expectColor(cgColor(secondaryLayer.backgroundColor), try color(".secondary-button", "background", "--color-bg"), "\(label): secondary fill")
            expectColor(resolved(secondary.titleColor, appearance), try color(".secondary-button", "color", "--color-text"), "\(label): secondary text")

            let subfolders = try page22Shell(size, name, children: ["a", "b"]).emptyFolderView
            let primary = subfolders.primaryButton, textButton = subfolders.chooseButton
            #expect(primary.style == .primary && textButton.style == .text)
            let primaryPadding = try light.edges(".mock-primary", "padding", viewport: width)
            #expect(Double(primary.padding.left) == primaryPadding.left && Double(primary.padding.top) == primaryPadding.top)
            #expect(abs(Double(primary.frame.width - primary.titleWidth) - primaryPadding.left - primaryPadding.right) < 0.5)
            let primaryLayer = try #require(primary.layer)
            #expect(abs(Double(primaryLayer.cornerRadius) - (try light.length(".mock-primary", "border-radius", viewport: width))) < 0.01)
            expectColor(cgColor(primaryLayer.backgroundColor), try color(".mock-primary", "background", "--color-accent-fill"), "\(label): primary fill")
            expectColor(resolved(primary.titleColor, subfolders.effectiveAppearance), try color(".mock-primary", "color", "--color-on-accent"),
                "\(label): primary text")
            #expect(primary.titleFont.pointSize == CGFloat(try firstLength(light, ".mock-primary", "font", width)))
            let textPadding = try light.edges(".mock-actions .text-button", "padding", viewport: width)
            #expect(Double(textButton.padding.left) == textPadding.left && Double(textButton.padding.top) == textPadding.top)
            #expect(abs(Double(textButton.frame.width - textButton.titleWidth) - textPadding.left - textPadding.right) < 0.5)
            expectColor(resolved(textButton.titleColor, subfolders.effectiveAppearance), try color(".text-button", "color",
                "--color-accent-text"), "\(label): text button")
        }
    }
}

@Test @MainActor func page22DropOutlineFollowsPinnedCSS() throws {
    let light = try PinnedDesign.page("empty-folder"), dark = try PinnedDesign.page("grid-dark")
    for (name, darkMode) in page22Appearances {
        for size in page22Sizes {
            let width = Double(size.width), label = "\(name.rawValue) \(Int(size.width))"
            let page = try page22Shell(size, name, children: []).emptyFolderView
            let board = NSPasteboard.withUniqueName()
            defer { board.releaseGlobally() }
            #expect(board.writeObjects([URL(fileURLWithPath: "/photos/Trip", isDirectory: true) as NSURL]))
            #expect(page.draggingEntered(Page22DesignDropInfo(board)) == .copy)
            let inset = try light.lengthValue(light.raw(".drop-outline", "inset", viewport: width), viewport: width)
            #expect(page.dropOutline.frame == page.bounds.insetBy(dx: inset, dy: inset), "\(label): inset")
            let layer = try #require(page.dropOutline.layer)
            #expect(abs(Double(layer.cornerRadius) - (try light.length(".drop-outline", "border-radius", viewport: width))) < 0.01)
            #expect(abs(Double(page.dropBorder.lineWidth) - (try firstLength(light, ".drop-outline", "border", width))) < 0.01)
            #expect(try light.raw(".drop-outline", "border", viewport: width).contains("dashed"))
            #expect(page.dropBorder.lineDashPattern?.isEmpty == false, "\(label): dashed")
            expectColor(cgColor(page.dropBorder.strokeColor), try designColor(light, dark, darkMode: darkMode,
                ".is-drag-over .drop-outline", "border-color", token: "--color-accent", width), "\(label): outline colour")
            expectColor(cgColor(layer.backgroundColor), try designColor(light, dark, darkMode: darkMode,
                ".is-drag-over .drop-outline", "background", token: "--color-accent-soft", width), "\(label): outline fill")
            page.draggingExited(nil)
            #expect(page.dropOutline.isHidden)
        }
    }
}

@MainActor private final class Page22DesignDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
    func resetSpringLoading() { }
}

@Test @MainActor func page22LongestStringsFitInBothLanguages() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let strings = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
    func value(_ key: String, _ language: String, form: String? = nil) throws -> String {
        let localized = try #require(((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?[language]
            as? [String: Any], "\(key) \(language)")
        let unit = form.map { ((localized["variations"] as? [String: Any])?["plural"] as? [String: Any])?[$0] as? [String: Any] }
            ?? localized
        return try #require((unit?["stringUnit"] as? [String: Any])?["value"] as? String, "\(key) \(language)")
    }
    let headingKey = "This level has no images, but has %lld subfolders"
    let detailKeys = ["Open a subfolder, show the images in subfolders too, or drop another folder here.",
                      "Choose another folder to continue, or drop a folder here."]
    let languages: [(String, String)] = [
        (try value(headingKey, "en", form: "other"), try detailKeys.map { try value($0, "en") }.max { $0.count < $1.count }!),
        (try value(headingKey, "zh-Hans"), try detailKeys.map { try value($0, "zh-Hans") }.max { $0.count < $1.count }!),
    ]
    let long = String(repeating: "长名字Long", count: 20)
    #expect(long.count == 140)
    let longRecent = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/long"), displayName: long,
        openedAt: page22Now.addingTimeInterval(-3 * 86_400))
    for size in page22Sizes {
        for (heading, detail) in languages {
            for children in [[long, "b"], []] {
                let shell = try page22Shell(size, .aqua, children: children, recents: [longRecent])
                let page = shell.emptyFolderView
                let label = "\(Int(size.width)) \(heading.prefix(8)) \(children.isEmpty ? "recents" : "subfolders")"
                page.heading.stringValue = heading.replacingOccurrences(of: "%lld", with: "1000")
                page.setDetailText(detail)
                page.needsLayout = true
                page.layoutSubtreeIfNeeded()
                for field in [page.heading, page.detail] {
                    let frame = field.frame
                    let needed = field.attributedStringValue.boundingRect(with: NSSize(width: frame.width, height: .greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                    #expect(frame.width <= 460.5, "\(label): width")
                    #expect(frame.height >= ceil(needed), "\(label): \(field.stringValue.prefix(10)) not clipped")
                }
                if let tile = page.tiles.first {
                    #expect(tile.nameLabel.lineBreakMode == .byTruncatingTail)
                    #expect(tile.bounds.contains(tile.nameLabel.frame), "\(label): name inside the tile")
                }
                if let row = page.recentRows.first {
                    #expect(row.nameLabel.lineBreakMode == .byTruncatingTail)
                    #expect(row.bounds.contains(row.nameLabel.frame) && row.bounds.contains(row.whenLabel.frame), "\(label): inside the row")
                    #expect(row.whenLabel.frame.width >= row.whenLabel.intrinsicContentSize.width, "\(label): time not truncated")
                }
            }
        }
    }
}

/// Viewer rows (owner decision C, #137): the viewer surface reuses page 22, so at the same content size and appearance
/// its layout and colours equal the grid page pinned above to empty-folder.html (light) and grid-dark.html (dark).
@Test @MainActor func viewerPage22MatchesThePinnedGridPage() throws {
    for (name, _) in page22Appearances {
        for children in [["2024 冲绳", "手机备份", "扫描件"], []] {
            let shell = try page22Shell(page22Sizes[0], name, children: children, recents: page22Recents())
            let grid = shell.emptyFolderView
            // Compare equal stack viewports: Grid pads its full drop frame internally,
            // while the viewer intentionally supplies no outer scroll padding.
            let top = try PinnedDesign.page("empty-folder").length(".layout-exploration.is-grid .grid-scroll", "padding-top", viewport: page22Sizes[0].width)
            let bottom = try PinnedDesign.page("empty-folder").length(".grid-scroll", "padding-bottom", viewport: page22Sizes[0].width)
                - PinnedDesign.page("empty-folder").length(".grid-bottom-bar", "height", viewport: page22Sizes[0].width)
            let host = ViewerStateHost(frame: NSRect(x: 0, y: 0, width: grid.bounds.width,
                                                    height: grid.bounds.height - top - bottom))
            host.appearance = try #require(NSAppearance(named: name))
            shell.mirrorEmptyFolderPage(to: host)
            host.display(.emptyFolder)
            let viewer = host.emptyFolderView
            viewer.layoutSubtreeIfNeeded()
            let label = "\(name.rawValue) \(children.isEmpty ? "recents" : "subfolders")"
            #expect(viewer.frame.size == host.bounds.size, "\(label): size")
            #expect(viewer.tiles.count == grid.tiles.count && viewer.recentRows.count == grid.recentRows.count, "\(label)")
            #expect(viewer.heading.stringValue == grid.heading.stringValue, "\(label): heading")
            #expect(viewer.detail.stringValue == grid.detail.stringValue, "\(label): detail")
            let fixed: [(NSView, NSView)] = [(grid.icon, viewer.icon), (grid.heading, viewer.heading),
                (grid.detail, viewer.detail), (grid.primaryButton, viewer.primaryButton),
                (grid.chooseButton, viewer.chooseButton), (grid.recentsGroup, viewer.recentsGroup)]
            let pairs = fixed + zip(grid.tiles, viewer.tiles).map { ($0 as NSView, $1 as NSView) }
                + zip(grid.recentRows, viewer.recentRows).map { ($0 as NSView, $1 as NSView) }
            for (index, (expected, actual)) in pairs.enumerated() {
                let item = "\(label) #\(index) \(type(of: expected))"
                if !expected.isHidden {
                    #expect(rect(actual, in: viewer) == rect(expected, in: grid).offsetBy(dx: 0, dy: -bottom), "\(item): frame")
                }
                #expect(actual.isHidden == expected.isHidden, "\(item): hidden")
                #expect(cgColor(actual.layer?.backgroundColor)?.usingColorSpace(.sRGB)
                    == cgColor(expected.layer?.backgroundColor)?.usingColorSpace(.sRGB), "\(item): fill")
                #expect(cgColor(actual.layer?.borderColor)?.usingColorSpace(.sRGB)
                    == cgColor(expected.layer?.borderColor)?.usingColorSpace(.sRGB), "\(item): border")
            }
        }
    }
}
