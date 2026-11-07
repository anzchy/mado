import Foundation

/// The app's version and build as read from its Info.plist; nil when a value is missing, not a string, or empty.
public struct AppVersionInfo: Equatable, Sendable {
    public let version: String?
    public let build: String?

    public init(infoDictionary: [String: Any]) {
        version = Self.nonEmptyString(infoDictionary["CFBundleShortVersionString"])
        build = Self.nonEmptyString(infoDictionary["CFBundleVersion"])
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

/// Settings → Updates talks to the updater only through this port; the Sparkle adapter lives in the App target.
@MainActor public protocol AppUpdatePort: AnyObject {
    var versionInfo: AppVersionInfo { get }
    /// Whether this build has an updater, independent of readiness to check right now.
    var isAvailable: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    /// False while the updater cannot start a user-initiated check (for example, a background check is running).
    var canCheckForUpdates: Bool { get }
    func checkForUpdates()
    /// Starts the updater; the App calls it once, after the first window is front, so Sparkle's permission question opens on top.
    func start()
    /// Calls `onChange` after the updater's state may have changed (an update cycle finished, or a setting changed elsewhere).
    func observe(_ onChange: @escaping @MainActor () -> Void)
}
