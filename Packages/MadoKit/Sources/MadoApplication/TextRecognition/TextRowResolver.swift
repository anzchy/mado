import CoreGraphics

/// Decides which recognised line a selection endpoint belongs to (#688, EXT-01).
///
/// Rule (owner: 「同一行内夹到离开的那段、行外按最近的行（先比垂直距离）」):
/// 1. A point inside a line box picks the first such box by index.
/// 2. Otherwise lines are grouped into rows once: two lines are neighbours when their
///    perpendicular overlap is more than half the shorter perpendicular extent. A line that
///    neighbours two lines which are not neighbours of each other is a bridge; bridges never
///    form or join a row. Rows are the connected components of the other lines (all lines
///    when every line is a bridge).
/// 3. The row is the one whose perpendicular band is nearest the point; the inline
///    coordinate plays no part. Ties go to the anchor's row, else to the lower row index.
/// 4. In that row, a member whose inline range covers the point wins. Otherwise the
///    candidates are the member with the largest end before the point and the member with
///    the smallest start after it (extreme edges, so nested boxes are safe).
/// 5. With both candidates, take the one nearer the anchor in reading order; if they
///    straddle the anchor, take the anchor's geometric side.
/// 6. With one candidate (point before or beyond the whole row), take it.
public struct TextRowResolver: Sendable {
    public enum Axis: Sendable { case horizontal, vertical }

    public let rects: [CGRect]
    public let axis: Axis
    /// Member indices of each row, ascending; rows ordered by their smallest member.
    public let rows: [[Int]]
    private let bands: [ClosedRange<CGFloat>]

    public init(rects: [CGRect], axis: Axis) {
        self.rects = rects
        self.axis = axis
        let horizontal = axis == .horizontal
        let low = rects.map { horizontal ? $0.minY : $0.minX }
        let high = rects.map { horizontal ? $0.maxY : $0.maxX }
        let count = rects.count
        var neighbour = Array(repeating: Array(repeating: false, count: count), count: count)
        for i in 0..<count {
            for j in 0..<count where i != j {
                let overlap = min(high[i], high[j]) - max(low[i], low[j])
                neighbour[i][j] = overlap > 0.5 * min(high[i] - low[i], high[j] - low[j])
            }
        }
        let bridges = Set((0..<count).filter { i in
            let around = (0..<count).filter { neighbour[i][$0] }
            return around.contains { j in around.contains { k in j != k && !neighbour[j][k] } }
        })
        let members = bridges.count == count ? Array(0..<count) : (0..<count).filter { !bridges.contains($0) }
        var rowOf = [Int: Int]()
        var rows: [[Int]] = []
        for start in members where rowOf[start] == nil {
            var row = [start]
            rowOf[start] = rows.count
            var next = 0
            while next < row.count {
                for other in members where rowOf[other] == nil && neighbour[row[next]][other] {
                    rowOf[other] = rows.count
                    row.append(other)
                }
                next += 1
            }
            rows.append(row.sorted())
        }
        self.rows = rows
        self.bands = rows.map { row in row.map { low[$0] }.min()!...row.map { high[$0] }.max()! }
    }

    /// The first line whose box contains `point`, by index.
    public func hitLine(at point: CGPoint) -> Int? {
        rects.indices.first { rects[$0].contains(point) }
    }

    /// The line a drag endpoint at `point` resolves to; `nil` only when there are no lines.
    public func lineIndex(at point: CGPoint, anchorLine: Int?) -> Int? {
        guard !rects.isEmpty else { return nil }
        if let hit = hitLine(at: point) { return hit }
        let anchor = anchorLine.flatMap { rects.indices.contains($0) ? $0 : nil }
        let u = along(point), v = perpendicular(point)
        func distance(_ band: ClosedRange<CGFloat>) -> CGFloat {
            max(band.lowerBound - v, 0, v - band.upperBound)
        }
        let row = rows[rows.indices.min { lhs, rhs in
            let left = distance(bands[lhs]), right = distance(bands[rhs])
            if left != right { return left < right }
            let leftAnchor = anchor.map(rows[lhs].contains) ?? false
            let rightAnchor = anchor.map(rows[rhs].contains) ?? false
            if leftAnchor != rightAnchor { return leftAnchor }
            return lhs < rhs
        }!]
        let covering = row.filter { alongMin($0) <= u && u <= alongMax($0) }
        if let member = covering.min(by: { (ownDistance($0, v), $0) < (ownDistance($1, v), $1) }) {
            return member
        }
        let before = row.filter { alongMax($0) < u }.min { (-alongMax($0), $0) < (-alongMax($1), $1) }
        let after = row.filter { alongMin($0) > u }.min { (alongMin($0), $0) < (alongMin($1), $1) }
        guard let before else { return after }
        guard let after else { return before }
        guard let anchor else { return before }
        if before >= anchor && after >= anchor { return min(before, after) }
        if before <= anchor && after <= anchor { return max(before, after) }
        return (alongMin(anchor) + alongMax(anchor)) / 2 < u ? before : after
    }

    private func along(_ point: CGPoint) -> CGFloat { axis == .horizontal ? point.x : point.y }
    private func perpendicular(_ point: CGPoint) -> CGFloat { axis == .horizontal ? point.y : point.x }
    private func alongMin(_ i: Int) -> CGFloat { axis == .horizontal ? rects[i].minX : rects[i].minY }
    private func alongMax(_ i: Int) -> CGFloat { axis == .horizontal ? rects[i].maxX : rects[i].maxY }
    private func ownDistance(_ i: Int, _ v: CGFloat) -> CGFloat {
        let low = axis == .horizontal ? rects[i].minY : rects[i].minX
        let high = axis == .horizontal ? rects[i].maxY : rects[i].maxX
        return max(low - v, 0, v - high)
    }
}
