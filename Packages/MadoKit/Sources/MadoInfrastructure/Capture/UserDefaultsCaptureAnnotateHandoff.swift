import Foundation
import MadoApplication

/// #694: the Annotate hand-off record in the App Group defaults the capture helper and Mado already share (the suite
/// the 「截图之后」 switches use). The helper writes it just before it opens a Capture in Mado; Mado takes it when the
/// open arrives. Each side synchronises around its access, as the switches do, so a fresh read sees the other
/// process's write.
public final class UserDefaultsCaptureAnnotateHandoff: CaptureAnnotateHandoffPort, @unchecked Sendable {
    public static let key = "captureAnnotateHandoff"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) { self.defaults = defaults }

    /// The shared suite; nil only when the App Group is unavailable.
    public static func shared() -> UserDefaultsCaptureAnnotateHandoff? {
        UserDefaults(suiteName: CaptureBarIdentity.appGroupID).map(UserDefaultsCaptureAnnotateHandoff.init(defaults:))
    }

    public func write(_ record: CaptureAnnotateHandoffRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: Self.key)
        defaults.synchronize()
    }

    public func clear() {
        defaults.removeObject(forKey: Self.key)
        defaults.synchronize()
    }

    /// Reads and removes the record; anything that does not decode as one is removed and ignored.
    public func take() -> CaptureAnnotateHandoffRecord? {
        defaults.synchronize()
        guard let value = defaults.object(forKey: Self.key) else { return nil }
        clear()
        guard let data = value as? Data else { return nil }
        return try? JSONDecoder().decode(CaptureAnnotateHandoffRecord.self, from: data)
    }
}
