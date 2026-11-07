import AppKit
import Testing
import MadoApplication
import MadoInfrastructure
import MadoMacUI

private struct Issue221AboutViews {
    let pane: NSView
    let icon: NSImageView
    let name: NSTextField
    let version: NSTextField
    let privacy: NSTextField
    let links: [NSButton]
    let licences: NSTextField
}

@MainActor private func issue221Panel(
    info: [String: Any]? = nil,
    openURL: @escaping (URL) -> Void = { _ in },
    localized: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) }
) -> SettingsPanelWindow {
    let preferences = InMemoryDisplayPreferencesStore()
    return SettingsPanelWindow(
        cache: ThumbnailDiskCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
        appearanceAdapter: WindowAppearanceAdapter(preferencesStore: preferences),
        preferencesStore: preferences,
        defaults: UserDefaults(suiteName: "issue221-about-\(UUID().uuidString)")!,
        openURL: openURL,
        aboutInfoDictionary: info,
        aboutLocalizedString: localized)
}

@MainActor private func issue221View(_ id: String, in root: NSView) -> NSView? {
    if root.accessibilityIdentifier() == id { return root }
    for child in root.subviews {
        if let found = issue221View(id, in: child) { return found }
    }
    return nil
}

@MainActor private func issue221AboutViews(
    in panel: SettingsPanelWindow,
    localized: @escaping (String) -> String = { String(localized: String.LocalizationValue($0)) }
) throws -> Issue221AboutViews {
    panel.select(.about)
    let root = try #require(panel.window.contentView)
    root.layoutSubtreeIfNeeded()
    let pane = try #require(issue221View("settings.pane.about", in: root))
    pane.layoutSubtreeIfNeeded()
    let fields = pane.subviews.compactMap { $0 as? NSTextField }
    let icon = try #require(pane.subviews.compactMap { $0 as? NSImageView }.first)
    let name = try #require(fields.first { $0.stringValue == "Mado" })
    let version = try #require(fields.first { $0.stringValue.hasPrefix(localized("Version") + " ") })
    let privacyKey = "A macOS image viewer for files on your disk. Mado collects no data and uploads no images; the sandbox reads only folders you authorize."
    let privacy = try #require(fields.first { $0.stringValue == localized(privacyKey) })
    let licenceKey = "Mado is released under the MIT License.\nThird party: Sparkle (MIT) · Welcome sample images from Unsplash (Unsplash License)."
    let licences = try #require(fields.first { $0.stringValue == localized(licenceKey) })
    let links = try (0...2).map { try #require(issue221View("settings.about.link.\($0)", in: pane) as? NSButton) }
    return Issue221AboutViews(pane: pane, icon: icon, name: name, version: version,
                              privacy: privacy, links: links, licences: licences)
}

private func issue221CatalogValue(_ key: String, _ language: String) throws -> String {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let strings = try #require(root["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any])
    let localizations = try #require(entry["localizations"] as? [String: Any])
    let localized = try #require(localizations[language] as? [String: Any])
    let unit = try #require(localized["stringUnit"] as? [String: Any])
    return try #require(unit["value"] as? String)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221AboutLinksOpenDestinationsAndStayFocusable() throws {
    var openedURLs: [URL] = []
    let panel = issue221Panel(openURL: { openedURLs.append($0) })
    defer { panel.window.close() }
    let views = try issue221AboutViews(in: panel)
    let expectations: [(EntryPoint, URL)] = [
        (.reportIssue, URL(string: "https://github.com/anzchy/mado/issues/new?template=bug_report.yml")!),
        (.settingsAboutPrivacyNote, URL(string: "https://github.com/anzchy/mado#%E9%9A%90%E7%A7%81")!),
        (.settingsAboutSourceCode, URL(string: "https://github.com/anzchy/mado")!),
    ]
    for (index, expected) in expectations.enumerated() {
        let button = views.links[index]
        #expect(button.isEnabled, "settings.about.link.\(index) must be enabled")
        #expect(button.acceptsFirstResponder, "settings.about.link.\(index) must be in the tab order")
        #expect(!button.refusesFirstResponder)
        #expect(button.accessibilityLabel()?.contains(String(localized: "Coming Soon")) == false)
        #expect(panel.entryPoint(for: button) == expected.0)
        button.performClick(nil)
    }
    #expect(openedURLs == expectations.map { $0.1 })
    #expect(!views.pane.subviews.compactMap { $0 as? NSTextField }
        .contains { $0.stringValue == String(localized: "Coming Soon") })
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221AboutVersionAndBuildUseInjectedBundleInfo() throws {
    let panel = issue221Panel(info: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "654"])
    defer { panel.window.close() }
    let views = try issue221AboutViews(in: panel)
    let description = String(format: String(localized: "%@ (build %@)"), "9.8.7", "654")
    #expect(views.version.stringValue == String(localized: "Version") + " " + description)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221AboutLicenceTextMatchesPinnedEnglishAndChinese() throws {
    let key = "Mado is released under the MIT License.\nThird party: Sparkle (MIT) · Welcome sample images from Unsplash (Unsplash License)."
    let english = "Mado is released under the MIT License.\nThird party: Sparkle (MIT) · Welcome sample images from Unsplash (Unsplash License)."
    let chinese = "Mado 以 MIT 许可发布\n第三方：Sparkle（MIT）· 首次打开页样图来自 Unsplash（Unsplash License）"
    #expect(try issue221CatalogValue(key, "en") == english)
    #expect(try issue221CatalogValue(key, "zh-Hans") == chinese)
    let panel = issue221Panel()
    defer { panel.window.close() }
    #expect(try issue221AboutViews(in: panel).licences.stringValue == english)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221PinnedAboutIconTypographyAndParagraphRenderedFrames() throws {
    let panel = issue221Panel()
    defer { panel.window.close() }
    let views = try issue221AboutViews(in: panel)
    // settings.html: .app-icon is 64×64; .about has gap 18px; .app-name is 16px/600.
    #expect(abs(views.icon.frame.width - 64) < 0.5, ".app-icon width")
    #expect(abs(views.icon.frame.height - 64) < 0.5, ".app-icon height")
    #expect(abs(views.name.frame.minX - views.icon.frame.maxX - 18) < 0.5, ".about gap")
    #expect(abs((views.name.font?.pointSize ?? 0) - 16) < 0.5, ".app-name font-size")
    let traits = NSFontManager.shared.traits(of: try #require(views.name.font))
    #expect(traits.contains(.boldFontMask), ".app-name font-weight: 600")
    // settings.html: .about-text p has margin 10px 0 0; .links has margin-top 10px.
    #expect(abs(views.version.frame.minY - views.privacy.frame.maxY - 10) < 0.5,
            ".about-text p margin-top")
    #expect(abs(views.privacy.frame.minY - views.links[0].frame.maxY - 10) < 0.5,
            ".links margin-top")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221PinnedAboutLinkSpacingAndLicenceWidthRenderedFrames() throws {
    let panel = issue221Panel()
    defer { panel.window.close() }
    let views = try issue221AboutViews(in: panel)
    let root = try #require(panel.window.contentView)
    let content = try #require(issue221View("settings.content", in: root))
    // settings.html: .links has gap 14px and .licences has margin-top 12px.
    for index in 1..<views.links.count {
        #expect(abs(views.links[index].frame.minX - views.links[index - 1].frame.maxX - 14) < 0.5,
                ".links gap at \(index)")
    }
    #expect(abs(views.links[0].frame.minY - views.licences.frame.maxY - 12) < 0.5,
            ".licences margin-top")
    // settings.html: .settings-pane horizontal padding is 26px; .app-icon is 64px and .about gap is 18px.
    let expectedWidth = content.frame.width - 2 * 26 - 64 - 18
    #expect(abs(views.licences.frame.width - expectedWidth) < 0.5, ".licences wrapping width")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221PinnedAboutMutedColorsInLightAndDark() throws {
    let panel = issue221Panel()
    defer { panel.window.close() }
    let views = try issue221AboutViews(in: panel)
    // settings.html: .hint uses --color-muted: light #6b7280; dark #9aa4b2.
    let cases: [(String, NSAppearance.Name, [Int])] = [
        ("light", .aqua, [107, 114, 128]),
        ("dark", .darkAqua, [154, 164, 178]),
    ]
    for (name, appearance, bytes) in cases {
        panel.window.appearance = NSAppearance(named: appearance)
        let expected = bytes.map { CGFloat($0) / 255 }
        for field in [views.version, views.privacy, views.licences] {
            var actual: NSColor?
            field.effectiveAppearance.performAsCurrentDrawingAppearance {
                actual = field.textColor?.usingColorSpace(.sRGB)
            }
            let color = try #require(actual, ".hint muted color in \(name)")
            for (channel, value) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                #expect(abs(channel - value) < 0.02, ".hint color in \(name): \(field.stringValue)")
            }
        }
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue221LocalizedAboutControlsFitPaneInEnglishChineseLightAndDark() throws {
    let privacyKey = "A macOS image viewer for files on your disk. Mado collects no data and uploads no images; the sandbox reads only folders you authorize."
    let licenceKey = "Mado is released under the MIT License.\nThird party: Sparkle (MIT) · Welcome sample images from Unsplash (Unsplash License)."
    for language in ["en", "zh-Hans"] {
        let localized: (String) -> String = { key in
            (try? issue221CatalogValue(key, language)) ?? key
        }
        let panel = issue221Panel(
            info: ["CFBundleShortVersionString": "9.8.7", "CFBundleVersion": "654"],
            localized: localized)
        defer { panel.window.close() }
        let views = try issue221AboutViews(in: panel, localized: localized)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            panel.window.appearance = NSAppearance(named: appearance)
            views.pane.layoutSubtreeIfNeeded()
            let versionFormat = String(format: localized("%@ (build %@)"), "9.8.7", "654")
            #expect(views.name.stringValue == "Mado", "\(language) app name")
            #expect(views.version.stringValue == localized("Version") + " " + versionFormat, "\(language) version")
            #expect(views.privacy.stringValue == localized(privacyKey), "\(language) privacy")
            #expect(views.licences.stringValue == localized(licenceKey), "\(language) licences")
            let linkKeys = ["Report a Problem…", "Privacy Note", "Source Code"]
            #expect(views.links.map(\.title) == linkKeys.map(localized), "\(language) links")

            let controls: [NSView] = [views.icon, views.name, views.version, views.privacy]
                + views.links + [views.licences]
            for control in controls {
                #expect(control.superview === views.pane, "\(language) control is not in the real About pane")
                #expect(NSContainsRect(views.pane.bounds, control.frame),
                        "\(language) \(appearance.rawValue) control outside pane: \(control.frame)")
            }
            for first in controls.indices {
                for second in controls.indices where second > first {
                    #expect(!NSIntersectsRect(controls[first].frame, controls[second].frame),
                            "\(language) \(appearance.rawValue) overlap: \(controls[first].frame) / \(controls[second].frame)")
                }
            }
            for field in [views.name, views.version, views.privacy, views.licences] {
                let needed = field.attributedStringValue.boundingRect(
                    with: NSSize(width: field.frame.width, height: 1000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]).height
                #expect(needed <= field.frame.height + 2,
                        "\(language) \(appearance.rawValue) clipped text: \(field.stringValue)")
            }
            for button in views.links {
                #expect(button.attributedTitle.size().width <= button.frame.width + 1,
                        "\(language) \(appearance.rawValue) clipped link: \(button.title)")
            }
        }
    }
}

// #299: the About pane draws its links from the entry-point declarations, so a link that is
// enabled and focusable on screen must be declared implemented, with no 「即将推出」 marker.
@MainActor @Test(.timeLimit(.minutes(3))) func issue299AboutLinkDeclarationsMatchThePaneEnabledState() throws {
    let panel = issue221Panel()
    defer { panel.window.close() }
    let views = try issue221AboutViews(in: panel)
    for (index, button) in views.links.enumerated() {
        let entry = try #require(panel.entryPoint(for: button))
        #expect(button.isEnabled, "settings.about.link.\(index) must be enabled")
        #expect(entry.state == .implemented, "\(entry) is enabled in the About pane but not declared implemented")
        #expect(entry.isEnabled == button.isEnabled, "\(entry) declaration disagrees with the pane")
        #expect(entry.isFocusable == !button.refusesFirstResponder, "\(entry) focusability disagrees with the pane")
        #expect(entry.accessibilityLabel(for: .english).isEmpty)
        #expect(entry.accessibilityLabel(for: .simplifiedChinese).isEmpty)
    }
}
