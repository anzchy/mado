import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
@testable import MadoMacUI

/// #114 / P3-11 WI-3: the page-15 Display popover (grid-display.html `.grid-tools-panel`) and its shell hookup.
@MainActor private final class Issue114PanelCounter: DisplayPreferencesObserver {
    var values: [DisplayPreferences] = []
    func preferencesDidChange(_ preferences: DisplayPreferences) { values.append(preferences) }
}

@MainActor private final class Issue114PanelFixture {
    let store: InMemoryDisplayPreferencesStore
    let shell: GridShellView
    let grid: GridBrowserView
    let window: NSWindow
    let counter = Issue114PanelCounter()
    let entries: [FolderEntry]
    init(width: CGFloat = 1280, sidebar: Bool = false, preferences: DisplayPreferences = .init(),
         count: Int = 12) throws {
        _ = NSApplication.shared
        var value = preferences
        value.gridSidebarVisible = sidebar
        store = InMemoryDisplayPreferencesStore(value)
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 800), preferencesStore: store)
        shell.appearance = NSAppearance(named: .aqua)
        grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
        grid.autoresizingMask = [.width, .height]
        shell.mainContent.addSubview(grid)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = shell
        window.orderFrontRegardless()
        // performClick on a button in an on-screen window, interleaved with the async Page22 tests, ends the test
        // process early (reproduced with the shell's sidebar button too); responders and key events need no on-screen window.
        window.orderOut(nil)
        let scrollView = try #require(grid.collectionView.enclosingScrollView)
        scrollView.scrollerStyle = .overlay
        scrollView.tile()
        let url = URL(fileURLWithPath: "/tmp/mado-grid-114-panel")
        let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: url)
        entries = (0..<count).map { FolderEntry(url: url.appendingPathComponent("IMG_\($0).jpg"), root: root) }
        grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: url, generation: 1),
            entries: entries, isComplete: true), selectedItemID: nil)
        grid.activate()
        settle()
        store.observe(counter)
    }
    var panel: GridDisplayPanelView { shell.displayPanel }
    func settle() {
        shell.layoutSubtreeIfNeeded()
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        for item in grid.collectionView.visibleItems() { item.view.layoutSubtreeIfNeeded() }
    }
    func click() {
        shell.displayButton.performClick(nil)
        settle()
    }
    /// Detaches the views, so nothing in this window outlives the test (#316 f89a0cab).
    func close() {
        grid.removeFromSuperview()
        window.contentView = nil
        window.close()
    }
    func write(size: Double, names: Bool, fit: ThumbnailFit) {
        var value = store.value
        value.thumbnailSize = size
        value.showFileNames = names
        value.thumbnailFit = fit
        store.value = value
    }
    var layout: NSCollectionViewFlowLayout { grid.collectionView.collectionViewLayout as! NSCollectionViewFlowLayout }
    var columns: Int {
        guard let first = layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0)) else { return 0 }
        return (0..<entries.count).filter { index in
            layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)).map {
                abs($0.frame.minY - first.frame.minY) < 0.5 } ?? false
        }.count
    }
    var visiblePhotoItems: [GridPhotoItem] { grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem } }
    /// A frame in shell coordinates.
    func rect(_ view: NSView) -> NSRect { shell.convert(view.bounds, from: view) }
    func escape() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        window.sendEvent(event)
        settle()
    }
}

@MainActor private func issue114AXValue(_ view: NSView) -> String? {
    switch view.accessibilityValue() {
    case let number as NSNumber: number.stringValue
    case let string as String: string
    default: nil
    }
}

/// Selects a popup item, failing (not trapping) when the popup lacks it.
@MainActor private func issue114Select(_ popup: NSPopUpButton, _ index: Int) throws {
    try #require(index < popup.numberOfItems, "popup has \(popup.numberOfItems) items")
    popup.selectItem(at: index)
}

@MainActor private func issue114Send(_ control: NSControl) {
    _ = control.sendAction(control.action, to: control.target)
}

private func issue114Pixels(_ value: String) -> Double? {
    value.hasSuffix("px") ? Double(value.dropLast(2)) : nil
}

