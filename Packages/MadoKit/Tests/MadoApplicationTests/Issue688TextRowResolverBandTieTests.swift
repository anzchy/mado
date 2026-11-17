import CoreGraphics
import Testing
import MadoApplication

// #688 688-RS2-WI-2 (fix round 1, F2): row bands can overlap when a tall member that is not a
// bridge inflates its row's band. A point in the overlap is at distance 0 from both bands, so the
// band tie is broken first by how far the pointer is from the line each tied row would give, then
// by the anchor's row, then by the lower row index (D4's exactly-midway rule stays the last resort).

enum RSBandTieLayouts {
    /// Opus i688-rs1 M2: 16 (0–48) neighbours November (4–20, overlap 16 > 8) but not Total
    /// (40–56, overlap 8 = 0.5 × 16, not more), so the rows are Header | 16 November | Total and
    /// the middle band 0…48 swallows Total's upper half.
    static let price = RS.Layout(rects: [RS.r(0, -40, 100, -20), RS.r(0, 0, 120, 48), RS.r(140, 4, 260, 20),
                                         RS.r(140, 40, 260, 56)],
                                 texts: ["Header", "16", "November", "Total"])
}

@Suite(.timeLimit(.minutes(2))) struct Issue688TextRowResolverBandTieTests {
    @Test func issue688RS2PriceRowsKeepTheTallMember() {
        #expect(RS.normalized(RSBandTieLayouts.price.resolver.rows) == [[0], [1, 2], [3]])
    }

    @Test(arguments: [40, 42, 44, 47, 49] as [CGFloat])
    func issue688RS2PointerLevelWithTotalSelectsTotal(y: CGFloat) {
        let layout = RSBandTieLayouts.price, resolver = layout.resolver
        let point = CGPoint(x: 330, y: y)
        #expect(resolver.lineIndex(at: point, anchorLine: 0) == 3, "anchor Header, y=\(y)")
        #expect(resolver.lineIndex(at: point, anchorLine: nil) == 3, "no anchor, y=\(y)")
        #expect(resolver.lineIndex(at: point, anchorLine: 2) == 3, "anchor November, y=\(y)")
        let anchor = CGPoint(x: 1, y: -30)
        #expect(layout.select(from: anchor, to: point) == "Header\n16\nNovember\nTotal",
                "drag from Header start to y=\(y) copies through Total")
    }

    @Test(arguments: [4, 12, 20, 27] as [CGFloat])
    func issue688RS2PointerLevelWithNovemberSelectsNovember(y: CGFloat) {
        let resolver = RSBandTieLayouts.price.resolver
        #expect(resolver.lineIndex(at: CGPoint(x: 330, y: y), anchorLine: 0) == 2, "y=\(y)")
        #expect(resolver.lineIndex(at: CGPoint(x: 330, y: y), anchorLine: 3) == 2, "y=\(y)")
    }

    @Test func issue688RS2EqualLineDistanceFallsBackToAnchorRowThenLowerIndex() {
        // In the gap between 16 and November both rows give a line level with the pointer:
        // the middle row's candidate is 16 (anchor Header, rule 5 takes the earlier line) at
        // distance 0, Total at distance 0. No anchor row among them → lower row index.
        let resolver = RSBandTieLayouts.price.resolver
        #expect(resolver.lineIndex(at: CGPoint(x: 130, y: 44), anchorLine: 0) == 1)
        // Two single-line rows overlapping by exactly half (not neighbours): both at distance 0.
        let pair = TextRowResolver(rects: [RS.r(0, 0, 100, 20), RS.r(200, 10, 300, 30)], axis: .horizontal)
        #expect(pair.lineIndex(at: CGPoint(x: 350, y: 15), anchorLine: nil) == 0)
        #expect(pair.lineIndex(at: CGPoint(x: 350, y: 15), anchorLine: 0) == 0)
        #expect(pair.lineIndex(at: CGPoint(x: 350, y: 15), anchorLine: 1) == 1)
    }

    @Test func issue688RS2PriceLayoutVerticalAxis() {
        // The same layout transposed: rows run down the page, the perpendicular axis is x.
        let transposed = RSBandTieLayouts.price.rects.map { RS.r($0.minY, $0.minX, $0.maxY, $0.maxX) }
        let resolver = TextRowResolver(rects: transposed, axis: .vertical)
        #expect(RS.normalized(resolver.rows) == [[0], [1, 2], [3]])
        #expect(resolver.lineIndex(at: CGPoint(x: 44, y: 330), anchorLine: 0) == 3)
        #expect(resolver.lineIndex(at: CGPoint(x: 12, y: 330), anchorLine: 0) == 2)
    }
}
