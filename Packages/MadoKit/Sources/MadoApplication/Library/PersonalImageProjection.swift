import Foundation
import MadoCore

/// What the sidebar's Personal Favorites and Recently Viewed sections and the grid's heart marker read.
/// Rows keep the store's order. A count is nil until the store has loaded and every row in its section
/// is resolved; it then counts present rows only, so missing or revoked rows never inflate it.
public struct PersonalImageProjection: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public let ref: PersonalImageRef
        /// Nil for favorites.
        public let viewedAt: Date?
        /// Nil until resolved.
        public let availability: PersonalImageAvailability?
        public var itemID: ItemID { ref.itemID }
    }
    public let favorites: [Row]
    public let recents: [Row]
    public let favoriteCount: Int?
    public let recentCount: Int?
    private let favoriteItems: Set<ItemID>

    /// Before the store has loaded: no rows and unknown counts.
    public init() {
        favorites = []; recents = []; favoriteCount = nil; recentCount = nil; favoriteItems = []
    }
    public init(favorites: [PersonalImageRef], recents: [PersonalImageVisit],
                availability: [PersonalImageRef: PersonalImageAvailability]) {
        self.favorites = favorites.map { Row(ref: $0, viewedAt: nil, availability: availability[$0]) }
        self.recents = recents.map { Row(ref: $0.ref, viewedAt: $0.viewedAt, availability: availability[$0.ref]) }
        favoriteCount = Self.count(self.favorites)
        recentCount = Self.count(self.recents)
        favoriteItems = Set(favorites.map(\.itemID))
    }
    /// The grid cell's heart marker.
    public func isFavorite(_ item: ItemID) -> Bool { favoriteItems.contains(item) }

    private static func count(_ rows: [Row]) -> Int? {
        var present = 0
        for row in rows {
            switch row.availability {
            case nil: return nil
            case .present: present += 1
            case .missing, .revoked: break
            }
        }
        return present
    }
}