private func issue114Hex(_ value: String) -> [Double]? {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard text.hasPrefix("#"), text.count == 7, let number = Int(text.dropFirst(), radix: 16) else { return nil }
    return [Double((number >> 16) & 0xff) / 255, Double((number >> 8) & 0xff) / 255, Double(number & 0xff) / 255]
}

private let issue114ComingSoonMarkers = ["Coming Soon", "即将推出"]

/// One #114 panel window at a time: other suites still run concurrently while the loops below yield (#316 f89a0cab).
@Suite(.serialized) struct Issue114GridDisplayPanelTests {
    // MARK: Toggle

    @Test @MainActor func issue114PanelToggleParityAndPressedState() throws {
        let f = try Issue114PanelFixture()
        defer { f.close() }
        let button = f.shell.displayButton
        func expectOpen(_ open: Bool, _ step: String) {
            #expect(f.shell.isDisplayPanelOpen == open, "\(step)")
            #expect((f.panel.superview === f.shell && !f.panel.isHidden) == open, "\(step): panel visible iff open")
            #expect(button.state == (open ? .on : .off), "\(step): pressed state")
            #expect(issue114AXValue(button) == (open ? "1" : "0"), "\(step): AX value")
        }
        expectOpen(false, "initial")
        let steps: [(String, () throws -> Void, Bool)] = [
            ("click 1", { f.click() }, true), ("click 2", { f.click() }, false), ("click 3", { f.click() }, true),
            ("close button", { f.panel.closeButton.performClick(nil); f.settle() }, false),
            ("click 4", { f.click() }, true), ("escape", { try f.escape() }, false),
            ("click 5", { f.click() }, true), ("click 6", { f.click() }, false),
        ]
        for (name, action, open) in steps {
            try action()
            expectOpen(open, name)
        }
    }

    @Test @MainActor func issue114PanelEscAndCloseReturnFocusToDisplayButton() throws {
        let f = try Issue114PanelFixture()
        defer { f.close() }
        f.click()
        #expect((f.window.firstResponder as? NSView)?.isDescendant(of: f.panel) == true, "open focuses inside the panel")
        try f.escape()
        #expect(!f.shell.isDisplayPanelOpen)
        #expect(f.window.firstResponder === f.shell.displayButton)

        f.click()
        #expect(f.window.makeFirstResponder(f.panel.sizeSlider))
        try f.escape()
        #expect(!f.shell.isDisplayPanelOpen)
        #expect(f.window.firstResponder === f.shell.displayButton)

        f.click()
        #expect(f.shell.isDisplayPanelOpen)
        f.panel.closeButton.performClick(nil)
        f.settle()
        #expect(!f.shell.isDisplayPanelOpen)
        #expect(f.window.firstResponder === f.shell.displayButton)
        #expect(f.panel.closeButton.accessibilityLabel() == "Close Display Panel")
        #expect(f.panel.closeButton.frame.size == NSSize(width: 30, height: 28))
    }

    // MARK: Panel ⇄ store ⇄ grid

    @Test @MainActor func issue114PanelSliderWritesNormalizedSizeAndGrid() throws {
        let f = try Issue114PanelFixture()
        defer { f.close() }
        f.click()
        let slider = f.panel.sizeSlider
        #expect(slider.minValue == 140 && slider.maxValue == 280)
        #expect(slider.numberOfTickMarks == 15 && slider.allowsTickMarkValuesOnly && slider.isContinuous)
        #expect(abs(slider.frame.width - 110) < 0.01)
        slider.doubleValue = 173
        issue114Send(slider)
        f.settle()
        #expect(f.store.value.thumbnailSize == 170)
        #expect(slider.doubleValue == 170)
        #expect(f.columns == 6)
        #expect(f.counter.values.count == 1, "one write per action, no echo")
        slider.doubleValue = 146
        issue114Send(slider)
        f.settle()
        #expect(f.store.value.thumbnailSize == 150)
        #expect(slider.doubleValue == 150)
        #expect(f.columns == 7)
        #expect(f.counter.values.count == 2)
    }

