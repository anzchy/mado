import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
@testable import PicseeMacUI

private func expectPinnedColor(_ actual: NSColor?, _ expected: PinnedDesign.Color) throws {
    let color = try #require(actual?.usingColorSpace(.sRGB))
    #expect(abs(Double(color.redComponent) - expected.red) < 0.01)
    #expect(abs(Double(color.greenComponent) - expected.green) < 0.01)
    #expect(abs(Double(color.blueComponent) - expected.blue) < 0.01)
    #expect(abs(Double(color.alphaComponent) - expected.alpha) < 0.01)
}

/// search-empty.html `.empty-state`, `h2`, `p`, `.mock-actions`, `.mock-primary`;
/// `.grid-bottom-bar` and `.grid-file-status`. grid-dark.html supplies dark tokens.
@Test @MainActor func page23GeometryTypographyAndResolvedColorsFollowPinnedCSS() throws {
    _ = NSApplication.shared
    let light = try PinnedDesign.page("search-empty")
    let dark = try PinnedDesign.page("grid-dark")
    for (appearanceName, darkMode) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)] {
            let design = darkMode ? dark : light
            let appearance = try #require(NSAppearance(named: appearanceName))
            let shell = GridShellView(frame: NSRect(origin: .zero, size: size),
                preferencesStore: InMemoryDisplayPreferencesStore())
            shell.appearance = appearance
            shell.reduceTransparencyOverride = false
            shell.layoutSubtreeIfNeeded()
            shell.showSearchEmpty(true, term: "missing")
            let title = try #require(shell.emptyStateTitle)
            let detail = try #require(shell.emptyStateDetail)
            let state = try #require(shell.mainContent.subviews.first { $0.accessibilityIdentifier() == "grid.search.empty" })
            let icon = try #require(state.subviews.compactMap { $0 as? NSImageView }.first)
            let clear = shell.clearSearchButton
            let width = Double(size.width)
            let titleGap = try light.length(".empty-state h2", "margin-top", viewport: width)
            let detailGap = try light.length(".empty-state p", "margin-top", viewport: width)
            let actionGap = try light.length(".mock-actions", "margin-top", viewport: width)
            let detailLineHeight = try light.lineHeight(".empty-state p", viewport: width)
            let detailFontSize = try light.length(".empty-state p", "font-size", viewport: width)
            let titleFont = try light.font(".empty-state h2", viewport: width)
            #expect(title.font == NSFont.systemFont(ofSize: titleFont.size, weight: .medium))
            #expect(titleFont.weight == 500)
            #expect(detail.font?.pointSize == CGFloat(detailFontSize))
            #expect(abs(Double(detail.frame.height) - detailLineHeight) < 0.01)
            let paragraph = detail.attributedStringValue.attribute(.paragraphStyle, at: 0,
                effectiveRange: nil) as? NSParagraphStyle
            #expect(abs(Double(paragraph?.minimumLineHeight ?? 0) - detailLineHeight) < 0.01)
            #expect(abs(Double(icon.frame.minY - title.frame.maxY) - titleGap) < 0.01)
            #expect(abs(Double(title.frame.minY - detail.frame.maxY) - detailGap) < 0.01)
            #expect(abs(Double(detail.frame.minY - clear.frame.maxY) - actionGap) < 0.01)
            let groupHeight = Double(icon.frame.height + title.frame.height + detail.frame.height + clear.frame.height)
                + titleGap + detailGap + actionGap
            let center = Double(shell.mainContent.bounds.midY)
            #expect(abs(Double(title.frame.maxY) - (center + groupHeight / 2 - Double(icon.frame.height) - titleGap)) < 0.01)
            #expect(abs(Double(detail.frame.maxY) - (center + groupHeight / 2 - Double(icon.frame.height + title.frame.height) - titleGap - detailGap)) < 0.01)
            #expect(abs(Double(clear.frame.minY) - (center - groupHeight / 2)) < 0.01)
            var resolved: [NSColor?] = []
            appearance.performAsCurrentDrawingAppearance {
                resolved = [title.textColor, detail.textColor, clear.bezelColor,
                    shell.searchStatus.textColor,
                    shell.footer.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))]
                    .map { $0?.usingColorSpace(.sRGB) }
            }
            try expectPinnedColor(resolved[0], darkMode
                ? dark.color(":root", "--color-text", viewport: width)
                : light.color(".empty-state h2", "color", viewport: width))
            try expectPinnedColor(resolved[1], darkMode
                ? dark.color(":root", "--color-muted", viewport: width)
                : light.color(".empty-state", "color", viewport: width))
            try expectPinnedColor(resolved[2], darkMode
                ? dark.color(":root", "--color-accent-fill", viewport: width)
                : light.color(".mock-primary", "background", viewport: width))
            try expectPinnedColor(resolved[3], design.color(".grid-file-status", "color", viewport: width))
            let barFill = try design.color(".grid-bottom-bar", "background", viewport: width)
            try expectPinnedColor(resolved[4], barFill)
        }
    }
}

