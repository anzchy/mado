import AppKit
import MadoApplication
import MadoCore

/// Pure selection geometry. The viewer currently supplies the drawn image's own orientation.
struct ImageTextGeometry {
    var transform: CanvasTransform
    var imageSize: CGSize
    var quarterTurns = 0
    var flipHorizontal = false
    var flipVertical = false

    func viewPoint(_ normalized: CGPoint) -> CGPoint {
        var x = normalized.x, y = 1 - normalized.y
        if flipHorizontal { x = 1 - x }
        if flipVertical { y = 1 - y }
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: (x, y) = (1 - y, x)
        case 2: (x, y) = (1 - x, 1 - y)
        case 3: (x, y) = (y, 1 - x)
        default: break
        }
        let size = quarterTurns.isMultiple(of: 2) ? imageSize : CGSize(width: imageSize.height, height: imageSize.width)
        return transform.imageToView(CGPoint(x: x * size.width, y: y * size.height))
    }

    func viewRect(_ box: CGRect) -> CGRect {
        let points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                      CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)].map(viewPoint)
        return CGRect(x: points.map(\.x).min() ?? 0, y: points.map(\.y).min() ?? 0,
                      width: (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0),
                      height: (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0))
    }
}

@MainActor final class ImageTextSelection {
    struct Position: Comparable {
        let line: Int
        let offset: Int
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.line == rhs.line ? lhs.offset < rhs.offset : lhs.line < rhs.line
        }
    }
    var lines: [TextRecognitionLine] = [] { didSet { clear() } }
    var geometry = ImageTextGeometry(transform: CanvasTransform(backingScale: 1), imageSize: .zero)
    private(set) var anchor: Position?
    private(set) var extent: Position?

    func clear() { anchor = nil; extent = nil }
    var selectedText: String? {
        guard let anchor, let extent, anchor != extent else { return nil }
        let lower = min(anchor, extent), upper = max(anchor, extent)
        return (lower.line...upper.line).map { index in
            let characters = Array(lines[index].text)
            let start = index == lower.line ? lower.offset : 0
            let end = index == upper.line ? upper.offset : characters.count
            return String(characters[start..<end])
        }.joined(separator: "\n")
    }

    func containsLine(at point: CGPoint) -> Bool {
        lines.contains { geometry.viewRect($0.box).contains(point) }
    }

    @discardableResult func begin(at point: CGPoint) -> Bool {
        guard let position = position(at: point, requireHit: true) else {
            clear(); return false
        }
        anchor = position; extent = position
        return true
    }
    func drag(to point: CGPoint) {
        guard anchor != nil else { return }
        extent = position(at: point, requireHit: false)
    }

    var selectionRects: [CGRect] {
        guard let anchor, let extent, anchor != extent else { return [] }
        let lower = min(anchor, extent), upper = max(anchor, extent)
        var boxes: [CGRect] = []
        for index in lower.line...upper.line {
            let line = lines[index]
            let count = line.text.count
            let start = index == lower.line ? lower.offset : 0
            let end = index == upper.line ? upper.offset : count
            guard start < end, count > 0 else { continue }
            if line.characterBoxes.count == count {
                for offset in start..<end { boxes.append(geometry.viewRect(line.characterBoxes[offset])) }
            } else {
                let width = line.box.width / CGFloat(count)
                boxes.append(geometry.viewRect(CGRect(x: line.box.minX + CGFloat(start) * width,
                                                     y: line.box.minY, width: CGFloat(end - start) * width,
                                                     height: line.box.height)))
            }
        }
        return boxes
    }

    private func position(at point: CGPoint, requireHit: Bool) -> Position? {
        guard !lines.isEmpty else { return nil }
        let rects = lines.map { geometry.viewRect($0.box) }
        let index: Int
        if let hit = lines.indices.first(where: { rects[$0].contains(point) }) {
            index = hit
        } else if requireHit { return nil }
        else {
            // Text-editor drag behavior: choose the vertical row before choosing
            // a line. Horizontal proximity must never pull an endpoint to another
            // row. In a same-row gap, stop at the line on the anchor's side.
            index = endpointOutsideBoxes(at: point, rects: rects)
        }
        let line = lines[index]
        let count = line.text.count
        guard count > 0 else { return Position(line: index, offset: 0) }
        let boxes = line.characterBoxes.count == count ? line.characterBoxes : (0..<count).map {
            CGRect(x: line.box.minX + CGFloat($0) * line.box.width / CGFloat(count), y: line.box.minY,
                   width: line.box.width / CGFloat(count), height: line.box.height)
        }
        let horizontal = quarterTurnsHorizontal
        let centers = boxes.map { geometry.viewRect($0).midX }
        let coordinate = horizontal ? point.x : point.y
        let values = horizontal ? centers : boxes.map { geometry.viewRect($0).midY }
        let ascending = values.first! <= values.last!
        let offset = values.firstIndex { ascending ? coordinate <= $0 : coordinate >= $0 } ?? count
        return Position(line: index, offset: offset)
    }
    private var quarterTurnsHorizontal: Bool { geometry.quarterTurns.isMultiple(of: 2) }

    private func endpointOutsideBoxes(at point: CGPoint, rects: [CGRect]) -> Int {
        let horizontal = quarterTurnsHorizontal
        let coordinate = horizontal ? point.x : point.y
        let perpendicular = horizontal ? point.y : point.x
        func alongMin(_ i: Int) -> CGFloat { horizontal ? rects[i].minX : rects[i].minY }
        func alongMax(_ i: Int) -> CGFloat { horizontal ? rects[i].maxX : rects[i].maxY }
        func perpMin(_ i: Int) -> CGFloat { horizontal ? rects[i].minY : rects[i].minX }
        func perpMax(_ i: Int) -> CGFloat { horizontal ? rects[i].maxY : rects[i].maxX }
        var rows: [[Int]] = []
        for index in rects.indices.sorted(by: { (perpMin($0) + perpMax($0)) < (perpMin($1) + perpMax($1)) }) {
            if let row = rows.indices.first(where: { row in
                rows[row].contains { member in
                    let overlap = min(perpMax(index), perpMax(member)) - max(perpMin(index), perpMin(member))
                    let shorter = min(perpMax(index) - perpMin(index), perpMax(member) - perpMin(member))
                    return overlap >= shorter * 0.5
                }
            }) {
                rows[row].append(index)
            } else {
                rows.append([index])
            }
        }
        // A band containing the endpoint wins; between bands, use the nearer one.
        let row = rows.min { lhs, rhs in
            @MainActor func score(_ members: [Int]) -> (CGFloat, CGFloat) {
                let low = members.map { perpMin($0) }.min() ?? 0
                let high = members.map { perpMax($0) }.max() ?? 0
                return (max(max(low - perpendicular, 0), perpendicular - high), abs((low + high) / 2 - perpendicular))
            }
            let a = score(lhs), b = score(rhs)
            return a.0 == b.0 ? a.1 < b.1 : a.0 < b.0
        }!.sorted { alongMin($0) < alongMin($1) }
        let onAnchorRow = anchor.map { row.contains($0.line) } ?? false
        if coordinate <= alongMin(row[0]) { return row[0] }
        if coordinate >= alongMax(row[row.count - 1]) { return row[row.count - 1] }
        for (position, index) in row.enumerated() {
            if coordinate >= alongMin(index), coordinate <= alongMax(index) { return index }
            guard position + 1 < row.count else { continue }
            let next = row[position + 1]
            if coordinate > alongMax(index), coordinate < alongMin(next) {
                if onAnchorRow {
                    return row.firstIndex(of: anchor!.line)! <= position ? index : next
                }
                let anchorRect = rects[anchor!.line]
                let anchorCoordinate = horizontal ? anchorRect.midX : anchorRect.midY
                return coordinate >= anchorCoordinate ? index : next
            }
        }
        return row.min { abs((alongMin($0) + alongMax($0)) / 2 - coordinate) < abs((alongMin($1) + alongMax($1)) / 2 - coordinate) }!
    }
}
