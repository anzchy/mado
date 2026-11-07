import AppKit
public enum DesignMetrics {
    public static let typeSizes: [String: Double] = ["uiSmall": 12, "ui": 13, "uiLarge": 14, "title": 16]
    public static let radii: [String: Double] = ["inner": 4, "control": 6, "popover": 10]
    public static let spacing: [Double] = [4, 8, 12, 16, 24]
    public static let icons: [Double] = [16, 18]
    public static let hitArea: [Double] = [30, 28]
    public static func font(_ role: String, monospaced: Bool = false) -> NSFont {
        let size = typeSizes[role]!
        return monospaced ? .monospacedSystemFont(ofSize: size, weight: .regular) : .systemFont(ofSize: size)
    }
}
public enum DesignSymbol: String, CaseIterable {
    case sidebar, grid, more, previous, next, search, sort, info, folder, favorite, favoriteSelected, zoomIn, zoomOut, filmstrip, close, shortcuts
    public var name: String {
        switch self {
        case .sidebar: "sidebar.left"
        case .grid: "square.grid.2x2"
        case .more: "ellipsis"
        case .previous: "chevron.left"
        case .next: "chevron.right"
        case .search: "magnifyingglass"
        case .sort: "arrow.up.arrow.down"
        case .info: "info.circle"
        case .folder: "folder"
        case .favorite: "heart"
        case .favoriteSelected: "heart.fill"
        case .zoomIn: "plus"
        case .zoomOut: "minus"
        case .filmstrip: "film"
        case .close: "xmark"
        case .shortcuts: "keyboard"
        }
    }
    public var label: String {
        switch self {
        case .sidebar: "Toggle sidebar"
        case .grid: "Return to grid"
        case .more: "More actions"
        case .previous: "Previous image"
        case .next: "Next image"
        case .search: "Search images"
        case .sort: "Sort images"
        case .info: "Show image information"
        case .folder: "Open folder"
        case .favorite: "Add to favorites"
        case .favoriteSelected: "Remove from favorites"
        case .zoomIn: "Zoom in"
        case .zoomOut: "Zoom out"
        case .filmstrip: "Toggle filmstrip"
        case .close: "Close"
        case .shortcuts: "Show keyboard shortcuts"
        }
    }
    public static let fallback = "questionmark.square"
    @MainActor public func image(candidate: String? = nil) -> NSImage {
        NSImage(systemSymbolName: candidate ?? name, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: Self.fallback, accessibilityDescription: label)!
    }
}
