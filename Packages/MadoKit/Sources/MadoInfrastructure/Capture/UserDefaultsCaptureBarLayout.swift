import CoreGraphics
import Foundation
import MadoApplication

/// The Capture Bar's position per display arrangement and its collapsed state (#685), kept by the helper.
public final class UserDefaultsCaptureBarLayout: CaptureBarLayoutPort, @unchecked Sendable {
    public static let originsKey = "capture.barOrigins.v1"
    public static let collapsedKey = "capture.barCollapsed.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func origin(forArrangement key: String) async -> CGPoint? {
        defaults.synchronize()
        guard let pair = defaults.dictionary(forKey: Self.originsKey)?[key] as? [Double], pair.count == 2 else { return nil }
        return CGPoint(x: pair[0], y: pair[1])
    }

    public func setOrigin(_ origin: CGPoint, forArrangement key: String) async {
        var origins = defaults.dictionary(forKey: Self.originsKey) ?? [:]
        origins[key] = [Double(origin.x), Double(origin.y)]
        defaults.set(origins, forKey: Self.originsKey)
        defaults.synchronize()
    }

    public func isCollapsed() async -> Bool {
        defaults.synchronize()
        return defaults.bool(forKey: Self.collapsedKey)
    }

    public func setCollapsed(_ collapsed: Bool) async {
        defaults.set(collapsed, forKey: Self.collapsedKey)
        defaults.synchronize()
    }
}
