import AppKit
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure
import PicseeMacUI

@MainActor private func settingsControl(_ id: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == id { return view }
    for child in view.subviews {
        if let found = settingsControl(id, in: child) { return found }
    }
    return nil
}

@MainActor @Test func issue218DisplaySectionControlsAreLiveAndSelectingWritesNothing() throws {
    let preferences = InMemoryDisplayPreferencesStore()
    let defaults = UserDefaults(suiteName: "issue218-future-\(UUID().uuidString)")!
    let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences, defaults: defaults)
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let futureIDs: [(SettingsSection, [String])] = [
        (.display, ["settings.display.size", "settings.display.names", "settings.display.fit.0", "settings.display.fit.1"]),
    ]
    for (section, ids) in futureIDs {
        panel.select(section)
        for id in ids {
            let control = try #require(settingsControl(id, in: root) as? NSControl)
            // #114 (owner: 「两者都做，共用一组偏好」): Settings 显示 is real now — visible, enabled, no Coming Soon marker;
            // selecting the section alone still writes nothing.
            #expect(!control.isHidden && !control.isHiddenOrHasHiddenAncestor)
            #expect(control.isEnabled)
            #expect(control.accessibilityLabel()?.contains(String(localized: "Coming Soon")) == false)
            #expect(control.window?.firstResponder !== control)
        }
    }
    #expect(preferences.value == DisplayPreferences())
}

@MainActor @Test func issue218SettingsTextFitsPinnedContentFrames() throws {
    let preferences = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue218-text-\(UUID().uuidString)")!)
    defer { panel.window.close() }
    let root = try #require(panel.window.contentView)
    let content = try #require(settingsControl("settings.content", in: root))
    func inspect(_ view: NSView) {
        if let field = view as? NSTextField, !field.stringValue.isEmpty {
            let height = field.attributedStringValue.boundingRect(
                with: NSSize(width: field.frame.width, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            #expect(height <= field.frame.height + 2, "Clipped Settings label: \(field.stringValue)")
        }
        view.subviews.forEach(inspect)
    }
    for section in SettingsSection.allCases {
        panel.select(section)
        inspect(content)
    }
}

@MainActor @Test func issue218CommandCommaReusesSettingsWindow() throws {
    _ = NSApplication.shared
    let preferences = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue218-menu-\(UUID().uuidString)")!)
    let previousMenu = NSApp.mainMenu
    let menu = CommandMenu(preferencesStore: preferences, openWithoutWindow: {},
                           openSettings: { panel.show() }, openDiagnostics: {})
    defer { panel.window.close(); NSApp.mainMenu = previousMenu; withExtendedLifetime(menu) {} }
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
        timestamp: 0, windowNumber: panel.window.windowNumber, context: nil, characters: ",",
        charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43))
    let mainMenu = try #require(NSApp.mainMenu)
    #expect(mainMenu.performKeyEquivalent(with: event))
    #expect(panel.window.isVisible)
    let first = panel.window
    #expect(mainMenu.performKeyEquivalent(with: event))
    #expect(panel.window === first)
    #expect(NSApp.windows.filter { $0 === first }.count == 1)
}

