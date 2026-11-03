import Foundation
import Testing

private struct CatalogLocalization: Decodable {
    struct Unit: Decodable { let value: String? }
    let stringUnit: Unit?
}
private struct CatalogRecord: Decodable {
    let localizations: [String: CatalogLocalization]?
}
private struct StatesCatalog: Decodable {
    let strings: [String: CatalogRecord]
    func value(_ key: String, _ language: String) -> String? {
        strings[key]?.localizations?[language]?.stringUnit?.value
    }
}
private func statesCatalog() throws -> StatesCatalog {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    return try JSONDecoder().decode(StatesCatalog.self, from: data)
}

private let statesLocalizationKeys = [
    "Open a folder to start browsing", "Images stay on your Mac. Browse by folder.",
    "Choose Folder…", "Opening %@…", "Unable to read this image",
    "The file may be damaged or its format unreadable.", "This image format is not supported.",
    "This image exceeds the available resources.", "The file changed again while it was being opened.",
    "Access to this image is unavailable.", "Showing reduced detail", "Next",
    "File", "Edit", "View", "Window", "About Picsee", "Hide Picsee", "Hide Others", "Show All",
    "Quit Picsee", "Undo", "Redo", "Cut", "Copy", "Paste", "Select All", "Minimize", "Zoom",
    "Bring All to Front", "Fit", "Actual Pixels", "Zoom In", "Zoom Out", "Open…",
    "Show Inspector", "Hide Inspector", "Focus Canvas", "Inspector Placeholder",
    "Cancel", "Retry", "Close", "Open Recent", "Always Show Tools", "Zoom mode", "Fit window",
    "Previous Image", "Next Image", "Previous image", "Next image", "Zoom in", "Zoom out",
    "Show image information", "Hide image information", "More browse actions", "Return to grid", "Show sidebar", "Hide sidebar", "Open folder", "Enter Full Screen", "Exit Full Screen", "Component Preview",
    "This File Can’t Be Opened", "“%@” isn’t a supported image format.",
    "None of These Files Can Be Opened", "None of the dropped or opened files is a supported image.",
    "You can also drop images or folders here.",
    "Open One Folder at a Time", "Drop or open a single folder to continue.",
    "No Recent Folders", "canvas.image",
    "Reading Folder…", "Looking for images to browse. Please wait.", "Cancel Reading"
]

@Test func statesLocalizationUsedKeysAreBilingual() throws {
    let catalog = try statesCatalog()
    for key in statesLocalizationKeys {
        #expect(catalog.value(key, "en")?.isEmpty == false, "English translation required for \(key)")
        #expect(catalog.value(key, "zh-Hans")?.isEmpty == false, "Chinese translation required for \(key)")
        #expect(catalog.value(key, "zh-Hans") != key, "Chinese must not display the English key: \(key)")
    }
}

@Test func statesLocalizationPageWordingAndFilenamePlaceholder() throws {
    let catalog = try statesCatalog()
    #expect(catalog.value("Open a folder to start browsing", "zh-Hans") == "打开一个文件夹，开始浏览")
    #expect(catalog.value("Images stay on your Mac. Browse by folder.", "zh-Hans") == "图片留在本地，按文件夹浏览。")
    #expect(catalog.value("Choose Folder…", "zh-Hans") == "选择文件夹…")
    #expect(catalog.value("Unable to read this image", "zh-Hans") == "无法读取这张图片")
    #expect(catalog.value("The file may be damaged or its format unreadable.", "zh-Hans") == "文件可能已损坏或当前格式不可读取。")
    #expect(catalog.value("Retry", "zh-Hans") == "重试")
    #expect(catalog.value("Next", "zh-Hans") == "下一张")
    #expect(catalog.value("Opening %@…", "en") == "Opening %@…")
    #expect(catalog.value("Opening %@…", "zh-Hans") == "正在打开 %@…")
    for language in ["en", "zh-Hans"] {
        let format = try #require(catalog.value("Opening %@…", language))
        #expect(format.components(separatedBy: "%@").count - 1 == 1)
    }
}

@Test func statesLocalizationAllCatalogEntriesRemainBilingual() throws {
    let catalog = try statesCatalog()
    #expect(!catalog.strings.isEmpty)
    for key in catalog.strings.keys {
        #expect(catalog.value(key, "en")?.isEmpty == false, "English translation required for \(key)")
        #expect(catalog.value(key, "zh-Hans")?.isEmpty == false, "Chinese translation required for \(key)")
    }
}

@Test func gridLocalizationDoesNotFallBackToEnglishForVisibleAndAXText() throws {
    let catalog = try statesCatalog()
    let expected = [
        "Thumbnail pending": "缩略图待生成",
        "thumbnail pending": "缩略图待生成",
        "Selected": "已选中",
        "Preview Selected Image": "预览所选图片",
        "Open Selected Image": "打开所选图片"
    ]
    for (key, chinese) in expected {
        #expect(catalog.value(key, "en") == key)
        #expect(catalog.value(key, "zh-Hans") == chinese)
        #expect(catalog.value(key, "zh-Hans") != key)
    }
}

@Test func issue215ReleaseSurfaceCatalogCopyMatchesBothLanguagesExactly() throws {
    let catalog = try statesCatalog()
    let expected = [
        "Coming Soon": "即将推出",
        "Personal Favorites": "个人收藏",
        "Recently Viewed": "最近查看",
        "Show Image Information": "显示图片信息",
        "Display and Appearance": "显示与外观",
        "Help": "帮助",
        "Report a Problem…": "报告问题…",
        "Keyboard Shortcuts": "键盘快捷键",
        "Diagnostics": "诊断信息",
    ]
    for (english, chinese) in expected {
        #expect(catalog.value(english, "en") == english)
        #expect(catalog.value(english, "zh-Hans") == chinese)
    }
}

@Test func gridCurrentItemAccessibilityValueIsBilingual() throws {
    let catalog = try statesCatalog()
    let expected = ["Current": "当前", "Selected, Current": "已选中，当前", "Selected": "已选中"]
    for (english, chinese) in expected {
        #expect(catalog.value(english, "en") == english)
        #expect(catalog.value(english, "zh-Hans") == chinese)
    }
}
