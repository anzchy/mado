import AppKit
import SwiftUI
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func issue351Views(_ root: NSView?) -> [NSView] {
    guard let root else { return [] }
    return [root] + root.subviews.flatMap(issue351Views)
}

@MainActor private func issue351Control<T: NSView>(_ id: String, in root: NSView?, as type: T.Type) throws -> T {
    try #require(issue351Views(root).first { $0.accessibilityIdentifier() == id } as? T)
}

@MainActor private func issue351Raster(_ view: NSView) throws -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

/// Real grants, folder scanning and ImageIO loading, with windows kept ordered out.
@MainActor private final class Issue351AppContext {
    let base: URL, image: URL
    let suite = "mado.app351.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: UserDefaultsDisplayPreferencesStore
    let services: AccessServices
    var controllers: [CanvasWindowController] = []
    var settings: [SettingsPanelWindow] = []
    init() async throws {
        _ = NSApplication.shared
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = base.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        image = folder.appendingPathComponent("a.png")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/portrait-2x3.png")
        try Data(contentsOf: fixture).write(to: image)
        defaults = try #require(UserDefaults(suiteName: suite))
        store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue351")
        _ = try await access.grant(folder: base)
        services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    }
    func panel(store override: (any DisplayPreferencesStore)? = nil) -> SettingsPanelWindow {
        let selectedStore = override ?? store
        let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(directory: base.appendingPathComponent("cache")),
            appearanceAdapter: WindowAppearanceAdapter(preferencesStore: selectedStore),
            preferencesStore: selectedStore, defaults: defaults)
        settings.append(panel)
        panel.window.orderOut(nil)
        panel.select(.display)
        panel.window.contentView?.layoutSubtreeIfNeeded()
        return panel
    }
    func open(store override: (any DisplayPreferencesStore)? = nil) async throws -> CanvasWindowController {
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: override ?? store,
            accessServices: Task { self.services }, motionPolicy: MotionPolicy(source: Issue349Motion()))
        controllers.append(controller)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderOut(nil)
        controller.openInput([image])
        let chrome = try #require(issue351Views(window.contentView).compactMap { $0 as? ViewerChromeOverlay }.first)
        try await waitUntil("real image and visible viewer groups") {
            controller.session.imageStatus == .showing &&
                controller.session.folderScan?.sourceSnapshot?.isComplete == true &&
                chrome.groups.allSatisfy { !$0.isHiddenOrHasHiddenAncestor }
        }
        return controller
    }
    func close() {
        for panel in settings { panel.window.close() }
        for controller in controllers { controller.window?.close() }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }
}

