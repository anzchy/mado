import CoreGraphics
import Testing
import MadoApplication

// #688 688-RS2-WI-1 (fix round 1, F1): which lines are bridges. Delegator decision B″ (2026-11-17):
// a line is a bridge when it neighbours two lines j and k that are (1) clearly separate — their
// perpendicular overlap is at most 0.25 of the shorter extent — (2) not on opposite sides of it
// along the line, and (3) the shorter of j and k is not taller than it. A skewed row's segments
// have their separated neighbours on opposite sides, so a skewed row stays one row; a tall or
// stretched box sits beside the rows it touches. Clause 3 is weaker than B″'s "strictly taller
// than both": see issue688RS2SameHeightLineBesideTightRowsIsABridge (why not stricter) and
// issue688RS2ShortLineBetweenTwoStretchedBoxesKeepsItsRow (why it is needed).

enum RSBridgeLayouts {
    /// Segments 100 wide at a 120 pt pitch, each shifted `d` pt; `heights` cycle when given.
    static func skew(_ count: Int, _ d: CGFloat, heights: [CGFloat] = [20]) -> RS.Layout {
        RS.Layout(rects: (0..<count).map { i in
            let h = heights[i % heights.count], centre = CGFloat(i) * d + 10
            return RS.r(CGFloat(i) * 120, centre - h / 2, CGFloat(i) * 120 + 100, centre + h / 2)
        }, texts: (0..<count).map { "s\($0)" })
    }
    static let varied: [CGFloat] = [20, 23, 17, 22, 18, 21, 17, 23]
    static let tightFull = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(120, 0, 220, 20), RS.r(0, 16, 100, 36),
                                             RS.r(120, 16, 220, 36), RS.r(300, 0, 340, 36)],
                                     texts: ["a1", "a2", "b1", "b2", "S"])
    static let partial = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(0, 28, 100, 48), RS.r(200, 8, 300, 40)],
                                   texts: ["j", "k", "i"])
    static let stretch12 = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(0, 16, 100, 36), RS.r(200, 4, 300, 28)],
                                     texts: ["j", "k", "i"])
    static let twoTall = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(0, 40, 100, 60), RS.r(0, 80, 100, 100),
                                           RS.r(200, 0, 240, 60), RS.r(300, 40, 340, 100)],
                                   texts: ["r1", "r2", "r3", "B1", "B2"])
    static let tableStretchMid = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(400, 0, 500, 20), RS.r(0, 16, 100, 36),
                                                   RS.r(400, 16, 500, 36), RS.r(200, 4, 300, 30)],
                                           texts: ["a1", "a2", "b1", "b2", "S"])
    static let stretchLeftOfRows = RS.Layout(rects: [RS.r(200, 0, 300, 20), RS.r(200, 16, 300, 36),
                                                     RS.r(0, 4, 100, 28)], texts: ["j", "k", "i"])
    /// Clause 1: j and k overlap 8 of 20 (0.4: not neighbours, not clearly separate).
    static let grey = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(0, 12, 100, 32), RS.r(200, 4, 300, 28)],
                                texts: ["j", "k", "i"])
    /// Dropped clause 3: i has the same height as j and k.
    static let sameHeight = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(0, 16, 100, 36), RS.r(200, 8, 300, 28)],
                                      texts: ["j", "k", "i"])
    /// Clause 3: row B (12 pt) touches box U (reaching up to row A) and box D (reaching down to
    /// row C); U and D overlap 9 pt ≤ 0.25 × 44, both lie after B. Found by the stretched generator.
    static let twoStretched = RS.Layout(rects: [RS.r(0, 0, 100, 16), RS.r(0, 41, 50, 53), RS.r(0, 76, 100, 88),
                                                RS.r(300, 0, 340, 53), RS.r(220, 44, 267, 88)],
                                        texts: ["A", "B", "C", "U", "D"])
    /// Known limit: a stretched box with its two rows on opposite sides along the line.
    static let oppositeSides = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(400, 16, 500, 36), RS.r(200, 4, 300, 32)],
                                         texts: ["j", "k", "i"])
}

