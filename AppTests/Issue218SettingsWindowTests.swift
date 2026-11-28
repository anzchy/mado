import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private func settingsFixture() -> (SettingsPanelWindow, InMemoryDisplayPreferencesStore, UserDefaults) {
    let preferences = InMemoryDisplayPreferencesStore()
    let defaults = UserDefaults(suiteName: "issue218-\(UUID().uuidString)")!
    let cache = ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    let panel = SettingsPanelWindow(cache: cache, appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
                                    preferencesStore: preferences, defaults: defaults)
    return (panel, preferences, defaults)
}

@MainActor private func settingsView(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = settingsView(id, in: child) { return found }
    }
    return nil
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218PinnedSettingsSidebarRenderedFrames() throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    root.layoutSubtreeIfNeeded()
    let sidebar = try #require(settingsView("settings.sidebar", in: root))
    let content = try #require(settingsView("settings.content", in: root))
    // settings.html: .window 760x520, .split 180px 1fr, sidebar padding 10px 8px,
    // rows 30px with 2px gap. Native titlebar occupies 38pt.
    #expect(abs(panel.window.frame.width - 760) < 1)
    #expect(abs(sidebar.frame.width - 180) < 1)
    #expect(abs(content.frame.width - 580) < 1)
    let general = try #require(settingsView("settings.section.general", in: root))
    let display = try #require(settingsView("settings.section.display", in: root))
    #expect(abs(general.frame.minX - 8) < 1)
    #expect(abs(sidebar.frame.maxY - general.frame.maxY - 10) < 1)
    #expect(abs(general.frame.height - 30) < 1)
    #expect(abs(general.frame.minY - display.frame.minY - 32) < 1)
    let pane = try #require(settingsView("settings.pane.general", in: root))
    let heading = try #require(pane.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(abs(heading.frame.minX - 26) < 1)
    #expect(abs(pane.frame.maxY - heading.frame.maxY - 18) < 1)
    #expect(abs((heading.font?.pointSize ?? 0) - 16) < 1)
}

