import Foundation
import Testing

private struct RecoveryCatalog: Decodable {
    struct Record: Decodable {
        struct Translation: Decodable {
            struct Unit: Decodable { let value: String }
            let stringUnit: Unit?
        }
        let localizations: [String: Translation]?
    }
    let strings: [String: Record]
    func value(_ key: String, language: String) -> String? {
        strings[key]?.localizations?[language]?.stringUnit?.value
    }
}

private func recoveryCatalog() throws -> RecoveryCatalog {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    return try JSONDecoder().decode(RecoveryCatalog.self, from: data)
}

@Test func p201RecoveryCatalogCopyMatchesBothLanguagesExactly() throws {
    let catalog = try recoveryCatalog()
    let copy = [
        ("Can’t Access This Folder", "无法访问这个文件夹"),
        ("Access may have expired. Choose “%@” again.", "访问权限可能已失效，请重新选择“%@”。"),
        ("Choose Folder Again…", "重新选择文件夹…"),
        ("Choose Another Folder…", "选择其他文件夹…"),
        ("Reconnect Folder", "重新连接文件夹"),
        ("Cancel", "取消")
    ]
    for (english, chinese) in copy {
        #expect(catalog.value(english, language: "en") == english)
        #expect(catalog.value(english, language: "zh-Hans") == chinese)
    }
}

@Test(arguments: ["en", "zh-Hans"], ["Holiday 2026", "100% Photos"])
func p201RecoveryCatalogFormatsFolderNameWithoutInterpretingItsPercent(language: String, name: String) throws {
    let catalog = try recoveryCatalog()
    let format = try #require(catalog.value("Access may have expired. Choose “%@” again.", language: language))
    #expect(format.components(separatedBy: "%@").count - 1 == 1)
    let expected = language == "en"
        ? "Access may have expired. Choose “\(name)” again."
        : "访问权限可能已失效，请重新选择“\(name)”。"
    #expect(String(format: format, name) == expected)
}

@Test func t229Page26CatalogUsesOnlyObservedCauseAndPinnedChineseCopy() throws {
    let catalog = try recoveryCatalog()
    let copy = [
        ("Unable to Access This Folder", "无法访问此文件夹"),
        ("External Disk Is Not Connected", "外接磁盘未连接"),
        ("External Disk “%@” Is Not Connected", "外接磁盘“%@”未连接"),
        ("“%@” is on an external disk.\nConnect the disk and Mado will verify access before restoring your place.",
         "“%@”在外接磁盘上。\n连接磁盘后，Mado 会重新确认访问权限，然后自动恢复。"),
        ("Mado can’t read “%@” right now. Choose this folder again, or choose another folder to continue.",
         "Mado 现在读不到“%@”。重新选择这个文件夹，或换一个文件夹继续。"),
        ("Waiting for the disk…", "等待磁盘连接…"),
        ("Folder Access Restored", "文件夹访问已恢复")
    ]
    for (english, chinese) in copy {
        let actualEnglish = catalog.value(english, language: "en")
        let actualChinese = catalog.value(english, language: "zh-Hans")
        #expect(actualEnglish == english)
        #expect(actualChinese == chinese)
        if english.contains("%@") {
            let format = try #require(catalog.value(english, language: "zh-Hans"))
            #expect(String(format: format, "100% Photos").contains("100% Photos"))
        }
    }
}
