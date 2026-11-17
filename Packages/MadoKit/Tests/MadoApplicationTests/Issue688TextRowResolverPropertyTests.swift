import CoreGraphics
import Foundation
import Testing
import MadoApplication

// #688 688-RS-WI-2: generated layouts and invariants I1–I10 for TextRowResolver (EXT-01).
// The generator, sampler and the I6 oracle are test code only: the oracle never calls the
// resolver. Each invariant collects its failures and reports the count plus the first few,
// each with the seed, layout index, layout literal, anchor and endpoint.

/// SplitMix64 (Steele, Lea, Flood 2014); pinned here so seeds reproduce across toolchains.
struct RSSplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ low: Int, _ high: Int) -> Int { low + Int(next() % UInt64(high - low + 1)) }
}

struct RSGenerated: CustomStringConvertible {
    var layout: RS.Layout
    var truthRows: [[Int]]
    var bridges: Set<Int>
    var hasNested: Bool
    var seed: UInt64
    var index: Int
    var description: String { "seed=\(seed) layout#\(index) \(layout)" }
}

enum RSGenerator {
    static let seeds: [UInt64] = [1, 2, 3, 5, 8, 13, 21, 34, 0x688, 0xDEAD_BEEF]
    static let layoutsPerSeed = 40
    static let alphabet = ["a", "中", "é", "e\u{301}", "👍🏽", "🇯🇵", "👨‍👩‍👧", "Z"]

    private struct Entry { var rect: CGRect; var text: String; var row: Int? }

    /// Fix round 1: extra layout kinds, each on its own seeds so the 400 plain layouts stay
    /// identical. `inflate` (F2): a tall member that is not a bridge stretches its row's band into
    /// the next row's band. `skew` (F1): rows of 3–6 segments, each shifted by d (0 < |d| ≤ 0.4 of
    /// the height, either tilt), as in a slightly rotated photo. `tight` (F1): flat rows that
    /// overlap the next row by 1 pt up to a quarter of the shorter height. `stretched` (F1): a
    /// partly stretched Vision box beside two adjacent rows (tight or ordinary spacing), covering
    /// at least three quarters of each; it is a bridge.
    enum Kind { case plain, inflate, skew, tight, stretched }
    static let extraSeeds: [(kind: Kind, seeds: [UInt64])] = [
        (.inflate, [0xF2_01, 0xF2_02, 0xF2_03, 0xF2_04, 0xF2_05]),
        (.skew, [0xF1_51, 0xF1_52, 0xF1_53]),
        (.tight, [0xF1_71, 0xF1_72, 0xF1_73]),
        (.stretched, [0xF1_B1, 0xF1_B2, 0xF1_B3])
    ]
    static let extraPerSeed = 20

    static func all() -> [RSGenerated] {
        seeds.flatMap { seed in
            var rng = RSSplitMix64(state: seed)
            return (0..<layoutsPerSeed).map { make(&rng, seed: seed, index: $0) }
        } + extraSeeds.flatMap { extra in
            extra.seeds.flatMap { seed in
                var rng = RSSplitMix64(state: seed)
                return (0..<extraPerSeed).map { make(&rng, seed: seed, index: $0, kind: extra.kind) }
            }
        }
    }

