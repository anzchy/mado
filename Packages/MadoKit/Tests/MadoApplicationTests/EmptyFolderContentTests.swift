import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private struct ContentRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

private let contentNow = Date(timeIntervalSince1970: 1_615_809_600) // 2021-03-15T12:00:00Z
private var utcGregorian: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}
private func recents(_ content: EmptyFolderContent?) -> [EmptyFolderRecentRow]? {
    if case .recents(let rows)? = content { return rows }
    return nil
}
private func key(_ folder: RecentFolder) -> (Date, String, String) {
    (folder.openedAt, folder.url.path, folder.rootID.rawValue.uuidString)
}
/// Strictly before in the page order: newest first, then path, then root ID.
private func before(_ a: RecentFolder, _ b: RecentFolder) -> Bool {
    let (ka, kb) = (key(a), key(b))
    if ka.0 != kb.0 { return ka.0 > kb.0 }
    return (ka.1, ka.2) < (kb.1, kb.2)
}

@Test func emptyFolderContentRecentsOrderedCappedIdempotent() throws {
    var random = ContentRandom(seed: 0x10)
    let dates = (0..<6).map { contentNow.addingTimeInterval(-Double($0) * 86_400) }
    let paths = (0..<50).map { "/recent/folder-\($0)" }
    func make(_ input: [RecentFolder]) -> [EmptyFolderRecentRow]? {
        recents(EmptyFolderContent.make(subfolders: [], recents: input, now: contentNow,
            locale: Locale(identifier: "en_US"), calendar: utcGregorian))
    }
    for sample in 0..<200 {
        let input = (0..<random.below(41)).map { _ -> RecentFolder in
            let bytes = (0..<16).map { _ in UInt8(truncatingIfNeeded: random.next()) }
            let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
            let path = paths[random.below(paths.count)]
            return RecentFolder(rootID: AccessRootID(rawValue: uuid), url: URL(fileURLWithPath: path),
                displayName: (path as NSString).lastPathComponent, openedAt: dates[random.below(dates.count)])
        }
        let label = "seed 0x10 sample \(sample) n \(input.count)"
        let rows = try #require(make(input), "\(label): recents case")
        let kept = rows.map(\.folder)
        #expect(rows.count == min(input.count, 10), "\(label): cap")
        for (a, b) in zip(kept, kept.dropFirst()) { #expect(before(a, b), "\(label): strict order") }
        var remaining = input
        for folder in kept {
            let index = try #require(remaining.firstIndex(of: folder), "\(label): kept folder comes from the input")
            remaining.remove(at: index)
        }
        if let last = kept.last {
            for excluded in remaining { #expect(!before(excluded, last), "\(label): top-k prefix") }
        }
        #expect(make(input.shuffled(using: &random)) == rows, "\(label): permutation")
        #expect(make(kept) == rows, "\(label): idempotent")
    }
}

@Test func emptyFolderContentChoosesSubfoldersOverRecents() throws {
    let recent = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/Trip"), displayName: "Trip",
        openedAt: contentNow.addingTimeInterval(-86_400))
    func make(_ subfolders: [URL], _ recents: [RecentFolder]) -> EmptyFolderContent {
        EmptyFolderContent.make(subfolders: subfolders, recents: recents, now: contentNow,
            locale: Locale(identifier: "en_US"), calendar: utcGregorian)
    }
    let folder = URL(fileURLWithPath: "/A")
    #expect(make([], []) == .recents([]))
    let row = try #require(recents(make([], [recent]))?.first)
    #expect(make([], [recent]) == .recents([row]) && row.folder == recent)
    #expect(make([folder.appendingPathComponent("2024 冲绳")], [recent]) == .subfolders(["2024 冲绳"]))
    let three = ["手机备份", "2024 冲绳", "扫描件"].map { folder.appendingPathComponent($0) }
    #expect(make(three, []) == .subfolders(["手机备份", "2024 冲绳", "扫描件"]))
}

@Test func recentRelativeTimeUsesInjectedClockAndLocale() throws {
    for identifier in ["en_US", "zh-Hans"] {
        let locale = Locale(identifier: identifier), calendar = utcGregorian
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale; formatter.calendar = calendar
        formatter.dateTimeStyle = .named; formatter.unitsStyle = .full
        for days in [1, 3, 8] {
            let opened = contentNow.addingTimeInterval(-Double(days) * 86_400)
            let folder = RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/r/\(days)"),
                displayName: "\(days)", openedAt: opened)
            let row = try #require(recents(EmptyFolderContent.make(subfolders: [], recents: [folder],
                now: contentNow, locale: locale, calendar: calendar))?.first)
            #expect(row.relativeTime == formatter.localizedString(for: opened, relativeTo: contentNow),
                "\(identifier) −\(days) days")
            if days == 1 { #expect(row.relativeTime == (identifier == "en_US" ? "yesterday" : "昨天")) }
        }
    }
}
