import AppKit
import Testing

func captureCatalog(_ locale: String) throws -> [String: String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(json["strings"] as? [String: Any])
    var result: [String: String] = [:]
    for (key, value) in strings {
        guard let item = value as? [String: Any], let localizations = item["localizations"] as? [String: Any],
              let entry = localizations[locale] as? [String: Any],
              let unit = entry["stringUnit"] as? [String: Any], let text = unit["value"] as? String else { continue }
        result[key] = text
    }
    return result
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue682CaptureLabelsUseLocalizedValues() throws {
    let expected: [String: [String: String]] = [
        "en": ["Region Capture": "Region Capture", "Full Screen Capture": "Full Screen Capture"],
        "zh-Hans": ["Region Capture": "区域截图", "Full Screen Capture": "全屏截图"]
    ]
    for locale in ["en", "zh-Hans"] {
        let catalog = try captureCatalog(locale)
        let permissionNote = "On macOS 15 and later, the system may ask again from time to time whether Mado can capture the screen. This is required by macOS; choose Allow to continue taking screenshots."
        let expectedNote = locale == "zh-Hans"
            ? "在 macOS 15 及以后，系统会不定期再次询问是否允许 Mado 截取屏幕。这是系统要求，选择允许即可继续截图。"
            : permissionNote
        #expect(catalog[permissionNote] == expectedNote)
        for (key, value) in expected[locale]! { #expect(catalog[key] == value) }
        let bar = CaptureBarView(localize: { catalog[$0] ?? $0 }, captureAction: {})
        #expect(locale != "zh-Hans" || bar.frame.width == 562)
        let grip = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.grip" } as? NSButton)
        let collapse = try #require(bar.subviews.first { $0.accessibilityIdentifier() == "capture.collapse" } as? NSButton)
        #expect(grip.accessibilityLabel() == catalog["Drag Capture Bar"])
        #expect(collapse.accessibilityLabel() == catalog["Collapse to Menu Bar"])
        for id in ["capture.region", "capture.window", "capture.screen", "capture.text", "capture.mado"] {
            let button = try #require(bar.subviews.first { $0.accessibilityIdentifier() == id } as? NSButton)
            let textWidth = (button.title as NSString).size(withAttributes: [.font: button.font!]).width
            #expect(textWidth + 18 + 6 + 12 <= button.frame.width)
        }
    }
}
