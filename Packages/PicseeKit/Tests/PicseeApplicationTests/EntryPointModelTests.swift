import Testing
import PicseeApplication

@Test func issue215EntryPointLanguageFollowsResolvedBundleLocalization() {
    #expect(EntryPointLanguage(preferredLocalization: "zh-Hans") == .simplifiedChinese)
    #expect(EntryPointLanguage(preferredLocalization: "en") == .english)
    #expect(EntryPointLanguage(preferredLocalization: "fr") == .english)
}

@Test func issue215EntryPointModelCoversEveryReleaseSurfaceEntry() {
    let expectedComingSoon: Set<EntryPoint> = [
        .contextMenu, .filmstrip, .favorites, .recents, .footerInfo,
    ]
    // #220 / ADR-015: the two Settings → Updates controls are real now; #299: so are the About links (#285);
    // #114: the grid footer Display button opens the page-15 popover, and Settings 显示 edits the same three
    // preferences (owner: 「两者都做，共用一组偏好」).
    let implemented: Set<EntryPoint> = [
        .reportIssue, .diagnostics, .keyboardShortcuts, .settingsUpdatesAutomaticCheck, .settingsUpdatesCheckNow,
        .settingsAboutPrivacyNote, .settingsAboutSourceCode, .footerDisplay,
        .settingsDisplayThumbnailSize, .settingsDisplayFileNames, .settingsDisplayFitMode,
    ]
    #expect(Set(EntryPoint.allCases) == expectedComingSoon.union(implemented))
    #expect(Set(EntryPoint.allCases.filter { $0.state == .comingSoon }) == expectedComingSoon)
    #expect(EntryPoint.settingsUpdatesAutomaticCheck.rawValue == "settingsUpdatesAutomaticCheck")
    #expect(EntryPoint.settingsUpdatesCheckNow.rawValue == "settingsUpdatesCheckNow")
    #expect(Set(EntryPoint.allCases.map(\.rawValue)).count == EntryPoint.allCases.count)
    #expect(EntryPoint.reportIssueURL.absoluteString == "https://github.com/anzchy/picsee/issues/new?template=bug_report.yml")

    for entry in EntryPoint.allCases {
        #expect(EntryPointState.allCases.contains(entry.state))
        if expectedComingSoon.contains(entry) {
            #expect(entry.state == .comingSoon)
            #expect(!entry.isEnabled)
            #expect(!entry.isFocusable)
            #expect(entry.keyEquivalent == nil)
            #expect(entry.accessibilityLabel(for: .english) == "Coming Soon")
            #expect(entry.accessibilityLabel(for: .simplifiedChinese) == "即将推出")
        } else {
            #expect(entry.state == .implemented)
            #expect(entry.isEnabled)
            #expect(entry.isFocusable)
            #expect(entry.accessibilityLabel(for: .english) == "")
            #expect(entry.accessibilityLabel(for: .simplifiedChinese) == "")
        }
    }
}
