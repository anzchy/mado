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
            // A drag ending in the gap between two lines on the same row stays at
            // the edge of the line it left. Otherwise, measure to the whole box:
            // midpoints alone can jump to a distant line on the same row.
            index = departedLine(inGapAt: point, rects: rects)
                ?? lines.indices.min { lhs, rhs in
                    let a = distanceToBox(point, rects[lhs])
                    let b = distanceToBox(point, rects[rhs])
                    return a < b || (a == b && lhs < rhs)
                } ?? 0
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

    private func distanceToBox(_ point: CGPoint, _ box: CGRect) -> CGFloat {
        let dx = max(box.minX - point.x, 0, point.x - box.maxX)
        let dy = max(box.minY - point.y, 0, point.y - box.maxY)
        return dx * dx + dy * dy
    }

    private func departedLine(inGapAt point: CGPoint, rects: [CGRect]) -> Int? {
        guard let anchor else { return nil }
        let horizontal = quarterTurnsHorizontal
        let coordinate = horizontal ? point.x : point.y
        let perpendicular = horizontal ? point.y : point.x
        let own = rects[anchor.line]
        let ownMin = horizontal ? own.minX : own.minY
        let ownMax = horizontal ? own.maxX : own.maxY
        let ownPerpMin = horizontal ? own.minY : own.minX
        let ownPerpMax = horizontal ? own.maxY : own.maxX
        for neighbor in [anchor.line - 1, anchor.line + 1] where rects.indices.contains(neighbor) {
            let other = rects[neighbor]
            let otherMin = horizontal ? other.minX : other.minY
            let otherMax = horizontal ? other.maxX : other.maxY
            let otherPerpMin = horizontal ? other.minY : other.minX
            let otherPerpMax = horizontal ? other.maxY : other.maxX
            let overlap = min(ownPerpMax, otherPerpMax) - max(ownPerpMin, otherPerpMin)
            let shorter = min(ownPerpMax - ownPerpMin, otherPerpMax - otherPerpMin)
            guard overlap > shorter * 0.5,
                  perpendicular >= min(ownPerpMin, otherPerpMin),
                  perpendicular <= max(ownPerpMax, otherPerpMax) else { continue }
            if ownMax < otherMin, coordinate >= ownMax, coordinate <= otherMin { return anchor.line }
            if otherMax < ownMin, coordinate >= otherMax, coordinate <= ownMin { return anchor.line }
        }
        return nil
    }
}
