import CoreGraphics
import MadoApplication

/// Test-side mirror of `ImageTextSelection` (App) for #688 resolver tests: a position is
/// (line, character offset), the offset comes from character centres along the text axis,
/// and the text is sliced and joined exactly like `selectedText`.
enum RS {
    struct Position: Comparable, Equatable, CustomStringConvertible {
        let line: Int
        let offset: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.line == rhs.line ? lhs.offset < rhs.offset : lhs.line < rhs.line
        }
        var description: String { "(\(line),\(offset))" }
    }

    static func r(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> CGRect {
        CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Uniform per-Character cells along the axis, in reading order (ascending coordinate).
    static func uniformCells(_ rect: CGRect, count: Int, axis: TextRowResolver.Axis) -> [CGRect] {
        (0..<count).map { i in
            let step = (axis == .horizontal ? rect.width : rect.height) / CGFloat(count)
            return axis == .horizontal
                ? CGRect(x: rect.minX + CGFloat(i) * step, y: rect.minY, width: step, height: rect.height)
                : CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * step, width: rect.width, height: step)
        }
    }

    /// The App's offset rule: first character whose centre is at or past the coordinate.
    static func offset(cells: [CGRect], point: CGPoint, axis: TextRowResolver.Axis) -> Int {
        guard !cells.isEmpty else { return 0 }
        let centres = cells.map { axis == .horizontal ? $0.midX : $0.midY }
        let coordinate = axis == .horizontal ? point.x : point.y
        let ascending = centres.first! <= centres.last!
        return centres.firstIndex { ascending ? coordinate <= $0 : coordinate >= $0 } ?? cells.count
    }

    struct Layout: CustomStringConvertible {
        var rects: [CGRect]
        var texts: [String]
        var axis: TextRowResolver.Axis = .horizontal
        var cells: [[CGRect]]? = nil

        func cellsOf(_ line: Int) -> [CGRect] {
            precondition(cells.map { $0.count == rects.count } ?? true, "cells table out of step with the lines")
            return cells?[line] ?? uniformCells(rects[line], count: texts[line].count, axis: axis)
        }
        /// The same layout with its uniform cells computed once (#787: the property walks asked for them on every drag,
        /// counting each line's characters again). A caller that inserts a line inserts its cells too.
        func withUniformCells() -> Layout {
            var layout = self
            layout.cells = rects.indices.map { cellsOf($0) }
            return layout
        }
        var resolver: TextRowResolver { TextRowResolver(rects: rects, axis: axis) }

        func anchor(_ point: CGPoint, using resolver: TextRowResolver) -> Position? {
            resolver.hitLine(at: point).map {
                Position(line: $0, offset: RS.offset(cells: cellsOf($0), point: point, axis: axis))
            }
        }
        func extent(_ point: CGPoint, anchorLine: Int?, using resolver: TextRowResolver) -> Position? {
            resolver.lineIndex(at: point, anchorLine: anchorLine).map {
                Position(line: $0, offset: RS.offset(cells: cellsOf($0), point: point, axis: axis))
            }
        }
        func text(_ a: Position, _ b: Position) -> String? {
            guard a != b else { return nil }
            let lower = min(a, b), upper = max(a, b)
            return (lower.line...upper.line).map { index in
                let characters = Array(texts[index])
                let start = index == lower.line ? lower.offset : 0
                let end = index == upper.line ? upper.offset : characters.count
                return String(characters[start..<end])
            }.joined(separator: "\n")
        }
        /// begin(at: anchor) + drag(to: end) through the resolver; nil when nothing is selected.
        func select(from anchorPoint: CGPoint, to endPoint: CGPoint) -> String? {
            select(from: anchorPoint, to: endPoint, using: resolver)
        }
        /// The same drag through a resolver already built for this layout (#787: building one is O(n²) in the lines,
        /// so the property walks build it once per layout instead of once per drag; it depends only on rects and axis).
        func select(from anchorPoint: CGPoint, to endPoint: CGPoint, using resolver: TextRowResolver) -> String? {
            guard let a = anchor(anchorPoint, using: resolver),
                  let e = extent(endPoint, anchorLine: a.line, using: resolver) else { return nil }
            return text(a, e)
        }
        var description: String {
            "axis: .\(axis), lines: [" + rects.indices.map { i in
                let r = rects[i]
                return "(\(texts[i].debugDescription), RS.r(\(r.minX), \(r.minY), \(r.maxX), \(r.maxY)))"
            }.joined(separator: ", ") + "]"
        }
    }

    static func normalized(_ rows: [[Int]]) -> [[Int]] {
        rows.map { $0.sorted() }.sorted { ($0.first ?? .max) < ($1.first ?? .max) }
    }
}