@MainActor @Test func issue218PinnedSidebarSurfaceInLightAndDark() throws {
    let preferences = InMemoryDisplayPreferencesStore()
    let panel = SettingsPanelWindow(cache: ThumbnailDiskCache(),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue218-color-\(UUID().uuidString)")!)
    defer { panel.window.close() }
    let windowContent = try #require(panel.window.contentView)
    let sidebar = try #require(settingsControl("settings.sidebar", in: windowContent))
    let general = try #require(settingsControl("settings.section.general", in: windowContent))
    for (appearance, expected, selection) in [(NSAppearance.Name.aqua, [246, 247, 251], [37, 99, 235]),
                                               (.darkAqua, [22, 26, 34], [96, 165, 250])] {
        panel.window.appearance = NSAppearance(named: appearance)
        sidebar.needsDisplay = true
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(sidebar.bounds.width * 2), pixelsHigh: Int(sidebar.bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = sidebar.bounds.size // 2 backing pixels per point in the destination context.
        sidebar.cacheDisplay(in: sidebar.bounds, to: bitmap)
        #expect(bitmap.colorSpaceName == .calibratedRGB)
        let backingScale = CGFloat(bitmap.pixelsWide) / sidebar.bounds.width
        #expect(backingScale == 2)
        let outputSpace = NSColorSpace.genericRGB
        func convertedCSS(_ bytes: [Int]) throws -> [CGFloat] {
            let color = NSColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255,
                                blue: CGFloat(bytes[2]) / 255, alpha: 1)
            let output = try #require(color.usingColorSpace(outputSpace))
            return [output.redComponent, output.greenComponent, output.blueComponent]
        }
        let color = try #require(bitmap.colorAt(x: Int(4 * backingScale), y: Int(4 * backingScale)))
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        for (actual, value) in zip(channels, try convertedCSS(expected)) {
            #expect(abs(actual - value) < 0.02,
                    "appearance=\(appearance.rawValue) sampled=\(channels) expected=\(expected)")
        }
        // settings.html: selected row is --color-accent at 14%/22% over --color-surface.
        // NSBitmapImageRep rows start at the top; NSView frames use the bottom-left origin.
        let selectedRow = Int((sidebar.bounds.height - general.frame.midY) * backingScale)
        let selected = try #require(bitmap.colorAt(x: Int(156 * backingScale), y: selectedRow))
        // AppKit composites in the bitmap working space: convert each CSS color before blending.
        let alpha: CGFloat = appearance == .darkAqua ? 0.22 : 0.14
        let foreground = try convertedCSS(selection)
        let background = try convertedCSS(expected)
        let composited = zip(foreground, background).map { $0 * alpha + $1 * (1 - alpha) }
        for (actual, value) in zip([selected.redComponent, selected.greenComponent, selected.blueComponent], composited) {
            #expect(abs(actual - value) < 0.04,
                    "appearance=\(appearance.rawValue) selected row does not match pinned accent soft")
        }
        // Pinned selected-row text/icon is accent blue; background alone cannot satisfy this.
        var accentForegroundPixels = 0
        let top = Int((sidebar.bounds.height - general.frame.maxY + 4) * backingScale)
        let bottom = Int((sidebar.bounds.height - general.frame.minY - 4) * backingScale)
        for y in top..<bottom {
            for x in Int(16 * backingScale)..<Int(140 * backingScale) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                   color.blueComponent - color.redComponent > 0.35 {
                    accentForegroundPixels += 1
                }
            }
        }
        #expect(accentForegroundPixels > 4, "Selected sidebar foreground must use pinned accent text in \(appearance.rawValue)")
    }
}

@MainActor @Test func issue218LongestCatalogLabelsFitPinnedColumnsInEnglishAndChinese() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let data = try Data(contentsOf: file)
    let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(root["strings"] as? [String: Any])
    let cases: [(String, CGFloat, CGFloat)] = [
        ("Follows the system language (Chinese / English). Set a language for picsee in System Settings → General → Language & Region.", 390, 67),
        ("Only thumbnails created by picsee are deleted. Your images are untouched. Confirm before clearing; thumbnails are rebuilt while browsing.", 390, 45),
        ("picsee is released under the MIT License.\nThird party: Sparkle (MIT) · Welcome sample images from Unsplash (Unsplash License).", 440, 52)
    ]
    for (key, width, height) in cases {
        let entry = try #require(strings[key] as? [String: Any])
        let translations = try #require(entry["localizations"] as? [String: Any])
        for language in ["en", "zh-Hans"] {
            let localized = try #require(translations[language] as? [String: Any])
            let unit = try #require(localized["stringUnit"] as? [String: Any])
            let value = try #require(unit["value"] as? String)
            let text = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            let needed = text.boundingRect(with: NSSize(width: width, height: 1000),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            #expect(needed <= height + 2, "\(language) clipped: \(key)")
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue218CacheClearRequiresConfirmation() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let imageURL = folder.appendingPathComponent("image.png")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try Data(contentsOf: fixture).write(to: imageURL)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: imageURL, maximumPixelSize: 128, identityRoot: root)
    let image = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: folder.appendingPathComponent("cache"))
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(image, for: ticket)
    let initialBytes = try await cache.sizeBytes()
    #expect(initialBytes > 0)
    let preferences = InMemoryDisplayPreferencesStore()
    var confirm = false
    var prompts = 0
    let panel = SettingsPanelWindow(cache: cache,
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue218-cache-\(UUID().uuidString)")!,
        confirmClear: { _, completion in prompts += 1; completion(confirm) })
    defer { panel.window.close() }
    panel.select(.cache)
    let windowContent = try #require(panel.window.contentView)
    let size = try #require(settingsControl("settings.cache.size", in: windowContent) as? NSTextField)
    let measuredLabel = ByteCountFormatter.string(fromByteCount: initialBytes, countStyle: .file)
    await waitUntil { size.stringValue == measuredLabel }
    #expect(size.stringValue == measuredLabel)
    let clear = try #require(settingsControl("settings.cache.clear", in: windowContent) as? NSButton)
    clear.performClick(nil)
    #expect(prompts == 1)
    #expect(try await cache.sizeBytes() == initialBytes)
    #expect(size.stringValue == measuredLabel)
    confirm = true
    clear.performClick(nil)
    try await waitUntil { try await cache.sizeBytes() == 0 }
    #expect(prompts == 2)
    #expect(try await cache.sizeBytes() == 0)
    let emptyLabel = ByteCountFormatter.string(fromByteCount: 0, countStyle: .file)
    await waitUntil { size.stringValue == emptyLabel }
    #expect(size.stringValue == emptyLabel)
}
