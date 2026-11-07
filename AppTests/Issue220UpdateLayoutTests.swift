import AppKit
import Testing
import PicseeApplication
import PicseeMacUI

// settings.html ?section=update: .form grid 120px label column + 16px gap (controls at x 162 in the 580pt pane),
// .hint muted ui-sm text, .switch (native checkbox, #218 mapping) and .btn rows at the #218 vertical rhythm.
@MainActor @Test func issue220UpdatePaneMatchesPinnedFrames() throws {
    let panel = issue220Panel(FakeUpdatePort())
    defer { panel.window.close() }
    panel.window.contentView?.layoutSubtreeIfNeeded()
    let pane = try #require(issue220View("settings.pane.update", in: panel))
    func frame(_ id: String) throws -> NSRect { try #require(issue220View(id, in: panel), "missing \(id)").frame }
    func labelFrame(_ text: String) throws -> NSRect {
        try #require(pane.subviews.first { ($0 as? NSTextField)?.stringValue == text }, "missing \(text)").frame
    }
    func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
    for (text, y) in [(String(localized: "Current Version"), 397.0), (String(localized: "Auto Check"), 352.0)] {
        let row = try labelFrame(text)
        #expect(near(row.minX, 26) && near(row.width, 120) && near(row.minY, y), "\(text) \(row)")
    }
    let hint = try labelFrame(String(localized: "Mado contacts GitHub only to check for updates and sends no system information."))
    #expect(near(hint.minX, 162) && near(hint.minY, 310) && near(hint.width, 390), "hint \(hint)")
    let pinned: [(String, CGFloat)] = [
        ("settings.update.version", 397), ("settings.update.automatic", 352),
        ("settings.update.now", 275), ("settings.update.last-checked", 247),
    ]
    for (id, y) in pinned {
        let rect = try frame(id)
        #expect(near(rect.minX, 162) && near(rect.minY, y), "\(id) \(rect)")
    }
    #expect(near(try frame("settings.update.last-checked").width, 390))
    #expect(try frame("settings.update.automatic").maxX <= 554)
    #expect(try frame("settings.update.now").maxX <= 554)
}

@MainActor @Test func issue220LongestUpdateLabelsFitInEnglishAndChinese() throws {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let strings = try #require(root["strings"] as? [String: Any])
    func value(_ key: String, _ language: String) throws -> String {
        let entry = try #require(strings[key] as? [String: Any], "missing key \(key)")
        let localizations = try #require(entry["localizations"] as? [String: Any])
        let unit = try #require((localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any], "\(language) \(key)")
        #expect(unit["state"] as? String == "translated", "\(language) \(key)")
        return try #require(unit["value"] as? String)
    }
    #expect(try value("Last checked: %@", "en") == "Last checked: %@")
    #expect(try value("Last checked: %@", "zh-Hans") == "上次检查：%@")
    // A long abbreviated date at 23:59 in each language.
    let late = try Date("2026-09-30T23:59:00Z", strategy: .iso8601)
    func sample(_ locale: String) -> String {
        late.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: locale),
                                        timeZone: TimeZone(identifier: "UTC")!))
    }
    func height(_ text: String, role: String, width: CGFloat) -> CGFloat {
        let field = NSTextField(labelWithString: text)
        field.font = DesignMetrics.font(role)
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 1000)).height
    }
    for (language, locale) in [("en", "en_US"), ("zh-Hans", "zh_Hans_CN")] {
        for key in ["Current Version", "Auto Check"] {
            let text = try value(key, language)
            #expect(height(text, role: "ui", width: 120) <= 24, "\(language) row label \(key)")
        }
        let hint = try value("Mado contacts GitHub only to check for updates and sends no system information.", language)
        #expect(height(hint, role: "uiSmall", width: 390) <= 36 + 2, "\(language) privacy hint")
        let last = String(format: try value("Last checked: %@", language), sample(locale))
        #expect(height(last, role: "uiSmall", width: 390) <= 24 + 2, "\(language) \(last)")
        for key in ["Check for updates automatically", "Check Now"] {
            let button = key == "Check Now"
                ? NSButton(title: try value(key, language), target: nil, action: nil)
                : NSButton(checkboxWithTitle: try value(key, language), target: nil, action: nil)
            button.font = DesignMetrics.font("ui")
            #expect(162 + button.intrinsicContentSize.width <= 554, "\(language) \(key)")
        }
    }
}

@MainActor @Test func issue220UpdatePaneTextColoursInLightAndDark() throws {
    let panel = issue220Panel(FakeUpdatePort())
    defer { panel.window.close() }
    let version = try #require(issue220View("settings.update.version", in: panel) as? NSTextField)
    let last = try #require(issue220View("settings.update.last-checked", in: panel) as? NSTextField)
    let pane = try #require(issue220View("settings.pane.update", in: panel))
    let hint = try #require(pane.subviews.compactMap { $0 as? NSTextField }.first {
        $0.stringValue == String(localized: "Mado contacts GitHub only to check for updates and sends no system information.")
    })
    #expect(version.textColor == .labelColor)
    #expect(last.textColor == .secondaryLabelColor)
    #expect(hint.textColor == .secondaryLabelColor)
    func resolved(_ color: NSColor, _ name: NSAppearance.Name) -> NSColor? {
        var result: NSColor?
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { result = color.usingColorSpace(.sRGB) }
        return result
    }
    for field in [version, last, hint] {
        let color = try #require(field.textColor)
        let light = try #require(resolved(color, .aqua))
        let dark = try #require(resolved(color, .darkAqua))
        #expect(light != dark, "\(field.stringValue) must follow appearance")
        #expect(light.brightnessComponent < dark.brightnessComponent, "\(field.stringValue) light text is darker")
    }
}
