import AppKit
import Testing

// #687 fix r5b F13 (amendment 4): English says "Copied 1 character" and "Copied 2 characters"; zh-Hans is unchanged.
// The App test bundle carries no compiled catalogue (strings resolve to their keys here), so, like the other
// localisation tests, this reads `Localizable.xcstrings` and resolves the plural with English's CLDR rule.

private func fix5bCopiedEntry() throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(json["strings"] as? [String: Any])
    let item = try #require(strings["Copied %lld characters"] as? [String: Any])
    return try #require(item["localizations"] as? [String: Any])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue687Fix5bCopiedCountUsesTheEnglishSingular() throws {
    let localizations = try fix5bCopiedEntry()
    let en = try #require(localizations["en"] as? [String: Any])
    let plural = try #require((en["variations"] as? [String: Any])?["plural"] as? [String: Any],
                              "English has a plural variation")
    func english(_ count: Int) throws -> String {
        let form = try #require(plural[count == 1 ? "one" : "other"] as? [String: Any])
        let value = try #require((form["stringUnit"] as? [String: Any])?["value"] as? String)
        return value.replacingOccurrences(of: "%lld", with: "\(count)")
    }
    #expect(try english(1) == "Copied 1 character")
    #expect(try english(2) == "Copied 2 characters")
    let zh = try #require(localizations["zh-Hans"] as? [String: Any])
    #expect((zh["stringUnit"] as? [String: Any])?["value"] as? String == "已拷贝 %lld 个字符", "zh-Hans is unchanged")
}