@Test @MainActor func issue314BottomBarFillRuleAndLiveReduceTransparencyMatchPinnedPages() throws {
    _ = NSApplication.shared
    for (pageName, appearanceName) in [("grid-light", NSAppearance.Name.aqua), ("grid-dark", .darkAqua)] {
        let design = try PinnedDesign.page(pageName)
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
            preferencesStore: InMemoryDisplayPreferencesStore())
        shell.appearance = NSAppearance(named: appearanceName)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        defer { window.close() }

        shell.reduceTransparencyOverride = false
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        shell.layoutSubtreeIfNeeded()
        var fill: NSColor?
        shell.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = shell.footer.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        }
        try expectPinnedColor(fill, design.color(".grid-bottom-bar", "background", viewport: 800))
        #expect(!shell.footer.subviews.contains {
            $0.frame.width == shell.footer.bounds.width && $0.frame.height == 1
                && $0.frame.maxY == shell.footer.bounds.maxY
        }, "The Bottom Bar has no top rule")

        shell.reduceTransparencyOverride = true
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        shell.effectiveAppearance.performAsCurrentDrawingAppearance {
            fill = shell.footer.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        }
        try expectPinnedColor(fill, design.color(":root", "--color-bg", viewport: 800))
    }
}

@Test @MainActor func issue314OverrideRestylesFooterImmediately() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    func fillAlpha() throws -> CGFloat {
        try #require(shell.footer.layer?.backgroundColor?.alpha)
    }
    shell.reduceTransparencyOverride = true
    #expect(try fillAlpha() == 1)
    shell.reduceTransparencyOverride = false
    #expect(abs(try fillAlpha() - 0.8) < 0.001)
    shell.reduceTransparencyOverride = true
    #expect(try fillAlpha() == 1)
}