@MainActor private func issue351ExpectViewer(_ controller: CanvasWindowController, _ expected: DisplayPreferences) throws {
    #expect(controller.session.imageStatus == .showing)
    #expect(controller.session.displayPreferences == expected)
    let descendants = issue351Views(controller.window?.contentView)
    let chrome = try #require(descendants.compactMap { $0 as? ViewerChromeOverlay }.first)
    #expect(chrome.groups.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
    for group in chrome.groups {
        let surface = try issue351Control("chrome.tool-background", in: group, as: NSView.self)
        let pixels = try issue351Raster(surface)
        let scale = CGFloat(pixels.pixelsWide) / surface.bounds.width
        let actual = try #require(pixels.colorAt(x: Int(1 * scale), y: Int(19 * scale)))
        #expect(abs(actual.alphaComponent - expected.toolBackgroundOpacity / 100) < 0.015)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue351SettingsSliderUpdatesAllRealViewersAndRestoresAfterReopen() async throws {
    let context = try await Issue351AppContext()
    defer { context.close() }
    var expected = DisplayPreferences(alwaysShowTools: true, appearance: .light, gridSidebarWidth: 284, gridSidebarVisible: false)
    expected.loopThroughImages = true; expected.thumbnailSize = 170; expected.showFileNames = false; expected.thumbnailFit = .fit
    context.store.value = expected
    let a = try await context.open(), b = try await context.open()
    let panel = context.panel()
    let slider = try issue351Control("settings.display.tool-opacity", in: panel.window.contentView, as: NSSlider.self)
    let value = try issue351Control("settings.display.tool-opacity.value", in: panel.window.contentView, as: NSTextField.self)
    #expect(slider.doubleValue == 50 && value.stringValue == "50%")
    for (opacity, text) in [(30.0, "30%"), (63.5, "63.5%"), (100, "100%"), (50, "50%")] {
        slider.doubleValue = opacity
        #expect(slider.sendAction(slider.action, to: slider.target))
        expected.toolBackgroundOpacity = opacity
        #expect(context.store.value == expected)
        #expect(value.stringValue == text)
        try issue351ExpectViewer(a, expected); try issue351ExpectViewer(b, expected)
    }
    // An external preference change also updates Settings and already-open viewers immediately.
    expected.toolBackgroundOpacity = 63.5
    context.store.value = expected
    #expect(slider.doubleValue == 63.5 && value.stringValue == "63.5%")
    try issue351ExpectViewer(a, expected); try issue351ExpectViewer(b, expected)
    let later = try await context.open()
    try issue351ExpectViewer(later, expected)
    let reopenedStore = UserDefaultsDisplayPreferencesStore(defaults: context.defaults)
    #expect(reopenedStore.value == expected)
    let reopened = try await context.open(store: reopenedStore)
    try issue351ExpectViewer(reopened, expected)
    let reopenedPanel = context.panel(store: reopenedStore)
    #expect(try issue351Control("settings.display.tool-opacity", in: reopenedPanel.window.contentView, as: NSSlider.self).doubleValue == 63.5)

    // Inspector is a protected surface; real metadata and hosted drawing stay unchanged.
    a.toggleInspector()
    try await waitUntil("real Inspector metadata") {
        if case .known = a.inspector.value { return a.inspectorVisible }
        return false
    }
    let descendants = issue351Views(a.window?.contentView)
    let inspector = try #require(descendants.compactMap { $0 as? NSHostingView<MotionPolicyContent<InspectorPanel>> }.first)
    #expect(!inspector.isHiddenOrHasHiddenAncestor)
    inspector.layoutSubtreeIfNeeded()
    let reference = try issue351Raster(inspector).tiffRepresentation
    let metadata = a.inspector.value
    let frame = inspector.frame
    for opacity in [30.0, 50, 100] {
        expected.toolBackgroundOpacity = opacity
        context.store.value = expected
        try issue351ExpectViewer(a, expected)
        #expect(a.inspector.value == metadata && inspector.frame == frame)
        #expect(try issue351Raster(inspector).tiffRepresentation == reference)
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue351SettingsSliderHasLiveKeyboardAXAndHiddenPaneExclusion() async throws {
    let context = try await Issue351AppContext()
    defer { context.close() }
    let panel = context.panel()
    let slider = try issue351Control("settings.display.tool-opacity", in: panel.window.contentView, as: NSSlider.self)
    let value = try issue351Control("settings.display.tool-opacity.value", in: panel.window.contentView, as: NSTextField.self)
    #expect(slider.minValue == 30 && slider.maxValue == 100 && slider.doubleValue == 50)
    #expect(slider.isEnabled && slider.isContinuous && slider.acceptsFirstResponder && slider.canBecomeKeyView)
    #expect(slider.isAccessibilityElement() && slider.accessibilityRole() == .slider)
    #expect(slider.accessibilityLabel() == String(localized: "Tool Background Opacity"))
    #expect((slider.accessibilityMinValue() as? NSNumber)?.doubleValue == 30)
    #expect((slider.accessibilityMaxValue() as? NSNumber)?.doubleValue == 100)
    #expect(slider.accessibilityChildren()?.isEmpty != false)
    func expectValue(_ opacity: Double, text: String) {
        #expect(context.store.value.toolBackgroundOpacity == opacity)
        #expect(slider.doubleValue == opacity)
        #expect((slider.accessibilityValue() as? NSNumber)?.doubleValue == opacity)
        #expect(slider.accessibilityValueDescription() == text && value.stringValue == text)
    }
    expectValue(50, text: "50%")
    panel.window.recalculateKeyViewLoop()
    _ = panel.window.makeFirstResponder(panel.window)
    if let preceding = slider.previousKeyView { panel.window.selectKeyView(following: preceding) }
    var forward = false
    for _ in 0..<40 {
        panel.window.selectNextKeyView(nil)
        if panel.window.firstResponder === slider { forward = true; break }
    }
    #expect(forward)
    panel.window.selectPreviousKeyView(nil)
    var reverse = false
    for _ in 0..<40 {
        panel.window.selectPreviousKeyView(nil)
        if panel.window.firstResponder === slider { reverse = true; break }
    }
    #expect(reverse)
    #expect(panel.window.makeFirstResponder(slider))
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: panel.window.windowNumber, context: nil, characters: "\u{f703}",
        charactersIgnoringModifiers: "\u{f703}", isARepeat: false, keyCode: 124))
    slider.keyDown(with: right)
    #expect(context.store.value.toolBackgroundOpacity > 50 && context.store.value.toolBackgroundOpacity <= 100)
    #expect(slider.doubleValue == context.store.value.toolBackgroundOpacity)
    for (start, increment, result) in [(30.0, true, 31.0), (100, false, 99), (63.5, true, 64.5)] {
        context.store.value.toolBackgroundOpacity = start
        #expect(increment ? slider.accessibilityPerformIncrement() : slider.accessibilityPerformDecrement())
        #expect(context.store.value.toolBackgroundOpacity == result)
    }
    context.store.value.toolBackgroundOpacity = 30
    #expect(!slider.accessibilityPerformDecrement())
    expectValue(30, text: "30%")
    context.store.value.toolBackgroundOpacity = 100
    #expect(!slider.accessibilityPerformIncrement())
    expectValue(100, text: "100%")
    context.store.value.toolBackgroundOpacity = 63.5
    expectValue(63.5, text: "63.5%")
    panel.select(.general)
    let before = context.store.value
    #expect(!slider.isAccessibilityElement() && !slider.canBecomeKeyView && !slider.acceptsFirstResponder)
    #expect(!slider.accessibilityPerformIncrement() && !slider.accessibilityPerformDecrement())
    #expect(context.store.value == before)
    panel.select(.display)
    #expect(slider.isAccessibilityElement() && slider.canBecomeKeyView)
    expectValue(63.5, text: "63.5%")
}

/// Lay out the full actual field content with its native cell's wrapping and line cap.
/// Checking glyph coverage and truncation separately prevents an ellipsis from looking like a fit.
@MainActor private func issue351ExpectFullTextFits(_ field: NSTextField) throws {
    let cell = try #require(field.cell as? NSTextFieldCell)
    let font = try #require(field.font)
    let drawing = cell.drawingRect(forBounds: field.bounds)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = field.alignment
    paragraph.lineBreakMode = field.lineBreakMode
    let text = NSTextStorage(string: field.stringValue, attributes: [.font: font, .paragraphStyle: paragraph])
    let layout = NSLayoutManager()
    let container = NSTextContainer(size: drawing.size)
    container.lineFragmentPadding = 0
    container.maximumNumberOfLines = cell.usesSingleLineMode ? 1 : field.maximumNumberOfLines
    container.lineBreakMode = field.lineBreakMode
    text.addLayoutManager(layout)
    layout.addTextContainer(container)
    layout.ensureLayout(for: container)
    let glyphs = layout.glyphRange(for: container)
    #expect(!field.stringValue.isEmpty)
    #expect(glyphs.location == 0 && glyphs.length == layout.numberOfGlyphs,
            "All characters must fit the actual native text frame")
    var truncated = false
    layout.enumerateLineFragments(forGlyphRange: glyphs) { _, _, _, lineGlyphs, _ in
        if layout.truncatedGlyphRange(inLineFragmentForGlyphAt: lineGlyphs.location).location != NSNotFound {
            truncated = true
        }
    }
    #expect(!truncated, "No truncation token may replace full localized text")
    let used = layout.usedRect(for: container)
    #expect(used.width <= drawing.width + 1 && used.height <= drawing.height + 1)
}

