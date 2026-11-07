import CryptoKit
import Foundation
import Testing

/// #354 owner decision: expired keeps one action; other page-26 states are unchanged.
@Test func i354ExpiredDesignKeepsOnlyReselectAction() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../..").standardizedFileURL
    let directory = root.appendingPathComponent("design/prototypes/picsee-browser/states")
    let page = try Data(contentsOf: directory.appendingPathComponent("permission-denied.html"))
    let html = try #require(String(data: page, encoding: .utf8))
    let bare = html.components(separatedBy: "<template")[0]
    #expect(try i354Actions(bare) == ["重新选择文件夹…"])
    for (id, expected) in [("missing", ["在新位置选择…", "选择其他文件夹…"]),
                           ("unknown", ["重新选择文件夹…", "选择其他文件夹…"]),
                           ("volume", ["选择其他文件夹…"])] {
        let marker = "<template id=\"case-\(id)\">"
        let start = try #require(html.range(of: marker))
        let rest = String(html[start.upperBound...])
        let state = try #require(rest.components(separatedBy: "</template>").first)
        #expect(try i354Actions(state) == expected)
    }
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
    let catalog = try #require(manifest as? [String: Any])
    let states = try #require(catalog["states"] as? [[String: Any]])
    let pin = try #require(states.first { $0["name"] as? String == "permission-denied" }?["sha256"] as? String)
    #expect(pin == SHA256.hash(data: page).map { String(format: "%02x", $0) }.joined())
}

private func i354Actions(_ html: String) throws -> [String] {
    let marker = try #require(html.range(of: "<div class=\"mock-actions\">"))
    let rest = String(html[marker.upperBound...])
    let section = try #require(rest.components(separatedBy: "</div>").first)
    let pattern = try NSRegularExpression(pattern: "<button\\b[^>]*>(.*?)</button>")
    return pattern.matches(in: section, range: NSRange(section.startIndex..., in: section)).compactMap { match in
        Range(match.range(at: 1), in: section).map { String(section[$0]) }
    }
}