/// grid-light.html / grid-dark.html `.grid-bottom-bar` (40px, 12px inset;
/// 7px only at max-width:480px), `.grid-toolbar-tools` (6px gap;
/// 2px at max-width:800px), and primitives.css `.ds-icon-button` (30x28).
/// search-empty.html `.empty-state` and its h2/p/.mock-primary rules.
@Test @MainActor func pinnedSearchFooterFramesAndPage23AtBothSizesAndAppearances() throws {
    _ = NSApplication.shared
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let design = try PinnedDesign.page(appearance == .darkAqua ? "grid-dark" : "grid-light")
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 800, height: 680)] {
            let shell = GridShellView(frame: NSRect(origin: .zero, size: size),
                preferencesStore: InMemoryDisplayPreferencesStore())
            shell.appearance = NSAppearance(named: appearance)
            shell.reduceTransparencyOverride = false
            shell.layoutSubtreeIfNeeded()
            #expect(shell.footer.frame.height == 40)
            #expect(shell.sortButton.frame.size == NSSize(width: 30, height: 28))
            let toolGap: CGFloat = size.width <= 800 ? 2 : 6
            #expect(shell.sortButton.frame.maxX + 2 * (30 + toolGap) == size.width - 12)
            #expect(shell.searchButton.frame.size == NSSize(width: 30, height: 28))
            #expect(shell.searchButton.frame.maxX + toolGap == shell.sortButton.frame.minX)
            #expect(shell.searchField.isHidden)
            #expect(shell.searchStatus.font?.pointSize == 12)
            #expect(shell.searchStatus.textColor == DesignColor.textSecondary.nsColor)
            var footerFill: NSColor?
            shell.effectiveAppearance.performAsCurrentDrawingAppearance {
                footerFill = shell.footer.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
            }
            try expectPinnedColor(footerFill, design.color(".grid-bottom-bar", "background", viewport: Double(size.width)))
            #expect(shell.footer.frame.minX == 0)
            shell.focusSearch()
            shell.layoutSubtreeIfNeeded()
            #expect(!shell.searchField.isHidden)
            #expect(shell.searchButton.isHidden)
            #expect(shell.searchField.frame.height == 28)
            #expect(shell.searchField.frame.maxX + toolGap == shell.sortButton.frame.minX)
            #expect(shell.searchField.frame.minX > shell.toggleButton.frame.maxX)
            shell.setSearchTerm("旅行")
            shell.setSearchStatus(resultCount: 4, term: "旅行")
            #expect(shell.searchStatus.stringValue.contains("4"))
            #expect(shell.searchStatus.stringValue.contains("旅行"))
            #expect(!shell.searchStatus.isHidden)
            shell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                object: shell.searchField))
            #expect(shell.searchField.isHidden)
            #expect(!shell.searchButton.isHidden)
            #expect(shell.searchButton.state == .on)
            shell.focusSearch()
            shell.showSearchEmpty(true, term: String(repeating: "long-name-", count: 40))
            let title = try #require(shell.emptyStateTitle)
            let detail = try #require(shell.emptyStateDetail)
            let paragraph = detail.attributedStringValue.attribute(.paragraphStyle, at: 0,
                effectiveRange: nil) as? NSParagraphStyle
            #expect(paragraph?.lineBreakMode == .byTruncatingMiddle)
            let closing = String(localized: "No images with “%@” in their filename.")
                .components(separatedBy: "%@").last ?? ""
            #expect(detail.attributedStringValue.string.hasSuffix(closing))
            #expect(title.font?.pointSize == 16)
            #expect(detail.font?.pointSize == 13)
            #expect(title.frame.midX == shell.mainContent.bounds.midX)
            #expect(detail.frame.midX == shell.mainContent.bounds.midX)
            #expect(shell.clearSearchButton.frame.midX == shell.mainContent.bounds.midX)
            #expect(title.frame.minY > shell.mainContent.bounds.minY)
            #expect(shell.clearSearchButton.frame.maxY < shell.mainContent.bounds.maxY)
            #expect(detail.frame.minX >= shell.mainContent.bounds.minX)
            #expect(detail.frame.maxX <= shell.mainContent.bounds.maxX)
            #expect(shell.clearSearchButton.isBordered)
            #expect(shell.clearSearchButton.bezelColor != nil)
            #expect((title.frame.maxY + shell.clearSearchButton.frame.minY) / 2 - shell.mainContent.bounds.midY < 80)
        }
    }
}

/// grid-light.html `.grid-bottom-bar` switches to 7px only at
/// `@media (max-width:480px)`; its tools keep the `max-width:800px` 2px gap.
@Test @MainActor func pinnedFooterUsesNarrowMediaInsetAt480Points() {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 480, height: 680),
        preferencesStore: InMemoryDisplayPreferencesStore())
    shell.layoutSubtreeIfNeeded()
    #expect(shell.sortButton.frame.maxX + 2 * (26 + 2) == CGFloat(480 - 7))
    #expect(shell.searchButton.frame.maxX + 2 == shell.sortButton.frame.minX)
    shell.focusSearch()
    shell.layoutSubtreeIfNeeded()
    #expect(shell.searchField.frame.maxX + 2 == shell.sortButton.frame.minX)
}

@Test @MainActor func issue215SearchFieldKeepsReadableFloorAtNarrowWidths() {
    _ = NSApplication.shared
    for width in [238.0, 480.0] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 680),
                                  preferencesStore: InMemoryDisplayPreferencesStore())
        shell.layoutSubtreeIfNeeded()
        #expect(shell.searchField.frame.width >= 120, "idle field at \(width)pt: \(shell.searchField.frame)")
        #expect(shell.searchField.frame.minX >= shell.toggleButton.frame.maxX)

        shell.focusSearch()
        shell.layoutSubtreeIfNeeded()
        #expect(shell.searchField.frame.width >= 120, "editing field at \(width)pt: \(shell.searchField.frame)")
        #expect(shell.searchField.frame.minX >= shell.toggleButton.frame.maxX)
        shell.setSearchStatus(resultCount: 4, term: "旅行")
        shell.layoutSubtreeIfNeeded()
        #expect(shell.searchStatus.isHidden)
    }
}

