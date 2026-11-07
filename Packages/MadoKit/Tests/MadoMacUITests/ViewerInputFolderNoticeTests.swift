import Foundation
import Testing

private struct FolderNoticeCatalog: Decodable {
    struct Record: Decodable {
        struct Localization: Decodable {
            struct Unit: Decodable { let value: String }
            let stringUnit: Unit?
        }
        let localizations: [String: Localization]?
    }
    let strings: [String: Record]
    func value(_ key: String, _ language: String) -> String? { strings[key]?.localizations?[language]?.stringUnit?.value }
}

@Test func inputFoldersNoticeCatalogExactBilingualValues() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let catalog = try JSONDecoder().decode(FolderNoticeCatalog.self,
        from: Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings")))
    let values = [
        ("Open One Folder at a Time", "Open One Folder at a Time", "请一次打开一个文件夹"),
        ("Drop or open a single folder to continue.", "Drop or open a single folder to continue.", "请拖入或打开单个文件夹以继续。")
    ]
    for (key, en, zh) in values {
        #expect(catalog.value(key, "en") == en)
        #expect(catalog.value(key, "zh-Hans") == zh)
    }
    #expect(catalog.value("None of the dropped or opened files is a supported image.", "en") == "None of the dropped or opened files is a supported image.")
    #expect(catalog.value("None of the dropped or opened files is a supported image.", "zh-Hans") == "拖入或打开的文件中没有支持的图片。")
}
