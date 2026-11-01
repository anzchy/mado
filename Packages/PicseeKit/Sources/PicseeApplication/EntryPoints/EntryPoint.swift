import Foundation

public enum EntryPointState: String, CaseIterable, Sendable {
    case implemented
    case comingSoon
}

public enum EntryPointLanguage: Sendable {
    case english
    case simplifiedChinese

    public init(preferredLocalization: String?) {
        self = preferredLocalization?.hasPrefix("zh") == true ? .simplifiedChinese : .english
    }

    public static var preferred: EntryPointLanguage {
        EntryPointLanguage(preferredLocalization: Bundle.main.preferredLocalizations.first)
    }
}

public enum EntryPoint: String, CaseIterable, Sendable {
    public static let reportIssueURL = URL(string: "https://github.com/anzchy/picsee/issues/new?template=bug_report.yml")!
    public static let settingsAboutPrivacyNoteURL = URL(string: "https://github.com/anzchy/picsee#%E9%9A%90%E7%A7%81")!
    public static let settingsAboutSourceCodeURL = URL(string: "https://github.com/anzchy/picsee")!

    case reportIssue
    case diagnostics
    case keyboardShortcuts
    case contextMenu
    case filmstrip
    case favorites
    case recents
    case footerInfo
    case footerDisplay
    case settingsDisplayThumbnailSize
    case settingsDisplayFileNames
    case settingsDisplayFitMode
    case settingsUpdatesAutomaticCheck
    case settingsUpdatesCheckNow
    case settingsAboutPrivacyNote
    case settingsAboutSourceCode

    public var state: EntryPointState {
        switch self {
        case .reportIssue, .diagnostics, .keyboardShortcuts,
             .settingsUpdatesAutomaticCheck, .settingsUpdatesCheckNow,
             .settingsAboutPrivacyNote, .settingsAboutSourceCode, .footerDisplay: .implemented
        case .contextMenu, .filmstrip, .favorites, .recents, .footerInfo,
             .settingsDisplayThumbnailSize, .settingsDisplayFileNames, .settingsDisplayFitMode: .comingSoon
        }
    }
    public var isEnabled: Bool { state == .implemented }
    public var isFocusable: Bool { state == .implemented }
    public var keyEquivalent: String? { nil }
    public func accessibilityLabel(for language: EntryPointLanguage) -> String {
        guard state == .comingSoon else { return "" }
        return switch language {
        case .english: "Coming Soon"
        case .simplifiedChinese: "即将推出"
        }
    }
}