    static func make(_ rng: inout RSSplitMix64, seed: UInt64, index: Int, kind: Kind = .plain) -> RSGenerated {
        func text() -> String { (0..<rng.int(1, 8)).map { _ in alphabet[rng.int(0, alphabet.count - 1)] }.joined() }
        var entries: [Entry] = []
        let rowCount = kind == .plain ? rng.int(1, 4) : rng.int(2, 4)
        let tight = kind == .tight || (kind == .stretched && rng.int(0, 1) == 0)
        var top = 40
        var tops: [Int] = [], heights: [Int] = []
        for row in 0..<rowCount {
            let height = [12, 16, 20][rng.int(0, 2)]
            if tight, let lastTop = tops.last, let lastHeight = heights.last {
                top = lastTop + lastHeight - rng.int(1, min(lastHeight, height) / 4)
            }
            tops.append(top); heights.append(height)
            var x = 100 + rng.int(0, 20)
            if kind == .skew {
                let d = rng.int(1, height * 2 / 5) * (rng.int(0, 1) == 0 ? 1 : -1)
                let count = rng.int(3, 6), base = d < 0 ? -d * (count - 1) : 0
                for i in 0..<count {
                    let y = top + base + i * d, width = rng.int(40, 120)
                    entries.append(Entry(rect: RS.r(CGFloat(x), CGFloat(y), CGFloat(x + width), CGFloat(y + height)),
                                         text: text(), row: row))
                    x += width + rng.int(15, 40)
                }
                top += abs(d) * (count - 1) + height + rng.int(8, 30)
                continue
            }
            for _ in 0..<rng.int(1, 3) {
                let jitter = rng.int(-2, 2), width = rng.int(30, 200)
                let dy = kind == .tight || kind == .stretched ? 0 : jitter
                entries.append(Entry(rect: RS.r(CGFloat(x), CGFloat(top + dy), CGFloat(x + width),
                                                CGFloat(top + dy + height)), text: text(), row: row))
                x += width + rng.int(15, 60)
            }
            top += height + rng.int(8, 30)
        }
        if kind == .stretched {
            let r = rng.int(0, rowCount - 2)
            let low = tops[r] + rng.int(0, heights[r] / 4)
            let high = tops[r + 1] + heights[r + 1] - rng.int(0, heights[r + 1] / 4)
            let x = Int(entries.map(\.rect.maxX).max()!) + rng.int(15, 40)
            entries.append(Entry(rect: RS.r(CGFloat(x), CGFloat(low), CGFloat(x + rng.int(30, 55)), CGFloat(high)),
                                 text: text(), row: nil))
        }
        if kind == .inflate {
            // A tall member of row r reaching into row r+1 by less than half of r+1's height
            // (−3 pt covers the ±2 pt jitter), so it neighbours row r's lines but not row r+1's.
            let r = rng.int(0, rowCount - 2)
            let x = Int(entries.map(\.rect.maxX).max()!) + rng.int(15, 40)
            let bottom = tops[r + 1] + heights[r + 1] / 2 - 3
            entries.append(Entry(rect: RS.r(CGFloat(x), CGFloat(tops[r]), CGFloat(x + rng.int(30, 80)), CGFloat(bottom)),
                                 text: text(), row: r))
        }
        var hasNested = false
        if rng.int(0, 2) == 0 {
            let start = rng.int(0, entries.count - 1)
            let order = Array(entries.indices[start...]) + Array(entries.indices[..<start])
            if let h = order.first(where: { entries[$0].rect.width >= 60 }) {
                let host = entries[h].rect
                let width = CGFloat(rng.int(10, Int(host.width) - 20))
                entries.insert(Entry(rect: RS.r(host.minX + 10, host.minY, host.minX + 10 + width, host.maxY),
                                     text: text(), row: entries[h].row), at: h + 1)
                hasNested = true
            }
        }
        if rowCount >= 2, rng.int(0, 2) == 0 {
            let first = rng.int(0, rowCount - 2)
            let span = rng.int(2, min(3, rowCount - first))
            let covered = entries.filter { ($0.row ?? -1) >= first && ($0.row ?? -1) < first + span }
            let x = Int(entries.map(\.rect.maxX).max()!) + rng.int(20, 40)
            let bridge = RS.r(CGFloat(x), covered.map(\.rect.minY).min()!, CGFloat(x + 40),
                              covered.map(\.rect.maxY).max()!)
            entries.insert(Entry(rect: bridge, text: text(), row: nil), at: rng.int(0, entries.count))
        }
        let rows = Dictionary(grouping: entries.indices.filter { entries[$0].row != nil }) { entries[$0].row! }
        return RSGenerated(layout: RS.Layout(rects: entries.map(\.rect), texts: entries.map(\.text)),
                           truthRows: RS.normalized(Array(rows.values)),
                           bridges: Set(entries.indices.filter { entries[$0].row == nil }),
                           hasNested: hasNested, seed: seed, index: index)
    }