    @Test @MainActor func issue114PanelCheckboxAndPopupWriteStoreAndGrid() throws {
        let f = try Issue114PanelFixture()
        defer { f.close() }
        f.click()
        let checkbox = f.panel.namesCheckbox, popup = f.panel.fitPopup
        #expect(checkbox.state == .on)
        checkbox.performClick(nil)
        f.settle()
        #expect(f.store.value.showFileNames == false)
        #expect(abs(f.layout.itemSize.height - 196.16) < 0.01)
        #expect(!f.visiblePhotoItems.isEmpty && f.visiblePhotoItems.allSatisfy { !$0.isNameVisible })
        #expect(popup.itemTitles == ["Fill and Crop", "Fit Entire Image"])
        try issue114Select(popup, 1)
        issue114Send(popup)
        f.settle()
        #expect(f.store.value.thumbnailFit == .fit)
        #expect(f.visiblePhotoItems.allSatisfy { $0.tileLayer?.contentsGravity == .resizeAspect })
        try issue114Select(popup, 0)
        issue114Send(popup)
        f.settle()
        #expect(f.store.value.thumbnailFit == .fill)
        #expect(f.visiblePhotoItems.allSatisfy { $0.tileLayer?.contentsGravity == .resizeAspectFill })
        #expect(f.counter.values.count == 3)
    }

    @Test @MainActor func issue114PanelReflectsExternalStoreWrites() throws {
        let f = try Issue114PanelFixture()
        defer { f.close() }
        f.click()
        f.write(size: 260, names: false, fit: .fit)
        f.settle()
        #expect(f.panel.sizeSlider.doubleValue == 260)
        #expect(f.panel.namesCheckbox.state == .off)
        #expect(f.panel.fitPopup.indexOfSelectedItem == 1)
        #expect(f.columns == 4)
        #expect(f.counter.values.count == 1, "reflecting a store write does not write back")

        f.click()
        #expect(!f.shell.isDisplayPanelOpen)
        f.write(size: 150, names: true, fit: .fill)
        f.click()
        #expect(f.shell.isDisplayPanelOpen)
        #expect(f.panel.sizeSlider.doubleValue == 150)
        #expect(f.panel.namesCheckbox.state == .on)
        #expect(f.panel.fitPopup.indexOfSelectedItem == 0)
        #expect(f.columns == 7)

        // Adversary round 1: with the panel closed the grid still follows the store.
        f.click()
        #expect(!f.shell.isDisplayPanelOpen)
        f.write(size: 150, names: false, fit: .fit)
        f.settle()
        #expect(f.columns == 7)
        // #349: pinned size variants scale tile height above720pt; hidden names keep only8pt padding.
        #expect(abs(f.layout.itemSize.height - (188.16 * 150 / 220 + 8)) < 0.01)
        #expect(!f.visiblePhotoItems.isEmpty && f.visiblePhotoItems.allSatisfy { $0.tileLayer?.contentsGravity == .resizeAspect })
        #expect(!f.shell.isDisplayPanelOpen)
        #expect(f.counter.values.count == 3)
    }

    @Test @MainActor func issue114PanelShellPushesStoredOptionsToAttachedGrid() throws {
        var stored = DisplayPreferences()
        stored.thumbnailSize = 260
        stored.showFileNames = false
        stored.thumbnailFit = .fit
        let f = try Issue114PanelFixture(preferences: stored)
        defer { f.close() }
        #expect(f.columns == 4)
        // #349: stored260pt size scales the default220pt tile height too.
        #expect(abs(f.layout.itemSize.height - (188.16 * 260 / 220 + 8)) < 0.01)
        #expect(!f.visiblePhotoItems.isEmpty && f.visiblePhotoItems.allSatisfy { $0.tileLayer?.contentsGravity == .resizeAspect })
        #expect(f.counter.values.isEmpty, "applying stored options writes nothing")
    }