@Test @MainActor func issue136Combo2FooterTabTargetsFollowVisibleKeyLoop() {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 765, height: 600),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let anchor = NSView()
    shell.linkKeyViews(from: anchor)
    #expect(shell.searchField.isHidden)
    #expect(shell.firstFooterKeyView === shell.toggleButton)
    // #114: the implemented Display button follows Sort in the footer loop (never a dead control).
    #expect(shell.lastFooterKeyView === shell.displayButton)
    #expect(shell.adjacentFooterKeyView(to: shell.toggleButton, reverse: true) == nil)
    #expect(shell.adjacentFooterKeyView(to: shell.toggleButton, reverse: false) === shell.toggleButton.nextKeyView)
    #expect(shell.adjacentFooterKeyView(to: shell.searchButton, reverse: false) === shell.sortButton)
    #expect(shell.adjacentFooterKeyView(to: shell.sortButton, reverse: false) === shell.displayButton)
    #expect(shell.adjacentFooterKeyView(to: shell.displayButton, reverse: false) == nil)
    #expect(shell.searchField.isHidden)
    shell.focusSearch()
    #expect(shell.firstFooterKeyView === shell.toggleButton)
    #expect(shell.lastFooterKeyView === shell.displayButton)
    #expect(shell.adjacentFooterKeyView(to: shell.searchField, reverse: false) === shell.sortButton)
    #expect(shell.adjacentFooterKeyView(to: shell.searchField, reverse: true) === shell.toggleButton.nextKeyView)
    shell.showSearchEmpty(true, term: "unmatched")
    #expect(shell.lastFooterKeyView === shell.clearSearchButton)
    #expect(shell.adjacentFooterKeyView(to: shell.sortButton, reverse: false) === shell.displayButton)
    #expect(shell.adjacentFooterKeyView(to: shell.displayButton, reverse: false) === shell.clearSearchButton)
    #expect(shell.adjacentFooterKeyView(to: shell.clearSearchButton, reverse: true) === shell.displayButton)
    #expect(shell.adjacentFooterKeyView(to: anchor, reverse: false) == nil)
}

@Test @MainActor func issue136TiledGridFooterUsesPinnedSearchAndSortFrames() throws {
    _ = NSApplication.shared
    for shellWidth in [765.0, 1060.0] {
        let design = try PinnedDesign.page("grid-light")
        let gap = try design.length(".grid-toolbar-tools", "gap", viewport: shellWidth)
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: shellWidth, height: 600),
            preferencesStore: InMemoryDisplayPreferencesStore())
        shell.layoutSubtreeIfNeeded()
        #expect(abs(shell.footer.frame.width - shellWidth) < 0.01)
        #expect(abs(shell.sortButton.frame.maxX + 2 * (30 + gap) - (shellWidth - 12)) < 0.01)
        #expect(abs(Double(shell.searchButton.frame.maxX - shell.sortButton.frame.minX) + gap) < 0.01)
        shell.focusSearch()
        shell.layoutSubtreeIfNeeded()
        #expect(abs(Double(shell.searchField.frame.maxX - shell.sortButton.frame.minX) + gap) < 0.01)
        #expect(shell.searchField.frame.minX > shell.toggleButton.frame.maxX)
    }
}

@Test @MainActor func gridFooterSearchSortAndEmptyStateFitCompactViewport() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [], backing: .buffered, defer: false)
    window.contentView!.addSubview(shell)
    shell.layoutSubtreeIfNeeded()
    #expect(shell.toggleButton.frame.maxX < shell.searchField.frame.minX)
    #expect(shell.searchField.frame.maxX < shell.sortButton.frame.minX)
    #expect(shell.sortButton.frame.maxX <= shell.footer.bounds.maxX)
    #expect(shell.searchField.accessibilityLabel() == "Search current folder")
    #expect(shell.sortButton.accessibilityLabel() == "Sort images")
    shell.focusSearch()
    #expect(window.firstResponder === shell.searchField || window.firstResponder is NSTextView)
    var observedTerm = ""
    shell.onSearchChange = { observedTerm = $0 }
    shell.setSearchTerm("café")
    shell.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: shell.searchField))
    #expect(observedTerm == "café")
    let anchor = NSView()
    shell.linkKeyViews(from: anchor)
    #expect(shell.searchField.nextKeyView === shell.sortButton)
    // #114: Sort → Display → (Clear Search) → anchor; the Display button is never a dead control.
    #expect(shell.sortButton.nextKeyView === shell.displayButton)
    #expect(shell.displayButton.nextKeyView === anchor)
    shell.showSearchEmpty(true, term: "旅行")
    #expect(shell.searchEmptyVisible)
    #expect(shell.sortButton.nextKeyView === shell.displayButton)
    #expect(shell.displayButton.nextKeyView === shell.clearSearchButton)
    #expect(shell.clearSearchButton.canBecomeKeyView)
    let empty = try #require(shell.mainContent.subviews.first { $0.accessibilityIdentifier() == "grid.search.empty" })
    #expect(empty.frame == shell.mainContent.bounds)
    #expect(empty.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("旅行") })
    #expect(shell.clearSearchButton.frame.midX == shell.mainContent.bounds.midX)
    var cleared = false
    shell.onClearSearch = { cleared = true }
    shell.clearSearchButton.performClick(nil)
    #expect(cleared)
    cleared = false
    shell.setSearchTerm("unmatched")
    #expect(shell.control(shell.searchField, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    #expect(cleared)
    #expect(shell.searchField.stringValue.isEmpty)
    shell.showSearchEmpty(false)
    #expect(shell.displayButton.nextKeyView === anchor)
    shell.setFooterActionsEnabled(false)
    #expect(!shell.searchField.isEnabled)
    #expect(!shell.sortButton.isEnabled)
    #expect(shell.toggleButton.nextKeyView?.nextKeyView === shell.displayButton)
    #expect(shell.displayButton.nextKeyView === anchor)
    shell.setFooterActionsEnabled(true)
    #expect(shell.searchField.isEnabled)
}

