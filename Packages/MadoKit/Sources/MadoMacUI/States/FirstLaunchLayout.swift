import AppKit

/// Image Wall geometry from pinned page 21 (`.wall .tiles`). Coordinates are AppKit's bottom-left system:
/// `box` is the unrotated tiles box in wall coordinates, tile frames are in box coordinates.
struct FirstLaunchLayout {
    struct Tile: Equatable { let row: Int; let column: Int; let sample: String; let frame: NSRect }
    struct Wall: Equatable { let box: NSRect; let tiles: [Tile] }
    static let sampleNames = ["alley", "lakeside", "hillside", "gate", "temple", "lakehouse"]
    static let tileCount = 60, columns = 6
    static let rowHeight: CGFloat = 340, gap: CGFloat = 22, oddColumnDrop: CGFloat = 110
    static let side: CGFloat = 0.18, top: CGFloat = 0.6, height: CGFloat = 2.2
    /// CSS `rotate(-9deg)` in the page's downward Y axis; AppKit's upward Y axis reverses the sign.
    static let tiltDegrees: CGFloat = 9

    static func wall(in contentSize: NSSize) -> Wall {
        let w = contentSize.width, h = contentSize.height
        let box = NSRect(x: -side * w, y: h - (height - top) * h, width: (1 + 2 * side) * w, height: height * h)
        let columnWidth = (box.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let tiles = (0..<tileCount).map { index -> Tile in
            let row = index / columns, column = index % columns
            let cssTop = CGFloat(row) * (rowHeight + gap) + (column % 2 == 1 ? oddColumnDrop : 0)
            let frame = NSRect(x: CGFloat(column) * (columnWidth + gap), y: box.height - cssTop - rowHeight,
                               width: columnWidth, height: rowHeight)
            return Tile(row: row, column: column, sample: sampleNames[(column + 2 * row) % sampleNames.count], frame: frame)
        }
        return Wall(box: box, tiles: tiles)
    }
}