    /// Endpoints: every edge midpoint 0.01 inside, on, 1 pt outside; gaps; row margins;
    /// between rows; above and below everything.
    static func endpoints(_ g: RSGenerated, _ rng: inout RSSplitMix64) -> [CGPoint] {
        var points: [CGPoint] = []
        for r in g.layout.rects {
            for d in [0.01, 0, -1] as [CGFloat] {
                points += [CGPoint(x: r.minX + d, y: r.midY), CGPoint(x: r.maxX - d, y: r.midY),
                           CGPoint(x: r.midX, y: r.minY + d), CGPoint(x: r.midX, y: r.maxY - d)]
            }
        }
        let bands = oracleBands(g)
        for (row, band) in zip(g.truthRows, bands) {
            let mid = (band.lowerBound + band.upperBound) / 2
            let members = row.map { g.layout.rects[$0] }.sorted { $0.minX < $1.minX }
            for (a, b) in zip(members, members.dropFirst()) where a.maxX < b.minX {
                points += [CGPoint(x: (a.maxX + b.minX) / 2, y: mid), CGPoint(x: a.maxX + 1, y: mid),
                           CGPoint(x: b.minX - 1, y: mid)]
            }
            // Level with each member, just past either end of the row (F2: overlapping bands).
            for m in members {
                points += [CGPoint(x: members.map(\.minX).min()! - 3, y: m.midY),
                           CGPoint(x: members.map(\.maxX).max()! + 3, y: m.midY)]
            }
            points += [CGPoint(x: members.map(\.minX).min()! - 5, y: mid),
                       CGPoint(x: members.map(\.maxX).max()! + 5, y: mid)]
        }
        let low = Int(g.layout.rects.map(\.minX).min()!), high = Int(g.layout.rects.map(\.maxX).max()!)
        let ordered = bands.sorted { $0.lowerBound < $1.lowerBound }
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            let mid = (a.upperBound + b.lowerBound) / 2
            for dy in [-0.5, 0, 0.5] as [CGFloat] { points.append(CGPoint(x: CGFloat(rng.int(low, high)), y: mid + dy)) }
        }
        points.append(CGPoint(x: CGFloat(rng.int(low, high)), y: ordered.first!.lowerBound - 10))
        points.append(CGPoint(x: CGFloat(rng.int(low, high)), y: ordered.last!.upperBound + 10))
        return points
    }

    /// Up to three anchors inside random non-bridge lines, 0.3 of the way into a character cell.
    static func anchors(_ g: RSGenerated, _ rng: inout RSSplitMix64) -> [CGPoint] {
        let candidates = g.layout.rects.indices.filter { !g.bridges.contains($0) }
        return (0..<min(3, candidates.count)).map { _ in
            let line = candidates[rng.int(0, candidates.count - 1)]
            let cells = g.layout.cellsOf(line)
            let cell = cells[rng.int(0, cells.count - 1)]
            return CGPoint(x: cell.minX + 0.3 * cell.width, y: cell.midY)
        }
    }

    /// Independent oracle (I6): perpendicular band of each true row, built here, O(n²) at most.
    static func oracleBands(_ g: RSGenerated) -> [ClosedRange<CGFloat>] {
        g.truthRows.map { row in
            row.map { g.layout.rects[$0].minY }.min()!...row.map { g.layout.rects[$0].maxY }.max()!
        }
    }
    static func oracleNearestRows(_ g: RSGenerated, _ point: CGPoint) -> [Int] {
        let distances = oracleBands(g).map { max($0.lowerBound - point.y, 0, point.y - $0.upperBound) }
        let best = distances.min()!
        return distances.indices.filter { distances[$0] == best }
    }
    /// The line a true row gives for an endpoint off every box: covering member nearest
    /// perpendicularly, else the extreme-edge candidates around the point resolved against the
    /// anchor in reading order (straddle: the anchor's side). Written here from the rule text.
    static func oracleCandidate(_ g: RSGenerated, row: Int, _ p: CGPoint, anchor: Int?) -> Int {
        let rects = g.layout.rects, members = g.truthRows[row]
        func own(_ i: Int) -> CGFloat { max(rects[i].minY - p.y, 0, p.y - rects[i].maxY) }
        let covering = members.filter { rects[$0].minX <= p.x && p.x <= rects[$0].maxX }
        if !covering.isEmpty { return covering.min { (own($0), $0) < (own($1), $1) }! }
        let before = members.filter { rects[$0].maxX < p.x }.max { (rects[$0].maxX, -$0) < (rects[$1].maxX, -$1) }
        let after = members.filter { rects[$0].minX > p.x }.min { (rects[$0].minX, $0) < (rects[$1].minX, $1) }
        guard let before else { return after! }
        guard let after else { return before }
        guard let anchor else { return before }
        if before >= anchor, after >= anchor { return min(before, after) }
        if before <= anchor, after <= anchor { return max(before, after) }
        return rects[anchor].midX < p.x ? before : after
    }
    /// The true row an endpoint off every box belongs to: nearest band; on a band tie, the row
    /// whose line is nearest the pointer perpendicularly; then the anchor's row; then the lowest.
    static func oracleRow(_ g: RSGenerated, _ p: CGPoint, anchor: Int?) -> Int {
        let nearest = oracleNearestRows(g, p)
        guard nearest.count > 1 else { return nearest[0] }
        let rects = g.layout.rects
        let distance = nearest.map { row -> CGFloat in
            let line = rects[oracleCandidate(g, row: row, p, anchor: anchor)]
            return max(line.minY - p.y, 0, p.y - line.maxY)
        }
        let tied = nearest.indices.filter { distance[$0] == distance.min()! }.map { nearest[$0] }
        if tied.count == 1 { return tied[0] }
        if let anchor, let row = tied.first(where: { g.truthRows[$0].contains(anchor) }) { return row }
        return tied.min()!
    }
    static func oracleHit(_ rects: [CGRect], _ point: CGPoint) -> Int? {
        for i in rects.indices where rects[i].contains(point) { return i }
        return nil
    }
}