// State 35: 10 pt inside each 164 pt row, 16 pt icon, 8 pt gap, 30 pt rows, 2 pt pitch.
@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue863SettingsSidebarMetricsInBothLanguages(_ locale: String) throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let sidebar = try #require(settingsView("settings.sidebar", in: root))
    let titles = locale == "zh-Hans" ? ["通用", "显示", "缓存", "截图", "更新", "关于"]
                                     : ["General", "Display", "Cache", "Screenshots", "Updates", "About"]
    for (index, section) in SettingsSection.allCases.enumerated() {
        panel.select(section)
        let row = try #require(settingsView("settings.section.\(section.rawValue)", in: root) as? NSButton)
        let icon = try #require(settingsView("settings.sidebar.icon.\(section.rawValue)", in: root))
        let text = try #require(settingsView("settings.sidebar.label.\(section.rawValue)", in: root) as? NSTextField)
        text.stringValue = titles[index] // Frames are independent of language; check both real string widths.
        row.layoutSubtreeIfNeeded()
        #expect(row.state == .on)
        #expect(abs(row.frame.minX - 8) < 0.5)
        #expect(abs(row.frame.height - 30) < 0.5)
        #expect(abs(icon.frame.minX - 10) < 0.5)
        #expect(abs(icon.frame.width - 16) < 0.5)
        #expect(abs(icon.frame.height - 16) < 0.5)
        #expect(abs(text.frame.minX - icon.frame.maxX - 6) < 0.5) // glyph ink begins ~2 pt inside the text field
        #expect(text.intrinsicContentSize.width <= text.frame.width - 4)
        #expect(row.bounds.contains(icon.frame) && row.bounds.contains(text.frame))
        if index > 0 {
            let previous = try #require(settingsView("settings.section.\(SettingsSection.allCases[index - 1].rawValue)", in: root))
            #expect(abs(previous.frame.minY - row.frame.maxY - 2) < 0.5)
        }
        #expect(row.frame.minY >= sidebar.bounds.minY)
    }
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        panel.window.appearance = NSAppearance(named: appearance)
        panel.select(.general)
        let selected = try #require(settingsView("settings.section.general", in: root) as? NSButton)
        let unselected = try #require(settingsView("settings.section.display", in: root) as? NSButton)
        #expect(selected.state == .on && unselected.state == .off)
        for row in [selected, unselected] {
            let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
            let title = try #require(row.subviews.compactMap { $0 as? NSTextField }.first)
            #expect(abs(title.frame.minX - icon.frame.maxX - 6) < 0.5)
            #expect(row.bounds.contains(icon.frame) && row.bounds.contains(title.frame))
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218SettingsSectionPersistsAcrossWindowInstances() {
    let (first, _, defaults) = settingsFixture()
    for section in SettingsSection.allCases {
        first.select(section)
        #expect(first.selectedSection == section)
        let preferences = InMemoryDisplayPreferencesStore()
        let second = SettingsPanelWindow(cache: ThumbnailDiskCache(),
            appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
            preferencesStore: preferences, defaults: defaults)
        #expect(second.selectedSection == section)
        second.window.close()
    }
    defaults.set("future-unknown-section", forKey: "settings.selectedSection.v1")
    let preferences = InMemoryDisplayPreferencesStore()
    let fallback = SettingsPanelWindow(cache: ThumbnailDiskCache(),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences, defaults: defaults)
    #expect(fallback.selectedSection == .general)
    first.window.close()
    fallback.window.close()
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue863Fix1SidebarFocusRingCoversTheWholeRow() throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let row = try #require(settingsView("settings.section.general", in: root) as? NSButton)
    #expect(row.focusRingMaskBounds == row.bounds)
}

// Browser state 35 measured in Chromium at the fixed 760×520 window: pane h=482,
// heading top=18, form first-row top=57, and grid row gap=14.
@MainActor @Test(.timeLimit(.minutes(3))) func issue863Fix1SettingsPaneSpacingMatchesState35() throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    func pane(_ section: SettingsSection) throws -> NSView {
        try #require(settingsView("settings.pane.\(section.rawValue)", in: root))
    }
    func label(_ title: String, in section: SettingsSection) throws -> NSTextField {
        try #require(try pane(section).subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == title })
    }
    func top(_ view: NSView, in section: SettingsSection) throws -> CGFloat {
        let container = try pane(section)
        return container.bounds.maxY - view.convert(view.bounds, to: container).maxY
    }
    let rows: [(SettingsSection, String, CGFloat)] = [
        (.general, String(localized: "Appearance"), 57),
        (.general, String(localized: "Image Tools"), 99),
        (.general, String(localized: "Language"), 172),
        (.display, String(localized: "Thumbnail Size"), 57),
        (.display, String(localized: "Show File Names"), 95),
        (.display, String(localized: "Thumbnails"), 133),
        (.cache, String(localized: "Thumbnail Cache"), 57),
        (.update, String(localized: "Current Version"), 57),
        (.update, String(localized: "Auto Check"), 95),
    ]
    for (section, title, expected) in rows {
        let field = try label(title, in: section)
        let measured = try top(field, in: section)
        print("i863 pane \(section.rawValue) \(title) top=\(measured) x=\(field.frame.minX) width=\(field.frame.width)")
        #expect(abs(measured - expected) < 0.5, "\(section.rawValue) \(title): \(measured) vs CSS \(expected)")
        #expect(abs(field.frame.minX - 26) < 0.5 && abs(field.frame.width - 120) < 0.5)
    }
    let about = try pane(.about)
    let icon = try #require(about.subviews.compactMap { $0 as? NSImageView }.first)
    let iconTop = try top(icon, in: .about)
    print("i863 pane about icon top=\(iconTop) x=\(icon.frame.minX) size=\(icon.frame.size)")
    #expect(abs(iconTop - 57) < 0.5)
    let captureFirst = try #require(settingsView("settings.capture.enabled.title", in: root))
    print("i863 pane capture first-label top=\(try top(captureFirst, in: .capture))")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue863Fix1SidebarDrawnTextGapAndCenter() throws {
    let (panel, _, _) = settingsFixture()
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    for section in SettingsSection.allCases {
        let row = try #require(settingsView("settings.section.\(section.rawValue)", in: root) as? NSButton)
        let icon = try #require(settingsView("settings.sidebar.icon.\(section.rawValue)", in: root))
        let title = try #require(settingsView("settings.sidebar.label.\(section.rawValue)", in: root) as? NSTextField)
        if section == .general {
            let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 40,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 240, height: 40).fill(using: .copy)
            NSAffineTransform(transform: AffineTransform(scale: 2)).concat()
            title.cell?.drawInterior(withFrame: title.bounds, in: title)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            var minX = 240, minY = 40, maxY = -1
            for y in 0..<40 { for x in 0..<240 {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                    minX = min(minX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            } }
            #expect(maxY >= minY)
            let visibleGap = title.frame.minX + CGFloat(minX) / 2 - icon.frame.maxX
            let verticalOffset = title.frame.minY + CGFloat(minY + maxY) / 4 - icon.frame.midY
            print("i863 sidebar visibleGap=\(visibleGap) verticalOffset=\(verticalOffset)")
            #expect(abs(visibleGap - 8) < 1)
            #expect(abs(verticalOffset) < 1)
        }
        #expect(row.bounds.contains(title.frame))
    }
}
