import Foundation
import MadoApplication

/// The Capture Folder record in the App Group defaults (#685). The helper writes it; Settings reads the display path
/// and the fallback flag. The bookmark is the helper's own and only the helper can resolve it.
public final class UserDefaultsCaptureFolderPreferences: CaptureFolderPreferencePort, @unchecked Sendable {
    public static let bookmarkKey = "capture.folder.bookmark.v1"
    public static let displayKey = "capture.folder.display.v1"
    public static let fallbackKey = "capture.folder.fallback.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The shared suite; nil only when the App Group is unavailable.
    public static func shared() -> UserDefaultsCaptureFolderPreferences? {
        UserDefaults(suiteName: CaptureBarIdentity.appGroupID).map(UserDefaultsCaptureFolderPreferences.init(defaults:))
    }

    public func folderRecord() async -> CaptureFolderRecord {
        defaults.synchronize()
        return CaptureFolderRecord(bookmark: defaults.data(forKey: Self.bookmarkKey),
                                   display: defaults.string(forKey: Self.displayKey) ?? CaptureFolderRecord.downloads.display,
                                   fellBack: defaults.bool(forKey: Self.fallbackKey))
    }

    public func setFolderRecord(_ record: CaptureFolderRecord) async {
        defaults.set(record.bookmark, forKey: Self.bookmarkKey)
        defaults.set(record.display, forKey: Self.displayKey)
        defaults.set(record.fellBack, forKey: Self.fallbackKey)
        defaults.synchronize()
    }
}
