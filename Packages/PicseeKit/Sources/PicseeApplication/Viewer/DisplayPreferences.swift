import PicseeCore

public enum DisplayAppearance: String, Codable, Sendable {
    case system, light, dark
}

/// App-level display preferences. Search and per-folder extension filters are transient.
public struct DisplayPreferences: Codable, Equatable, Sendable {
    public var loopThroughImages: Bool = false
    public var alwaysShowTools: Bool
    public var filmstripExpanded: Bool
    public var appearance: DisplayAppearance
    public var gridSidebarWidth: Double
    public var gridSidebarVisible: Bool
    public var folderSort: FolderSortKey
    public var folderSortDirection: FolderSortDirection
    public init(alwaysShowTools: Bool = false, filmstripExpanded: Bool = false, appearance: DisplayAppearance = .system,
                gridSidebarWidth: Double = 196, gridSidebarVisible: Bool = true) {
        self.alwaysShowTools = alwaysShowTools
        self.filmstripExpanded = filmstripExpanded
        self.appearance = appearance
        self.gridSidebarWidth = Self.normalizedSidebarWidth(gridSidebarWidth)
        self.gridSidebarVisible = gridSidebarVisible
        self.folderSort = .name
        self.folderSortDirection = .ascending
    }

    private enum CodingKeys: String, CodingKey {
        case alwaysShowTools, filmstripExpanded, appearance, gridSidebarWidth, gridSidebarVisible
        case folderSort, folderSortDirection, loopThroughImages
    }

    public static func normalizedSidebarWidth(_ width: Double) -> Double {
        width.isFinite ? min(320, max(160, width)) : 196
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(alwaysShowTools, forKey: .alwaysShowTools)
        try values.encode(filmstripExpanded, forKey: .filmstripExpanded)
        try values.encode(appearance, forKey: .appearance)
        try values.encode(gridSidebarWidth, forKey: .gridSidebarWidth)
        try values.encode(gridSidebarVisible, forKey: .gridSidebarVisible)
        // Omit defaults to keep existing preference encodings stable.
        if folderSort != .name { try values.encode(folderSort, forKey: .folderSort) }
        if folderSortDirection != .ascending { try values.encode(folderSortDirection, forKey: .folderSortDirection) }
        if loopThroughImages { try values.encode(loopThroughImages, forKey: .loopThroughImages) }
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        alwaysShowTools = try values.decode(Bool.self, forKey: .alwaysShowTools)
        filmstripExpanded = try values.decode(Bool.self, forKey: .filmstripExpanded)
        appearance = DisplayAppearance(rawValue: try values.decodeIfPresent(String.self, forKey: .appearance) ?? "") ?? .system
        gridSidebarWidth = Self.normalizedSidebarWidth((try? values.decode(Double.self, forKey: .gridSidebarWidth)) ?? 196)
        gridSidebarVisible = (try? values.decode(Bool.self, forKey: .gridSidebarVisible)) ?? true
        folderSort = (try? values.decode(FolderSortKey.self, forKey: .folderSort)) ?? .name
        folderSortDirection = (try? values.decode(FolderSortDirection.self, forKey: .folderSortDirection)) ?? .ascending
        loopThroughImages = (try? values.decode(Bool.self, forKey: .loopThroughImages)) ?? false
    }
}

@MainActor public protocol DisplayPreferencesObserver: AnyObject {
    func preferencesDidChange(_ preferences: DisplayPreferences)
}

@MainActor public protocol DisplayPreferencesStore: AnyObject {
    var value: DisplayPreferences { get set }
    func observe(_ observer: any DisplayPreferencesObserver)
}

/// In-memory preferences for tests and callers that do not need persistence.
@MainActor public final class InMemoryDisplayPreferencesStore: DisplayPreferencesStore {
    private struct WeakObserver {
        weak var value: (any DisplayPreferencesObserver)?
    }
    private var observers: [WeakObserver] = []
    private var storedValue: DisplayPreferences
    public var value: DisplayPreferences {
        get { storedValue }
        set {
            var normalized = newValue
            normalized.gridSidebarWidth = DisplayPreferences.normalizedSidebarWidth(normalized.gridSidebarWidth)
            storedValue = normalized
            observers.removeAll { $0.value == nil }
            for observer in observers { observer.value?.preferencesDidChange(normalized) }
        }
    }
    public func observe(_ observer: any DisplayPreferencesObserver) {
        observers.append(WeakObserver(value: observer))
    }
    public init(_ value: DisplayPreferences = .init()) { storedValue = value }
}