@Test @MainActor func nativeSearchClearAndReadingStateKeepFieldAndResultsInStep() {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    var changes: [String] = []
    shell.onSearchChange = { changes.append($0) }
    shell.setSearchTerm("missing")
    shell.showSearchEmpty(true, term: "missing")
    shell.searchField.stringValue = "" // NSSearchField's built-in clear button has emptied the cell.
    shell.searchFieldDidEndSearching(shell.searchField)
    #expect(changes == [""])
    shell.setFooterActionsEnabled(false)
    #expect(shell.searchEmptyVisible == false)
    #expect(shell.searchField.isEnabled == false)
}

@Test @MainActor func searchFieldNativeActionAndClickOutsideCollapse() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 680),
        preferencesStore: InMemoryDisplayPreferencesStore())
    var terms: [String] = []
    shell.onSearchChange = { terms.append($0) }
    shell.searchButton.performClick(nil)
    #expect(!shell.searchField.isHidden)
    #expect(!shell.searchField.isHidden)
    shell.setSearchTerm("cafe")
    let action = try #require(shell.searchField.action)
    #expect(shell.searchField.target === shell)
    #expect(action == #selector(GridShellView.searchFieldAction))
    shell.searchFieldAction()
    #expect(terms == ["cafe"])
    shell.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
        object: shell.searchField))
    #expect(shell.searchField.isHidden)
    #expect(shell.searchButton.state == .on)
    shell.searchButton.performClick(nil)
    #expect(shell.searchField.stringValue == "cafe")
    shell.searchField.stringValue = ""
    shell.searchFieldAction()
    #expect(terms == ["cafe", ""])
    #expect(shell.searchButton.state == .off)
    #expect(shell.searchField.isHidden && !shell.searchButton.isHidden)
}

@Test @MainActor func footerSortActionsUseFolderMenuActionsAndReflectCurrentConditions() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    shell.sortConditions = { FolderViewConditions(sort: .size, direction: .descending) }
    var chosen: FolderMenuAction?
    shell.onSort = { chosen = $0 }
    let menu = shell.makeSortMenu()
    var openedMenu: NSMenu?
    shell.onOpenSortMenu = { _, menu in openedMenu = menu }
    shell.sortButton.performClick(nil)
    #expect(openedMenu?.items.count == menu.items.count)
    let size = try #require(menu.items.first { $0.accessibilityIdentifier() == "folder.sort.size.menu" })
    let descending = try #require(menu.items.first { $0.accessibilityIdentifier() == "folder.order.descending.menu" })
    #expect(size.state == .on)
    #expect(descending.state == .on)
    menu.performActionForItem(at: menu.index(of: size))
    #expect(chosen == .sort(.size))
}

@Test @MainActor func gridCurrentItemSetterKeepsVisibleIdentityOrFallsBack() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-grid-current-search")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let first = FolderEntry(url: folder.appendingPathComponent("a.jpg"), root: root)
    let second = FolderEntry(url: folder.appendingPathComponent("b.jpg"), root: root)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 640, height: 600))
    grid.display(FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [first, second], isComplete: true), selectedItemID: nil)
    #expect(grid.displayedItemIDs == [first.itemID, second.itemID])
    grid.setCurrentItemID(second.itemID)
    #expect(grid.currentItemID == second.itemID)
    grid.setCurrentItemID(nil)
    #expect(grid.currentItemID == first.itemID)
}
