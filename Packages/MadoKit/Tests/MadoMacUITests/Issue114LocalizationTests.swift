import Foundation
import Testing

/// #114: every page-15 panel and Settings 显示 string ships in English and Simplified Chinese.
@Test func issue114StringsPanelAndSettingsKeysBilingual() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    func value(_ key: String, _ language: String) -> String? {
        let entry = strings[key] as? [String: Any]
        let localized = (entry?["localizations"] as? [String: Any])?[language] as? [String: Any]
        let unit = localized?["stringUnit"] as? [String: Any]
        return unit?["state"] as? String == "translated" ? unit?["value"] as? String : nil
    }
    let expected = [
        "Close Display Panel": "关闭显示面板", "Display and Appearance": "显示与外观", "Thumbnail Size": "缩略图大小",
        "Show File Names": "显示文件名", "Thumbnails": "缩略图", "Fill and Crop": "填充裁剪", "Fit Entire Image": "完整显示",
    ]
    for (key, chinese) in expected {
        #expect(value(key, "en") == key, "en \(key)")
        #expect(value(key, "zh-Hans") == chinese, "zh-Hans \(key)")
    }
    let names = try #require(value("Show names below thumbnails", "zh-Hans"))
    #expect(!names.isEmpty && names != "Show names below thumbnails")
    let panel = try String(contentsOf: root.appendingPathComponent(
        "Packages/MadoKit/Sources/MadoMacUI/Grid/GridDisplayPanelView.swift"), encoding: .utf8)
    let keys = try Regex(#"String\(localized: "([^"]+)"\)"#)
    let used = Set(panel.matches(of: keys).compactMap { $0.output[1].substring.map(String.init) })
    #expect(!used.isEmpty)
    for key in used {
        #expect(value(key, "en")?.isEmpty == false, "en \(key)")
        #expect(value(key, "zh-Hans")?.isEmpty == false, "zh-Hans \(key)")
    }
}