@Suite(.timeLimit(.minutes(2))) struct Issue688TextRowResolverBridgeRuleTests {
    private func rows(_ layout: RS.Layout) -> [[Int]] { RS.normalized(layout.resolver.rows) }

    @Test(arguments: [("opus 3° 4 seg", RSBridgeLayouts.skew(4, 6)), ("opus 3° 4 seg negative", RSBridgeLayouts.skew(4, -6)),
                      ("3 seg", RSBridgeLayouts.skew(3, 6)), ("3 seg negative", RSBridgeLayouts.skew(3, -6)),
                      ("steep4", RSBridgeLayouts.skew(4, 8)), ("steep4 negative", RSBridgeLayouts.skew(4, -8)),
                      ("gentle5", RSBridgeLayouts.skew(5, 4)), ("8 seg d=-9", RSBridgeLayouts.skew(8, -9)),
                      ("vary d=4", RSBridgeLayouts.skew(8, 4, heights: RSBridgeLayouts.varied)),
                      ("vary d=6", RSBridgeLayouts.skew(8, 6, heights: RSBridgeLayouts.varied)),
                      ("vary d=8", RSBridgeLayouts.skew(8, 8, heights: RSBridgeLayouts.varied)),
                      ("vary d=-8", RSBridgeLayouts.skew(8, -8, heights: RSBridgeLayouts.varied))])
    func issue688RS2SkewedRowStaysOneRow(name: String, layout: RS.Layout) {
        #expect(rows(layout) == [Array(layout.rects.indices)], "\(name)")
    }

    @Test func issue688RS2SkewedRowStaysOneRowUnderReflectionAndRotation() {
        let base = RSBridgeLayouts.skew(4, 6)
        func map(_ f: (CGPoint) -> CGPoint) -> [CGRect] {
            base.rects.map { r in
                let a = f(CGPoint(x: r.minX, y: r.minY)), b = f(CGPoint(x: r.maxX, y: r.maxY))
                return RS.r(min(a.x, b.x), min(a.y, b.y), max(a.x, b.x), max(a.y, b.y))
            }
        }
        let cases: [(String, [CGRect], TextRowResolver.Axis)] = [
            ("flip x", map { CGPoint(x: -$0.x, y: $0.y) }, .horizontal),
            ("flip y", map { CGPoint(x: $0.x, y: -$0.y) }, .horizontal),
            ("rotate 90", map { CGPoint(x: -$0.y, y: $0.x) }, .vertical),
            ("rotate 270", map { CGPoint(x: $0.y, y: -$0.x) }, .vertical),
            ("rotate 180", map { CGPoint(x: -$0.x, y: -$0.y) }, .horizontal)
        ]
        for (name, rects, axis) in cases {
            #expect(RS.normalized(TextRowResolver(rects: rects, axis: axis).rows) == [[0, 1, 2, 3]], "\(name)")
        }
    }

    @Test func issue688RS2SkewedRowEndpointsStayInTheRow() {
        // Opus reproduction: anchor in s0. Before the fix (350,20) gave s0 and (110,22) gave s3.
        let layout = RSBridgeLayouts.skew(4, 6), resolver = layout.resolver
        #expect(resolver.lineIndex(at: CGPoint(x: 350, y: 20), anchorLine: 0) == 2)
        #expect(resolver.lineIndex(at: CGPoint(x: 110, y: 22), anchorLine: 0) == 0)
        #expect(layout.select(from: CGPoint(x: 1, y: 10), to: CGPoint(x: 350, y: 20)) == "s0\ns1\ns2")
        let three = RSBridgeLayouts.skew(3, 6).resolver
        #expect(three.lineIndex(at: CGPoint(x: 110, y: 22), anchorLine: 0) == 0)
    }

    @Test func issue688RS2StretchedAndTallBoxesStayBridges() {
        #expect(rows(RSBridgeLayouts.tightFull) == [[0, 1], [2, 3]])
        #expect(rows(RSBridgeLayouts.partial) == [[0], [1]])
        #expect(rows(RSBridgeLayouts.stretch12) == [[0], [1]])
        #expect(rows(RSBridgeLayouts.twoTall) == [[0], [1], [2]])
        #expect(rows(RSBridgeLayouts.tableStretchMid) == [[0, 1], [2, 3]])
        #expect(rows(RSBridgeLayouts.stretchLeftOfRows) == [[0], [1]])
        #expect(rows(RSLayouts.ce1) == [[1], [2]])
        #expect(rows(RSLayouts.ce2) == [[1], [2]])
        #expect(rows(RSLayouts.ce3) == [[0, 1, 2]])
        #expect(rows(RSBandTieLayouts.price) == [[0], [1, 2], [3]])
    }

    @Test func issue688RS2TightRowsWithStretchedBoxKeepTheirOwnLines() {
        // Rows 0–20 and 16–36 overlap 4 pt; the box beside them is a bridge, so a drag past the
        // end of each row stays on that row.
        let resolver = RSBridgeLayouts.tightFull.resolver
        #expect(resolver.lineIndex(at: CGPoint(x: 260, y: 6), anchorLine: 0) == 1)
        #expect(resolver.lineIndex(at: CGPoint(x: 260, y: 30), anchorLine: 2) == 3)
        // Middle row of the two-tall-boxes layout survives (the known case from i688-rs1).
        #expect(RSBridgeLayouts.twoTall.resolver.lineIndex(at: CGPoint(x: 150, y: 50), anchorLine: 0) == 1)
    }

    @Test func issue688RS2GreyZoneNeighboursAreNotSeparate() {
        // Clause 1: j and k overlap 0.4 of their height, so i is not a bridge and all three stay
        // one row (with the old non-neighbour test i would be a bridge: rows [[0],[1]]).
        #expect(rows(RSBridgeLayouts.grey) == [[0, 1, 2]])
        // At exactly 0.25 they are separate: i is a bridge.
        let quarter = TextRowResolver(rects: [RS.r(0, 0, 100, 20), RS.r(0, 15, 100, 35), RS.r(200, 4, 300, 30)],
                                      axis: .horizontal)
        #expect(RS.normalized(quarter.rows) == [[0], [1]])
    }

    @Test func issue688RS2SameHeightLineBesideTightRowsIsABridge() {
        // Why clause 3 is not B″'s "strictly taller than both": i is as tall as j and k, yet it
        // touches two clearly separate rows from the side; with the strict clause it would chain
        // them into one row, the failure this work package prevents.
        #expect(rows(RSBridgeLayouts.sameHeight) == [[0], [1]])
    }

    @Test func issue688RS2ShortLineBetweenTwoStretchedBoxesKeepsItsRow() {
        // Clause 3: without it B is a bridge and its row disappears (rows [[0],[2]]).
        let layout = RSBridgeLayouts.twoStretched
        #expect(rows(layout) == [[0], [1], [2]])
        #expect(layout.resolver.lineIndex(at: CGPoint(x: 150, y: 47), anchorLine: 0) == 1)
    }

    @Test func issue688RS2KnownLimitStretchBetweenOppositeRowsChains() {
        // Documented limit (EXT-01 限制, PR Still open): a stretched box whose two rows lie on
        // opposite sides of it along the line has the shape of a skewed row, so it chains them.
        #expect(rows(RSBridgeLayouts.oppositeSides) == [[0, 1, 2]])
    }
}