@MainActor private func issue351CatalogStrings() throws -> [String: Any] {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    return try #require(catalog["strings"] as? [String: Any])
}

@MainActor private func issue351Translation(_ key: String, locale: String, strings: [String: Any]) throws -> String {
    let entry = try #require(strings[key] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    let localization = try #require(localizations[locale] as? [String: Any])
    let unit = try #require(localization["stringUnit"] as? [String: Any])
    return try #require(unit["value"] as? String)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue351SettingsDisplayRowsKeepColumnsAndFullLocalizedLabels() async throws {
    let context = try await Issue351AppContext()
    defer { context.close() }
    let panel = context.panel()
    let pane = try issue351Control("settings.pane.display", in: panel.window.contentView, as: NSView.self)
    let keysAndControls = [("Thumbnail Size", "settings.display.size"),
                           ("Show File Names", "settings.display.names"),
                           ("Thumbnails", "settings.display.fit.0"),
                           ("Tool Background Opacity", "settings.display.tool-opacity")]
    let rows = try keysAndControls.map { key, id -> (String, NSTextField, NSControl) in
        let matching = pane.subviews.compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == String(localized: String.LocalizationValue(key)) }
        #expect(matching.count == 1, "Each Display row has exactly one full label")
        return (key, try #require(matching.first), try issue351Control(id, in: pane, as: NSControl.self))
    }
    #expect(rows.count == 4)
    let strings = try issue351CatalogStrings()
    let originalAXLabel = rows[3].2.accessibilityLabel()
    #expect(originalAXLabel == String(localized: "Tool Background Opacity"))
    for locale in ["en", "zh-Hans"] {
        // Exercise the supported catalog text on real native fields without altering layout configuration.
        // This is native text/layout coverage, not a separate localized-process launch.
        for (key, label, _) in rows { label.stringValue = try issue351Translation(key, locale: locale, strings: strings) }
        for activation in 0..<2 {
            if activation == 1 { panel.select(.general); panel.select(.display) }
            panel.window.contentView?.layoutSubtreeIfNeeded()
            let sizeLabel = rows[0].1.convert(rows[0].1.bounds, to: nil)
            let sizeControl = rows[0].2.convert(rows[0].2.bounds, to: nil)
            for (key, label, control) in rows {
                #expect(!label.isHiddenOrHasHiddenAncestor && !control.isHiddenOrHasHiddenAncestor)
                #expect(label.stringValue == (try issue351Translation(key, locale: locale, strings: strings)))
                let labelFrame = label.convert(label.bounds, to: nil)
                let controlFrame = control.convert(control.bounds, to: nil)
                #expect(abs(labelFrame.minX - sizeLabel.minX) <= 1)
                #expect(abs(labelFrame.maxX - sizeLabel.maxX) <= 1,
                        "Every right-aligned label must end at the shared label column")
                #expect(abs(controlFrame.minX - sizeControl.minX) <= 1,
                        "Every Display row's first control must start at the Thumbnail Size column")
                try issue351ExpectFullTextFits(label)
                #expect(pane.bounds.contains(label.frame) && pane.bounds.contains(control.frame))
                #expect(!label.frame.intersects(control.frame))
                for sibling in pane.subviews where sibling !== label && sibling !== control {
                    #expect(!sibling.frame.intersects(label.frame), "A full row label must not overlap another view")
                }
            }
            #expect(rows[3].2.accessibilityLabel() == originalAXLabel)
        }
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue351SettingsEnglishAndChineseOpacityLabelsFitRealFrames() async throws {
    let context = try await Issue351AppContext()
    defer { context.close() }
    let panel = context.panel()
    let label = try issue351Control("settings.display.tool-opacity.label", in: panel.window.contentView, as: NSTextField.self)
    let slider = try issue351Control("settings.display.tool-opacity", in: panel.window.contentView, as: NSSlider.self)
    let value = try issue351Control("settings.display.tool-opacity.value", in: panel.window.contentView, as: NSTextField.self)
    let catalogURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let catalog = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    let entry = try #require(strings["Tool Background Opacity"] as? [String: Any])
    let translations = try #require(entry["localizations"] as? [String: Any])
    let originalLabel = label.stringValue
    defer { label.stringValue = originalLabel }
    #expect(label.stringValue == String(localized: "Tool Background Opacity"))
    for (locale, expected) in [("en", "Tool Background Opacity"), ("zh-Hans", "工具背景不透明度")] {
        let localization = try #require(translations[locale] as? [String: Any])
        let unit = try #require(localization["stringUnit"] as? [String: Any])
        #expect(unit["value"] as? String == expected)
        label.stringValue = expected
        try issue351ExpectFullTextFits(label)
    }
    let pane = try #require(label.superview)
    #expect(pane.bounds.contains(label.frame) && pane.bounds.contains(slider.frame) && pane.bounds.contains(value.frame))
    #expect(!label.frame.intersects(slider.frame) && !slider.frame.intersects(value.frame) && !label.frame.intersects(value.frame))
    for text in ["30%", "50%", "63.5%", "100%"] {
        #expect(ceil((text as NSString).size(withAttributes: [.font: try #require(value.font)]).width) + 4 <= value.frame.width)
    }
    for sibling in pane.subviews where sibling !== label && sibling !== slider && sibling !== value {
        #expect(!sibling.frame.intersects(label.frame) && !sibling.frame.intersects(slider.frame) && !sibling.frame.intersects(value.frame))
    }
}