/// Failure reports stay short (seed, layout index, a clipped detail; the layout regenerates
/// from the seed and index): long multi-line issue text from parallel tests can split the
/// runner's result lines, which makes the receipt lane reject the run.
private struct RSFailures {
    var name: String
    var items: [String] = []
    mutating func add(_ g: RSGenerated, _ detail: String) {
        items.append("\(name): seed=\(g.seed) layout#\(g.index) \(detail.prefix(160))")
    }
    func report(_ start: ContinuousClock.Instant, sourceLocation: SourceLocation = #_sourceLocation) {
        print("\(name): \(ContinuousClock.now - start) for \(Issue688TextRowResolverPropertyTests.layouts.count) layouts")
        #expect(items.isEmpty, "\(items.count) failures; first: \(items.first ?? "")", sourceLocation: sourceLocation)
    }
}

private func positions(_ layout: RS.Layout, _ resolver: TextRowResolver, anchor: CGPoint, end: CGPoint)
    -> (RS.Position, RS.Position?)? {
    guard let a = layout.anchor(anchor, using: resolver) else { return nil }
    return (a, layout.extent(end, anchorLine: a.line, using: resolver))
}

@Suite(.timeLimit(.minutes(2))) struct Issue688TextRowResolverPropertyTests {
    static let layouts = RSGenerator.all()

    /// Walks every generated layout with its own sampler stream (seeded by the layout).
    private func each(_ body: (RSGenerated, [CGPoint], [CGPoint]) -> Void) {
        for g in Self.layouts {
            var rng = RSSplitMix64(state: g.seed &* 31 &+ UInt64(g.index))
            let ends = RSGenerator.endpoints(g, &rng)
            body(g, RSGenerator.anchors(g, &rng), ends)
        }
    }

    @Test func issue688RSInBoxFirstContaining() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I1")
        each { g, anchors, ends in
            let resolver = g.layout.resolver
            for p in ends + anchors {
                let hit = RSGenerator.oracleHit(g.layout.rects, p)
                if resolver.hitLine(at: p) != hit { failures.add(g, "hitLine p=\(p)") }
                guard let hit else { continue }
                for a in anchors {
                    let line = resolver.hitLine(at: a)
                    if resolver.lineIndex(at: p, anchorLine: line) != hit { failures.add(g, "in-box p=\(p) a=\(a)") }
                }
            }
        }
        failures.report(start)
    }

    @Test func issue688RSEdgeContinuity() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I2")
        var checked = 0
        each { g, anchors, _ in
            let resolver = g.layout.resolver
            let rects = g.layout.rects
            for line in rects.indices where !g.bridges.contains(line) {
                let r = rects[line]
                let pairs = [(CGPoint(x: r.minX + 0.01, y: r.midY), CGPoint(x: r.minX - 1, y: r.midY)),
                             (CGPoint(x: r.maxX - 0.01, y: r.midY), CGPoint(x: r.maxX + 1, y: r.midY)),
                             (CGPoint(x: r.midX, y: r.minY + 0.01), CGPoint(x: r.midX, y: r.minY - 1)),
                             (CGPoint(x: r.midX, y: r.maxY - 0.01), CGPoint(x: r.midX, y: r.maxY + 1))]
                let row = g.truthRows.firstIndex { $0.contains(line) }!
                let mates = g.truthRows[row].filter { $0 != line }
                let lineAnchor = CGPoint(x: r.minX + 0.3 * g.layout.cellsOf(line)[0].width, y: r.midY)
                for (inside, outside) in pairs {
                    guard resolver.hitLine(at: inside) == line else { continue }
                    let segment = CGRect(x: min(inside.x, outside.x), y: min(inside.y, outside.y),
                                         width: abs(inside.x - outside.x), height: abs(inside.y - outside.y))
                        .insetBy(dx: -0.001, dy: -0.001)
                    if rects.indices.contains(where: { $0 != line && rects[$0].insetBy(dx: -1, dy: -1).intersects(segment) }) {
                        continue
                    }
                    guard RSGenerator.oracleNearestRows(g, outside) == [row] else { continue }
                    // Leaving L sideways into a gap can land on the row-mate across it, whose
                    // edge is the same text only when no line's index lies between the two (a
                    // nested line or a bridge read in between is included by one, not the other).
                    let across = outside.x < inside.x
                        ? mates.filter { rects[$0].maxX < outside.x }.max { rects[$0].maxX < rects[$1].maxX }
                        : outside.x > inside.x ? mates.filter { rects[$0].minX > outside.x }.min { rects[$0].minX < rects[$1].minX } : nil
                    if let across, abs(across - line) > 1 { continue }
                    for anchor in [lineAnchor] + anchors.prefix(1) {
                        let before = g.layout.select(from: anchor, to: inside).map { $0.replacingOccurrences(of: "\n", with: "") } ?? ""
                        let after = g.layout.select(from: anchor, to: outside).map { $0.replacingOccurrences(of: "\n", with: "") } ?? ""
                        checked += 1
                        if before != after {
                            failures.add(g, "anchor=\(anchor) inside=\(inside) \(before.debugDescription) outside=\(outside) \(after.debugDescription)")
                        }
                    }
                }
            }
        }
        #expect(checked > 1000, "I2 must exercise enough edges, got \(checked)")
        failures.report(start)
    }

    @Test func issue688RSTallLineInsertionInvariant() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I3")
        var checked = 0
        each { g, anchors, ends in
            guard g.truthRows.count >= 2 else { return }
            var rng = RSSplitMix64(state: g.seed ^ UInt64(g.index + 1) &* 0x688)
            let rects = g.layout.rects
            let tall = RS.r(20, rects.map(\.minY).min()! - 2, 60, rects.map(\.maxY).max()! + 2)
            for k in [rng.int(0, rects.count), rects.count] {
                var with = g.layout
                with.rects.insert(tall, at: k)
                with.texts.insert("T", at: k)
                let base = g.layout.resolver, other = with.resolver
                func remap(_ p: RS.Position?) -> RS.Position? {
                    p.map { RS.Position(line: $0.line < k ? $0.line : $0.line + 1, offset: $0.offset) }
                }
                for a in anchors {
                    for e in ends {
                        guard let (oa, oe) = positions(g.layout, base, anchor: a, end: e),
                              let (na, ne) = positions(with, other, anchor: a, end: e) else {
                            failures.add(g, "anchor lost a=\(a)"); continue
                        }
                        checked += 1
                        if remap(oa) != na || remap(oe) != ne {
                            failures.add(g, "k=\(k) a=\(a) e=\(e) without=\(oa)→\(String(describing: oe)) with=\(na)→\(String(describing: ne))")
                        } else if k == rects.count, let oe, let ne, g.layout.text(oa, oe) != with.text(na, ne) {
                            failures.add(g, "k=n text a=\(a) e=\(e)")
                        }
                    }
                }
            }
        }
        #expect(checked > 10000, "I3 must exercise enough drags, got \(checked)")
        failures.report(start)
    }

    @Test func issue688RSNestedInsertionInvariant() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I4")
        var checked = 0
        each { g, anchors, ends in
            guard !g.hasNested else { return }
            let rects = g.layout.rects
            guard let h = rects.indices.first(where: { !g.bridges.contains($0) && rects[$0].width >= 60 }) else { return }
            var rng = RSSplitMix64(state: g.seed ^ UInt64(g.index + 7) &* 0x4688)
            let host = rects[h]
            let short = RS.r(host.minX + 10, host.minY, host.minX + 10 + CGFloat(rng.int(10, Int(host.width) - 20)), host.maxY)
            var with = g.layout
            with.rects.insert(short, at: h + 1)
            with.texts.insert("s", at: h + 1)
            let base = g.layout.resolver, other = with.resolver
            for a in anchors {
                for e in ends where RSGenerator.oracleHit(rects, e) == nil {
                    guard let (oa, oe) = positions(g.layout, base, anchor: a, end: e),
                          let (na, ne) = positions(with, other, anchor: a, end: e), let oe, let ne else {
                        failures.add(g, "position lost a=\(a) e=\(e)"); continue
                    }
                    checked += 1
                    let mapped = RS.Position(line: oe.line <= h ? oe.line : oe.line + 1, offset: oe.offset)
                    if mapped != ne {
                        failures.add(g, "H=\(h) a=\(a) e=\(e) without=\(oe) with=\(ne)")
                        continue
                    }
                    let lower = min(na, ne), upper = max(na, ne)
                    if !(lower.line <= h && upper.line >= h + 1), g.layout.text(oa, oe) != with.text(na, ne) {
                        failures.add(g, "text a=\(a) e=\(e)")
                    }
                }
            }
        }
        #expect(checked > 5000, "I4 must exercise enough drags, got \(checked)")
        failures.report(start)
    }

    /// The eight symmetries of the square on integer coordinates; odd ones swap the text axis.
    static let maps: [@Sendable (CGPoint) -> CGPoint] = [
        { $0 }, { CGPoint(x: -$0.y, y: $0.x) }, { CGPoint(x: -$0.x, y: -$0.y) }, { CGPoint(x: $0.y, y: -$0.x) },
        { CGPoint(x: -$0.x, y: $0.y) }, { CGPoint(x: $0.x, y: -$0.y) }, { CGPoint(x: $0.y, y: $0.x) },
        { CGPoint(x: -$0.y, y: -$0.x) }
    ]
    static let mapAxes: [TextRowResolver.Axis] = [.horizontal, .vertical, .horizontal, .vertical,
                                                  .horizontal, .horizontal, .vertical, .vertical]

    @Test func issue688RSDihedralCovariance() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I5")
        var checked = 0
        func mapRect(_ r: CGRect, _ map: (CGPoint) -> CGPoint) -> CGRect {
            let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)].map(map)
            return RS.r(min(corners[0].x, corners[1].x), min(corners[0].y, corners[1].y),
                        max(corners[0].x, corners[1].x), max(corners[0].y, corners[1].y))
        }
        each { g, anchors, ends in
            let shift = { (p: CGPoint) in CGPoint(x: p.x + 0.37, y: p.y + 0.37) }
            let cells = g.layout.rects.indices.map { g.layout.cellsOf($0) }
            let edgesX = Set(g.layout.rects.flatMap { [$0.minX, $0.maxX] } + cells.flatMap { $0.map(\.midX) })
            let edgesY = Set(g.layout.rects.flatMap { [$0.minY, $0.maxY] } + cells.flatMap { $0.map(\.midY) })
            let points = (ends + anchors).map(shift).filter { !edgesX.contains($0.x) && !edgesY.contains($0.y) }
            let starts = anchors.map(shift)
            // The selected text is a function of the two positions over the same strings, so
            // equal (anchor, extent) positions under every map mean equal copied text. A line
            // with one cell has no reading direction to recover after a reflection (the App's
            // offset rule, unchanged here, reads it left to right), so only its line is compared.
            func key(_ position: RS.Position?) -> RS.Position? {
                guard let position, cells[position.line].count < 2 else { return position }
                return RS.Position(line: position.line, offset: 0)
            }
            var base: [RS.Position?] = []
            for (index, map) in Self.maps.enumerated() {
                let layout = RS.Layout(rects: g.layout.rects.map { mapRect($0, map) }, texts: g.layout.texts,
                                       axis: Self.mapAxes[index], cells: cells.map { $0.map { mapRect($0, map) } })
                let resolver = layout.resolver
                var found: [RS.Position?] = []
                for a in starts {
                    let anchor = layout.anchor(map(a), using: resolver)
                    for p in points {
                        found.append(key(anchor))
                        found.append(key(layout.extent(map(p), anchorLine: anchor?.line, using: resolver)))
                    }
                }
                if index == 0 { base = found; continue }
                checked += found.count / 2
                if let i = found.indices.first(where: { found[$0] != base[$0] }) {
                    let a = starts[i / 2 / points.count], p = points[i / 2 % points.count]
                    failures.add(g, "map \(index) a=\(a) p=\(p) position \(String(describing: base[i]))→\(String(describing: found[i]))")
                }
            }
        }
        #expect(checked > 10000, "I5 must exercise enough drags, got \(checked)")
        failures.report(start)
    }

    @Test func issue688RSRowsMatchGeneratorTruth() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I6a")
        each { g, _, _ in
            let rows = RS.normalized(g.layout.resolver.rows)
            if rows != g.truthRows { failures.add(g, "rows \(rows) truth \(g.truthRows)") }
        }
        #expect(Self.layouts.contains { !$0.bridges.isEmpty } && Self.layouts.contains(where: \.hasNested))
        failures.report(start)
    }

    @Test func issue688RSRowSafetyAgainstOracle() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I6b")
        each { g, anchors, ends in
            let resolver = g.layout.resolver
            for a in anchors {
                guard let anchorLine = resolver.hitLine(at: a) else { continue }
                for e in ends where RSGenerator.oracleHit(g.layout.rects, e) == nil {
                    // Fix round 1 (F2): every band tie is decided by the oracle, including
                    // multi-row ties without the anchor's row.
                    let allowed = [RSGenerator.oracleRow(g, e, anchor: anchorLine)]
                    guard let line = resolver.lineIndex(at: e, anchorLine: anchorLine) else {
                        failures.add(g, "nil a=\(a) e=\(e)"); continue
                    }
                    if g.bridges.contains(line) || !allowed.contains(where: { g.truthRows[$0].contains(line) }) {
                        failures.add(g, "a=\(a) e=\(e) line=\(line) allowed rows \(allowed.map { g.truthRows[$0] })")
                    }
                }
            }
        }
        failures.report(start)
    }

    @Test func issue688RSContiguity() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I7")
        each { g, anchors, ends in
            let resolver = g.layout.resolver
            let full = Array(g.layout.texts.joined(separator: "\n"))
            func global(_ p: RS.Position) -> Int {
                g.layout.texts[..<p.line].reduce(0) { $0 + $1.count + 1 } + p.offset
            }
            for a in anchors {
                for e in ends {
                    guard let (pa, pe) = positions(g.layout, resolver, anchor: a, end: e), let pe else { continue }
                    if !(0...g.layout.texts[pe.line].count).contains(pe.offset) { failures.add(g, "offset \(pe)") }
                    let lower = min(global(pa), global(pe)), upper = max(global(pa), global(pe))
                    let expected = lower == upper ? nil : String(full[lower..<upper])
                    if g.layout.text(pa, pe) != expected { failures.add(g, "a=\(a) e=\(e)") }
                }
            }
        }
        failures.report(start)
    }

    private func oracleBottom(_ g: RSGenerated, _ row: [Int]) -> CGFloat { row.map { g.layout.rects[$0].maxY }.max()! }

    @Test func issue688RSFullRange() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I8")
        var checked = 0
        each { g, _, _ in
            // The last line must close the bottom row (an inflated member is appended last but
            // belongs to an upper row).
            let bottom = g.truthRows.max { oracleBottom(g, $0) < oracleBottom(g, $1) }!
            guard g.bridges.isEmpty, !g.hasNested, bottom.contains(g.layout.rects.count - 1) else { return }
            let cell = g.layout.cellsOf(0)[0]
            let anchor = CGPoint(x: cell.minX + 0.1 * cell.width, y: cell.midY)
            let end = CGPoint(x: g.layout.rects.map(\.maxX).max()! + 20, y: g.layout.rects.map(\.maxY).max()! + 20)
            checked += 1
            if g.layout.select(from: anchor, to: end) != g.layout.texts.joined(separator: "\n") {
                failures.add(g, "full range")
            }
        }
        #expect(checked > 50)
        failures.report(start)
    }

    @Test func issue688RSInBoxSymmetry() {
        let start = ContinuousClock.now
        var failures = RSFailures(name: "I9")
        each { g, anchors, ends in
            let resolver = g.layout.resolver
            let inBox = (anchors + ends).filter { resolver.hitLine(at: $0) != nil }
            for a in anchors {
                for b in inBox where g.layout.select(from: a, to: b) != g.layout.select(from: b, to: a) {
                    failures.add(g, "a=\(a) b=\(b)")
                }
            }
        }
        failures.report(start)
    }

    @Test func issue688RSDegenerateInputsDeterministic() {
        let cases: [[CGRect]] = [
            [RS.r(0, 0, 50, 20)], [RS.r(10, 10, 10, 30)], [RS.r(10, 10, 60, 10)],
            [RS.r(0, 0, 50, 20), RS.r(0, 0, 50, 20)], [RS.r(0, 0, 100, 20), RS.r(20, 0, 40, 20)],
            [RS.r(10, 10, 10, 30), RS.r(10, 10, 60, 10), RS.r(0, 0, 0, 0)]
        ]
        var rng = RSSplitMix64(state: 0x10)
        for rects in cases {
            for axis in [TextRowResolver.Axis.horizontal, .vertical] {
                let first = TextRowResolver(rects: rects, axis: axis), second = TextRowResolver(rects: rects, axis: axis)
                #expect(first.rows == second.rows)
                for _ in 0..<200 {
                    let p = CGPoint(x: CGFloat(rng.int(-20, 120)) + 0.5, y: CGFloat(rng.int(-20, 60)) + 0.5)
                    let anchor = [nil, 0, rects.count - 1][rng.int(0, 2)]
                    let line = first.lineIndex(at: p, anchorLine: anchor)
                    #expect(line == second.lineIndex(at: p, anchorLine: anchor))
                    #expect(line.map(rects.indices.contains) == true, "\(rects) p=\(p)")
                }
            }
        }
        let duplicates = TextRowResolver(rects: [RS.r(0, 0, 50, 20), RS.r(0, 0, 50, 20)], axis: .horizontal)
        #expect(RS.normalized(duplicates.rows) == [[0, 1]])
        #expect(duplicates.hitLine(at: CGPoint(x: 10, y: 10)) == 0)
        let empty = RS.Layout(rects: [RS.r(0, 0, 50, 20)], texts: [""])
        #expect(empty.select(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 80, y: 10)) == nil)
        #expect(TextRowResolver(rects: [], axis: .vertical).lineIndex(at: .zero, anchorLine: nil) == nil)
    }
}
