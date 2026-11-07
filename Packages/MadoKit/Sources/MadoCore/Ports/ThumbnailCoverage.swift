import Foundation

/// The pixel tile a thumbnail fills under aspect-fill. ImageIO bounds the long side, so the decode edge
/// depends on the source's oriented aspect ratio.
public struct ThumbnailCoverage: Equatable, Sendable {
    public let width: Double
    public let height: Double
    public let ceiling: Int
    public init(width: Double, height: Double, ceiling: Int = 1024) {
        self.width = width; self.height = height; self.ceiling = ceiling
    }
    /// Used only when the ratio is unknown: twice the tile's long side covers ratios up to 2:1.
    public var fallbackEdge: Int {
        let longest = max(width, height)
        guard longest.isFinite, longest > 0, ceiling > 0 else { return 0 }
        return min(ceiling, max(1, Int(ceil(min(longest * 2, Double(ceiling))))))
    }
    /// The smallest long-side edge whose output (short side rounded down) fills the tile, for an upright source size.
    /// Never above the ceiling or the source's own long side; the fallback when the ratio is unknown.
    public func edge(sourceWidth: Double, sourceHeight: Double) -> Int {
        guard fallbackEdge > 0, sourceWidth.isFinite, sourceHeight.isFinite, sourceWidth > 0, sourceHeight > 0 else {
            return fallbackEdge
        }
        let long = max(sourceWidth, sourceHeight), short = min(sourceWidth, sourceHeight)
        let (alongLong, alongShort) = sourceWidth >= sourceHeight
            ? (width.rounded(.up), height.rounded(.up)) : (height.rounded(.up), width.rounded(.up))
        let limit = min(Double(ceiling), long.rounded(.down))
        // The short side is ⌊edge·short/long⌋, so it reaches alongShort once edge ≥ alongShort·long/short.
        var edge = min(limit, max(alongLong, (alongShort * long / short).rounded(.up)))
        while edge > 1, edge - 1 >= alongLong, ((edge - 1) * short / long).rounded(.down) >= alongShort { edge -= 1 }
        while edge < limit, (edge * short / long).rounded(.down) < alongShort { edge += 1 }
        return max(1, Int(edge))
    }
}

/// A pipeline that reads the source header before it chooses the request's edge.
public protocol CoverageRequesting: Sendable {
    func request(for fileURL: URL, covering: ThumbnailCoverage, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest
}