    @Test @MainActor func issue114PanelShellObserverIsWeak() {
        _ = NSApplication.shared
        let store = InMemoryDisplayPreferencesStore()
        weak var probe: GridShellView?
        autoreleasepool {
            let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), preferencesStore: store)
            shell.layoutSubtreeIfNeeded()
            probe = shell
        }
        #expect(probe == nil)
        store.value.thumbnailSize = 150
        #expect(store.value.thumbnailSize == 150)
    }

    @Test @MainActor func issue114PanelAndSettingsWritesPreserveConcurrentFields() throws {
        let f = try Issue114PanelFixture()
        defer { f.close() }
        f.click()
        func external(_ change: (inout DisplayPreferences) -> Void) -> DisplayPreferences {
            var value = f.store.value
            change(&value)
            f.store.value = value
            return f.store.value
        }
        var expected = external { $0.gridSidebarWidth = 300; $0.appearance = .dark }
        f.panel.sizeSlider.doubleValue = 173
        issue114Send(f.panel.sizeSlider)
        expected.thumbnailSize = 170
        #expect(f.store.value == expected)

        expected = external { $0.gridSidebarWidth = 240; $0.appearance = .light; $0.alwaysShowTools = true }
        f.panel.namesCheckbox.performClick(nil)
        expected.showFileNames = false
        #expect(f.store.value == expected)

        expected = external { $0.loopThroughImages = true; $0.folderSort = .modificationDate }
        try issue114Select(f.panel.fitPopup, 1)
        issue114Send(f.panel.fitPopup)
        expected.thumbnailFit = .fit
        #expect(f.store.value == expected)
    }

    // MARK: Panel layout (page 15, light, @1x, 1280×800)

    @Test @MainActor func issue114PanelPinnedGeometryAndHeader() throws {
        let design = try PinnedDesign.page("grid-display")
        let f = try Issue114PanelFixture(sidebar: true)
        defer { f.close() }
        f.click()
        let panel = f.rect(f.panel)
        let right = try #require(issue114Pixels(try design.exactDeclaration(".grid-tools-panel", "right")))
        let bottom = try #require(issue114Pixels(try design.exactDeclaration(".grid-tools-panel", "bottom")))
        let width = try #require(issue114Pixels(try design.exactDeclaration(".grid-tools-panel", "width")))
        let padding = try #require(issue114Pixels(try design.exactDeclaration(".grid-tools-panel", "padding")))
        let headerGap = try #require(issue114Pixels(try design.exactDeclaration(".grid-tools-panel header", "margin-bottom")))
        #expect(right == 12 && bottom == 50 && width == 280 && padding == 12 && headerGap == 9)
        #expect(abs(panel.maxX - (1280 - right)) < 0.01, "\(panel)")
        #expect(abs(panel.minY - bottom) < 0.01, "\(panel)")
        #expect(abs(panel.width - width) < 0.01)
        #expect(panel.minY >= f.shell.footer.frame.maxY)

        let rows = f.panel.rows.map(f.rect)
        #expect(rows.count == 3)
        for row in rows {
            #expect(abs(row.minX - (panel.minX + padding)) < 0.01)
            #expect(abs(row.maxX - (panel.maxX - padding)) < 0.01)
        }
        #expect(abs(rows[rows.count - 1].minY - (panel.minY + padding)) < 0.01)
        let close = f.rect(f.panel.closeButton)
        #expect(abs(close.maxY - (panel.maxY - padding)) < 0.01)
        #expect(abs(close.maxX - (panel.maxX - padding)) < 0.01)
        #expect(abs(close.minY - rows[0].maxY - headerGap) < 0.01)
        let title = f.rect(f.panel.titleLabel)
        #expect(abs(title.minX - (panel.minX + padding)) < 0.01)
        #expect(abs(title.midY - close.midY) <= 0.5)
        #expect(title.maxX <= close.minX)

        let radius = try design.lengthValue(try design.exactDeclaration(".grid-tools-panel", "border-radius"), viewport: 1280)
        #expect(radius == 10 && radius == DesignMetrics.radii["popover"])
        #expect(abs(Double(f.panel.layer?.cornerRadius ?? 0) - radius) < 0.01)
        #expect(try design.exactDeclaration(".grid-tools-panel", "background") == "var(--color-panel)")
        let expected = try #require(issue114Hex(try design.rootToken("--color-panel")))
        let background = try #require(f.panel.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
        let actual = [background.redComponent, background.greenComponent, background.blueComponent].map(Double.init)
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 1.0 / 255 }, "\(actual) vs \(expected)")
        #expect(background.alphaComponent == 1)
        #expect((f.panel.layer?.shadowOpacity ?? 0) > 0, "soft shadow present (exact CSS shadow NOT VERIFIED)")

        let font = try design.font(".grid-tools-panel header strong", viewport: 1280)
        #expect(font.size == 13 && font.weight == 500)
        let titleFont = try #require(f.panel.titleLabel.font)
        #expect(titleFont.pointSize == 13)
        let traits = titleFont.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = try #require(traits?[.weight] as? CGFloat)
        #expect(abs(weight - NSFont.Weight.medium.rawValue) < 0.01)
    }

    @Test @MainActor func issue114PanelRowMetricsViaExactDeclaration() throws {
        let design = try PinnedDesign.page("grid-display")
        #expect(try design.exactDeclaration(".setting-row", "padding") == "10px 2px")
        let minHeight = try #require(issue114Pixels(try design.exactDeclaration(".setting-row", "min-height")))
        let gap = try #require(issue114Pixels(try design.exactDeclaration(".setting-row", "gap")))
        let fontSize = try #require(issue114Pixels(try design.exactDeclaration(".setting-row", "font-size")))
        let rangeWidth = try #require(issue114Pixels(try design.exactDeclaration(".setting-row input[type=\"range\"]", "width")))
        let selectMax = try #require(issue114Pixels(try design.exactDeclaration(".setting-row select", "max-width")))
        #expect(minHeight == 34 && gap == 14 && fontSize == 12 && rangeWidth == 110 && selectMax == 135)

        let f = try Issue114PanelFixture(sidebar: true)
        defer { f.close() }
        f.click()
        let panel = f.panel
        let rows = panel.rows.map(f.rect)
        let controls: [NSView] = [panel.sizeSlider, panel.namesCheckbox, panel.fitPopup]
        #expect(rows.count == 3 && panel.rowLabels.count == 3)
        for index in rows.indices {
            let row = rows[index], label = f.rect(panel.rowLabels[index]), control = f.rect(controls[index])
            #expect(abs(row.width - 256) < 0.01, "row \(index) \(row)")
            #expect(row.height >= minHeight - 0.01, "row \(index) \(row)")
            #expect(row.height >= control.height + 20 - 0.01 && row.height >= label.height + 20 - 0.01, "row \(index) padding")
            if index + 1 < rows.count { #expect(abs(row.minY - rows[index + 1].maxY) < 0.01, "rows contiguous") }
            #expect(abs(label.minX - row.minX - 2) < 0.01, "row \(index) label inset")
            #expect(abs(row.maxX - control.maxX - 2) < 0.01, "row \(index) control inset")
            #expect(label.maxX + gap <= control.minX + 0.01, "row \(index) gap")
            #expect(abs(label.midY - row.midY) <= 0.5 && abs(control.midY - row.midY) <= 0.5, "row \(index) centred")
            #expect(panel.rowLabels[index].font.map { Double($0.pointSize) } == fontSize)
            #expect(ceil(panel.rowLabels[index].cell!.cellSize.width) <= label.width + 0.01)
        }
        #expect(abs(panel.sizeSlider.frame.width - rangeWidth) < 0.01)
        #expect(panel.fitPopup.frame.width <= selectMax + 0.01)
        let checkbox = panel.namesCheckbox.frame.size
        #expect(checkbox == NSSize(width: 15, height: 15) || checkbox == panel.namesCheckbox.intrinsicContentSize,
                "checkbox \(checkbox), intrinsic \(panel.namesCheckbox.intrinsicContentSize)")
    }

    @Test @MainActor func issue114PanelNarrowShellStaysInside() async throws {
        for (width, expected) in [(CGFloat(290), CGFloat(266)), (238, 214)] {
            let f = try Issue114PanelFixture(width: width)
            defer { f.close() }
            f.click()
            let panel = f.rect(f.panel)
            #expect(abs(panel.width - expected) < 0.01, "\(width): \(panel)")
            #expect(abs(panel.minX - 12) < 0.01 && abs(panel.maxX - (width - 12)) < 0.01, "\(width): \(panel)")
            let controls: [NSView] = [f.panel.sizeSlider, f.panel.namesCheckbox, f.panel.fitPopup]
            for (index, rowView) in f.panel.rows.enumerated() {
                let row = f.rect(rowView), label = f.rect(f.panel.rowLabels[index]), control = f.rect(controls[index])
                #expect(row.minX >= panel.minX && row.maxX <= panel.maxX, "\(width) row \(index)")
                #expect(control.minX >= row.minX + 2 - 0.01 && control.maxX <= row.maxX - 2 + 0.01, "\(width) row \(index)")
                #expect(label.minX >= row.minX + 2 - 0.01)
                #expect(label.maxX + 14 <= control.minX + 0.01, "\(width) row \(index): \(label) \(control)")
                #expect(ceil(f.panel.rowLabels[index].cell!.cellSize.width) <= label.width + 0.01, "\(width) row \(index) label fits")
            }
            #expect(f.panel.sizeSlider.frame.width > 0 && f.panel.sizeSlider.frame.width <= 110)
            let title = f.rect(f.panel.titleLabel), close = f.rect(f.panel.closeButton)
            #expect(title.minX >= panel.minX && close.maxX <= panel.maxX && title.maxX <= close.minX)
            await Task.yield()
        }
    }

    @Test @MainActor func issue114PanelContentPressureEnAndZh() async throws {
        let languages: [(String, String, [String], [String])] = [
            ("en", "Display and Appearance", ["Thumbnail Size", "Show File Names", "Thumbnails"],
             ["Fill and Crop", "Fit Entire Image"]),
            ("zh-Hans", "显示与外观", ["缩略图大小", "显示文件名", "缩略图"], ["填充裁剪", "完整显示"]),
        ]
        for (language, title, labels, options) in languages {
            let f = try Issue114PanelFixture(sidebar: true)
            defer { f.close() }
            f.click()
            let panel = f.panel
            panel.titleLabel.stringValue = title
            for (label, text) in zip(panel.rowLabels, labels) { label.stringValue = text }
            for (index, text) in options.enumerated() where index < panel.fitPopup.numberOfItems { panel.fitPopup.item(at: index)?.title = text }
            panel.needsLayout = true
            f.settle()
            #expect(ceil(panel.titleLabel.cell!.cellSize.width) <= panel.titleLabel.frame.width + 0.01, "\(language) title")
            #expect(panel.titleLabel.frame.maxX <= panel.closeButton.frame.minX, "\(language) title")
            let controls: [NSView] = [panel.sizeSlider, panel.namesCheckbox, panel.fitPopup]
            for (index, label) in panel.rowLabels.enumerated() {
                let cell = label.cell!.cellSize
                #expect(ceil(cell.width) <= label.frame.width + 0.01 && ceil(cell.height) <= label.frame.height + 0.01,
                        "\(language) \(label.stringValue): \(cell) in \(label.frame)")
                #expect(f.rect(label).maxX + 14 <= f.rect(controls[index]).minX + 0.01, "\(language) row \(index) gap")
            }
            for index in options.indices {
                try issue114Select(panel.fitPopup, index)
                #expect(panel.fitPopup.cell!.cellSize.width <= panel.fitPopup.frame.width + 0.01,
                        "\(language) \(options[index]): \(panel.fitPopup.cell!.cellSize) in \(panel.fitPopup.frame)")
            }
            await Task.yield()
        }
    }

    // MARK: Footer button and key loop

    @Test @MainActor func issue114PanelFooterButtonImplementedAt481And480() {
        _ = NSApplication.shared
        for (width, buttonWidth, inset) in [(CGFloat(481), CGFloat(30), CGFloat(12)), (480, 26, 7)] {
            let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: width, height: 680),
                                      preferencesStore: InMemoryDisplayPreferencesStore())
            shell.layoutSubtreeIfNeeded()
            let button = shell.displayButton
            #expect(button.frame.size == NSSize(width: buttonWidth, height: 28), "\(width)")
            #expect(abs(button.frame.maxX - (width - inset)) < 0.01, "\(width)")
            #expect(!button.isHidden && button.superview != nil)
            #expect(button.isEnabled)
            #expect(button.action != nil && button.target != nil)
            #expect(button.acceptsFirstResponder && button.canBecomeKeyView)
            for marker in issue114ComingSoonMarkers {
                #expect(button.toolTip?.contains(marker) != true, "\(width) tooltip")
                #expect(button.accessibilityLabel()?.contains(marker) != true, "\(width) AX label")
            }
            #expect(button.accessibilityLabel()?.isEmpty == false)
            for other in [shell.favoritesButton, shell.recentsButton, shell.infoButton] {
                #expect(!other.isEnabled && other.action == nil, "\(other.accessibilityIdentifier())")
            }
        }
        #expect(EntryPoint.footerDisplay.state == .implemented)
        #expect([EntryPoint.favorites, .recents, .footerInfo].allSatisfy { $0.state == .comingSoon })
    }

    @Test @MainActor func issue114PanelKeyLoopContainsDisplayButtonOnce() async {
        _ = NSApplication.shared
        for actions in [true, false] {
            for emptyShown in [true, false] {
                for sidebar in [true, false] {
                    for searchFocused in [false, true] {
                        let step = "actions \(actions) empty \(emptyShown) sidebar \(sidebar) search \(searchFocused)"
                        var preferences = DisplayPreferences()
                        preferences.gridSidebarVisible = sidebar
                        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
                                                  preferencesStore: InMemoryDisplayPreferencesStore(preferences))
                        shell.layoutSubtreeIfNeeded()
                        let anchor = NSView()
                        shell.linkKeyViews(from: anchor)
                        if searchFocused { shell.focusSearch() }
                        if emptyShown { shell.showSearchEmpty(true, term: "x") }
                        if !actions { shell.setFooterActionsEnabled(false) }
                        var loop: [NSView] = []
                        var view = anchor.nextKeyView
                        while let next = view, next !== anchor, loop.count < 50 { loop.append(next); view = next.nextKeyView }
                        #expect(view === anchor, "\(step): loop returns to the anchor")
                        #expect(loop.filter { $0 === shell.displayButton }.count == 1, "\(step)")
                        var footer: [NSView] = [shell.firstFooterKeyView]
                        while let next = shell.adjacentFooterKeyView(to: footer[footer.count - 1], reverse: false),
                              footer.count < 50 { footer.append(next) }
                        #expect(footer.count == loop.count && zip(footer, loop).allSatisfy { $0 === $1 },
                                "\(step): footer order matches the key loop")
                        #expect(footer.filter { $0 === shell.displayButton }.count == 1, "\(step)")
                        if actions {
                            #expect(shell.adjacentFooterKeyView(to: shell.sortButton, reverse: false) === shell.displayButton, "\(step)")
                            #expect(shell.lastFooterKeyView === (emptyShown ? shell.clearSearchButton : shell.displayButton), "\(step)")
                        } else {
                            #expect(shell.lastFooterKeyView === shell.displayButton, "\(step)")
                            #expect(!loop.contains { $0 === shell.sortButton || $0 === shell.searchButton }, "\(step)")
                        }
                        await Task.yield()
                    }
                }
            }
        }
    }

    @Test @MainActor func issue114PanelDisplayButtonLiveWhenFooterActionsOff() async throws {
        let cases: [(String, (GridShellView) -> Void)] = [
            ("footer actions off", { $0.setFooterActionsEnabled(false) }),
            ("empty folder page", { $0.setEmptyFolderState(true, recents: [], now: Date()) }),
            ("read failed", { $0.setReadFailedStatus(true) }),
        ]
        for (name, apply) in cases {
            let f = try Issue114PanelFixture()
            defer { f.close() }
            apply(f.shell)
            f.settle()
            #expect(f.shell.displayButton.isEnabled, "\(name)")
            f.click()
            #expect(f.shell.isDisplayPanelOpen, "\(name)")
            let slider = f.panel.sizeSlider
            let centre = f.shell.convert(NSPoint(x: slider.bounds.midX, y: slider.bounds.midY), from: slider)
            let point = f.shell.superview.map { f.shell.convert(centre, to: $0) } ?? centre
            #expect(f.shell.hitTest(point) === slider, "\(name): panel above the page")
            await Task.yield()
        }
    }
}
