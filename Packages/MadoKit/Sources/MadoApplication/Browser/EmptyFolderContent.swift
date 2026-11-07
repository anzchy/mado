import Foundation
import MadoCore

public struct EmptyFolderRecentRow: Equatable, Sendable {
    public let folder: RecentFolder
    public let relativeTime: String
}

/// Page 22 (22-BD, ADR-014): subfolder names when the folder has any, else at most 10 recents, newest first.
public enum EmptyFolderContent: Equatable, Sendable {
    case subfolders([String])
    case recents([EmptyFolderRecentRow])
    public static func make(subfolders: [URL], recents: [RecentFolder], now: Date,
                            locale: Locale, calendar: Calendar) -> EmptyFolderContent {
        guard subfolders.isEmpty else { return .subfolders(subfolders.map(\.lastPathComponent)) }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale; formatter.calendar = calendar
        formatter.dateTimeStyle = .named; formatter.unitsStyle = .full
        let ordered = recents.sorted {
            if $0.openedAt != $1.openedAt { return $0.openedAt > $1.openedAt }
            return ($0.url.path, $0.rootID.rawValue.uuidString) < ($1.url.path, $1.rootID.rawValue.uuidString)
        }
        return .recents(ordered.prefix(10).map {
            EmptyFolderRecentRow(folder: $0, relativeTime: formatter.localizedString(for: $0.openedAt, relativeTo: now))
        })
    }
}
