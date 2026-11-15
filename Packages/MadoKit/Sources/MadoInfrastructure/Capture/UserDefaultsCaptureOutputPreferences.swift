import Foundation
import MadoApplication

/// The 「截图之后」 switches in the App Group defaults Mado and the capture helper share (#684).
/// An unset switch is on. The helper reads them at every Capture, so a change needs no restart.
public final class UserDefaultsCaptureOutputPreferences: CaptureOutputPreferencePort, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static let sharedSuiteName = CaptureBarIdentity.appGroupID

    /// The shared suite; nil only when the App Group is unavailable.
    public static func shared() -> UserDefaultsCaptureOutputPreferences? {
        UserDefaults(suiteName: sharedSuiteName).map(UserDefaultsCaptureOutputPreferences.init(defaults:))
    }

    public func outputPolicy() async -> CaptureOutputPolicy {
        defaults.synchronize()
        return CaptureOutputPolicy(savesToFolder: value(CaptureBarIdentity.saveToFolderKey),
                                   copiesToClipboard: value(CaptureBarIdentity.copyToClipboardKey))
    }

    public func setSavesToFolder(_ enabled: Bool) async {
        defaults.set(enabled, forKey: CaptureBarIdentity.saveToFolderKey)
        defaults.synchronize()
    }

    public func setCopiesToClipboard(_ enabled: Bool) async {
        defaults.set(enabled, forKey: CaptureBarIdentity.copyToClipboardKey)
        defaults.synchronize()
    }

    private func value(_ key: String) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }
}
