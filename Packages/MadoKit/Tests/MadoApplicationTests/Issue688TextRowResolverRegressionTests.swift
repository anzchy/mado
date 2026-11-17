import CoreGraphics
import Testing
import MadoApplication

// #688 688-RS-WI-1: named regression table for TextRowResolver (EXT-01). View coordinates,
// y down. Each layout is swept around every box edge (0.01 inside, on, 1 pt outside), plus
// the counterexamples CE1–CE5 and the plan's decisions D3/D4/D5. Expected values come from
// the rule in the #688 fix plan §2, not from the implementation.

enum RSTextCheck: Sendable { case skip, equals(String?), prefix(String) }

struct RSSweep: Sendable, CustomTestStringConvertible {
    let point: CGPoint
    let anchor: Int?
    let line: Int?
    let text: RSTextCheck
    var testDescription: String {
        "p=(\(point.x),\(point.y)) anchor=\(anchor.map(String.init) ?? "nil") → \(line.map(String.init) ?? "nil")"
    }
}

private func s(_ x: CGFloat, _ y: CGFloat, _ anchor: Int?, _ line: Int?, _ text: RSTextCheck = .skip) -> RSSweep {
    RSSweep(point: CGPoint(x: x, y: y), anchor: anchor, line: line, text: text)
}

enum RSLayouts {
    static let ce1 = RS.Layout(rects: [RS.r(0, 0, 120, 48), RS.r(140, 4, 260, 20), RS.r(150, 28, 300, 44)],
                               texts: ["16", "November", "Monday"])
    static let ce1Anchor = CGPoint(x: 141, y: 12)
    static let ce2 = RS.Layout(rects: [RS.r(0, 0, 200, 120), RS.r(300, 0, 500, 20), RS.r(300, 40, 500, 60)],
                               texts: ["big", "a", "b"])
    static let ce2Anchor = CGPoint(x: 301, y: 50)
    static let ce3 = RS.Layout(rects: [RS.r(0, 0, 300, 20), RS.r(200, 0, 250, 20), RS.r(400, 0, 500, 20)],
                               texts: ["wide", "short", "C"])
    static let ce3Anchor = CGPoint(x: 1, y: 10)
    static let ce4 = RS.Layout(rects: [RS.r(0, 0, 160, 40), RS.r(220, 10, 300, 40), RS.r(0, 80, 200, 110)],
                               texts: ["中文测试", "SIDE", "Hello Mado"])
    static let d5 = RS.Layout(rects: [RS.r(0, 0, 100, 60), RS.r(150, 0, 250, 20), RS.r(400, 0, 500, 20),
                                      RS.r(150, 40, 250, 60)], texts: ["T", "A", "B", "C"])
    /// Every line is a bridge: the neighbour graph is the 4-cycle X–s1–Y–s2.
    static let allBridge = RS.Layout(rects: [RS.r(0, 0, 100, 40), RS.r(300, 30, 400, 70), RS.r(150, 32, 200, 36),
                                             RS.r(220, 36, 270, 40)], texts: ["X", "Y", "s1", "s2"])
    static let margins = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(130, 30, 230, 50)], texts: ["A", "B"])
    static let marginsVertical = RS.Layout(rects: [RS.r(0, 0, 20, 100), RS.r(30, 130, 50, 230)], texts: ["A", "B"],
                                           axis: .vertical)
    static let three = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(200, 0, 300, 20), RS.r(400, 0, 500, 20)],
                                 texts: ["A", "B", "C"])
    static let forward = RS.Layout(rects: [RS.r(500, 0, 600, 20), RS.r(0, 30, 100, 50), RS.r(200, 30, 300, 50)],
                                   texts: ["A", "B", "C"])
    static let reverse = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(200, 0, 300, 20), RS.r(0, 30, 100, 50)],
                                   texts: ["A", "B", "C"])
    static let rowEnd = RS.Layout(rects: [RS.r(0, 0, 300, 20), RS.r(200, 0, 250, 20)], texts: ["wide", "short"])
    static let alongTie = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(40, 2, 60, 22)], texts: ["A", "N"])
    static let straddleRight = RS.Layout(rects: [RS.r(0, 0, 100, 20), RS.r(400, 0, 500, 20), RS.r(200, 0, 300, 20)],
                                         texts: ["A", "B", "C"])
    static let straddleLeft = RS.Layout(rects: [RS.r(400, 0, 500, 20), RS.r(0, 0, 100, 20), RS.r(200, 0, 300, 20)],
                                        texts: ["A", "B", "C"])
}

private func check(_ layout: RS.Layout, anchorPoint: CGPoint?, _ sweep: RSSweep) {
    let resolver = layout.resolver
    let first = resolver.lineIndex(at: sweep.point, anchorLine: sweep.anchor)
    #expect(first == sweep.line, "\(layout)")
    #expect(resolver.lineIndex(at: sweep.point, anchorLine: sweep.anchor) == first, "deterministic")
    guard let anchorPoint else { return }
    let text = layout.select(from: anchorPoint, to: sweep.point)
    switch sweep.text {
    case .skip: break
    case let .equals(expected): #expect(text == expected, "\(layout)")
    case let .prefix(expected): #expect(text?.hasPrefix(expected) == true, "got \(String(describing: text))")
    }
}

@Suite(.timeLimit(.minutes(1))) struct Issue688TextRowResolverRegressionTests {
    @Test func issue688RSRowsOfNamedLayouts() {
        #expect(RS.normalized(RSLayouts.ce1.resolver.rows) == [[1], [2]])
        #expect(RS.normalized(RSLayouts.ce2.resolver.rows) == [[1], [2]])
        #expect(RS.normalized(RSLayouts.ce3.resolver.rows) == [[0, 1, 2]])
        #expect(RS.normalized(RSLayouts.ce4.resolver.rows) == [[0, 1], [2]])
        #expect(RS.normalized(RSLayouts.d5.resolver.rows) == [[1, 2], [3]])
        #expect(RS.normalized(RSLayouts.allBridge.resolver.rows) == [[0, 1, 2, 3]])
        #expect(TextRowResolver(rects: [], axis: .horizontal).rows.isEmpty)
    }

    @Test func issue688RSAllBridgeFallback() {
        let resolver = RSLayouts.allBridge.resolver
        #expect(RS.normalized(resolver.rows) == [[0, 1, 2, 3]])
        #expect(resolver.lineIndex(at: CGPoint(x: 450, y: 50), anchorLine: 0) == 1)
        #expect(resolver.lineIndex(at: CGPoint(x: 210, y: 100), anchorLine: 0) == 2)
        #expect(resolver.lineIndex(at: CGPoint(x: 210, y: 100), anchorLine: nil) == 2)
        #expect(resolver.lineIndex(at: CGPoint(x: 210, y: 100), anchorLine: 3) == 3)
    }

    @Test func issue688RSEmptyRects() {
        let resolver = TextRowResolver(rects: [], axis: .horizontal)
        #expect(resolver.rows.isEmpty)
        #expect(resolver.hitLine(at: .zero) == nil)
        #expect(resolver.lineIndex(at: CGPoint(x: 5, y: 5), anchorLine: nil) == nil)
        #expect(resolver.lineIndex(at: CGPoint(x: 5, y: 5), anchorLine: 0) == nil)
    }

    // CE1 price: `16` is a tall box beside two rows. Anchor at the start of November.
    @Test(arguments: [
        s(330, 21, 1, 1, .equals("November")), s(330, 2, 1, 1, .equals("November")),
        s(280, 22, 1, 1, .equals("November")), s(259.99, 12, 1, 1, .equals("November")),
        s(260, 12, 1, 1, .equals("November")), s(261, 12, 1, 1, .equals("November")),
        s(330, 19.99, 1, 1, .equals("November")), s(330, 20, 1, 1, .equals("November")),
        s(330, 4.01, 1, 1), s(330, 4, 1, 1), s(330, 3, 1, 1, .equals("November")),
        s(330, -1, 1, 1, .equals("November")),
        s(330, 24.01, 1, 2, .equals("November\nMonday")), s(299.99, 36, 1, 2),
        s(300, 36, 1, 2, .equals("November\nMonday")), s(301, 36, 1, 2), s(330, 28.01, 1, 2),
        s(330, 28, 1, 2), s(330, 27, 1, 2), s(330, 44, 1, 2), s(330, 45, 1, 2),
        s(119.99, 12, 1, 0), s(120, 12, 1, 1, .equals(nil)), s(121, 12, 1, 1, .equals(nil)),
        s(60, 47.99, 1, 0), s(60, 48, 1, 2, .equals("November\n")), s(60, 49, 1, 2, .equals("November\n")),
        // D4: (330,24) is midway between the November and Monday bands.
        s(330, 24, 1, 1), s(330, 24, 2, 2), s(330, 24, 0, 1), s(330, 24, nil, 1)
    ])
    func issue688RSCE1PriceSweep(_ sweep: RSSweep) {
        check(RSLayouts.ce1, anchorPoint: sweep.anchor == 1 ? RSLayouts.ce1Anchor : nil, sweep)
    }

    // CE2 tall: `big` spans both rows. Anchor at the start of b.
    @Test(arguments: [
        s(600, 62, 2, 2, .equals("b")), s(600, 80, 2, 2, .equals("b")), s(250, 80, 2, 2, .equals(nil)),
        s(499.99, 50, 2, 2), s(500, 50, 2, 2, .equals("b")), s(501, 50, 2, 2),
        s(400, 59.99, 2, 2), s(400, 60, 2, 2), s(400, 61, 2, 2), s(400, 40, 2, 2), s(400, 39, 2, 2),
        s(600, 20, 2, 1, .equals("\n")), s(199.99, 50, 2, 0), s(200, 50, 2, 2, .equals(nil)), s(201, 50, 2, 2),
        s(100, 119.99, 2, 0), s(100, 120, 2, 2), s(100, 121, 2, 2),
        // D4: (600,30) is midway between the a and b bands.
        s(600, 30, 2, 2), s(600, 30, 1, 1), s(600, 30, 0, 1)
    ])
    func issue688RSCE2TallSweep(_ sweep: RSSweep) {
        check(RSLayouts.ce2, anchorPoint: sweep.anchor == 2 ? RSLayouts.ce2Anchor : nil, sweep)
    }

    // CE3 nested: `short` lies inside `wide`; C follows. Anchor at the start of wide.
    @Test(arguments: [
        s(350, 10, 0, 0, .equals("wide")), s(299.99, 10, 0, 0), s(300, 10, 0, 0, .equals("wide")),
        s(301, 10, 0, 0, .equals("wide")), s(399, 10, 0, 0, .equals("wide")), s(400, 10, 0, 2),
        s(500, 10, 0, 2), s(501, 10, 0, 2), s(350, 20, 0, 0, .equals("wide")), s(350, 21, 0, 0, .equals("wide")),
        s(350, -1, 0, 0, .equals("wide")), s(225, -1, 0, 0),
        s(350, 10, 2, 2), s(350, 10, 1, 0), s(350, 10, nil, 0)
    ])
    func issue688RSCE3NestedSweep(_ sweep: RSSweep) {
        check(RSLayouts.ce3, anchorPoint: sweep.anchor == 0 ? RSLayouts.ce3Anchor : nil, sweep)
    }

    // CE4 side by side: 中文测试 and SIDE share a row with a 60 pt gap; Hello Mado below.
    @Test(arguments: [
        s(159.99, 20, 0, 0, .equals("中文测试")), s(160, 20, 0, 0, .equals("中文测试")),
        s(161, 20, 0, 0, .equals("中文测试")), s(172, 25, 0, 0, .equals("中文测试")),
        s(172, 20, 0, 0, .equals("中文测试")), s(219, 25, 0, 0, .equals("中文测试")),
        s(219, 20, 0, 0, .equals("中文测试")), s(220, 25, 0, 1), s(172, 40, 0, 0), s(172, 41, 0, 0),
        s(301, 25, 0, 1, .equals("中文测试\nSIDE")), s(190, 59.99, 0, 0), s(190, 60.01, 0, 2), s(190, 60, 0, 0)
    ])
    func issue688RSCE4SideBySideFromChinese(_ sweep: RSSweep) {
        check(RSLayouts.ce4, anchorPoint: CGPoint(x: 1, y: 20), sweep)
    }

    @Test(arguments: [
        s(208, 20, 1, 1, .equals("SIDE")), s(208, 25, 1, 1, .equals("SIDE")), s(161, 25, 1, 1, .equals("SIDE")),
        s(172, 9, 1, 1, .equals("SIDE")), s(-1, 20, 1, 0, .equals("中文测试\nSIDE"))
    ])
    func issue688RSCE4SideBySideFromSIDEEnd(_ sweep: RSSweep) {
        check(RSLayouts.ce4, anchorPoint: CGPoint(x: 299, y: 25), sweep)
    }

    @Test(arguments: [s(190, 25, 2, 1, .prefix("SIDE\n")), s(190, 60, 2, 2)])
    func issue688RSCE4SideBySideFromHello(_ sweep: RSSweep) {
        check(RSLayouts.ce4, anchorPoint: CGPoint(x: 1, y: 95), sweep)
    }

    // CE5: margins, three on a row, forward/reverse cross-row gaps, row end, along tie-break.
    @Test(arguments: [
        s(105, 40, 0, 1, .equals("A\n")), s(245, 40, 0, 1, .equals("A\nB")), s(129, 40, 0, 1, .equals("A\n")),
        s(231, 40, 0, 1, .equals("A\nB")), s(105, 24.99, 0, 0), s(105, 25, 0, 0)
    ])
    func issue688RSCE5Margins(_ sweep: RSSweep) {
        check(RSLayouts.margins, anchorPoint: CGPoint(x: 1, y: 10), sweep)
    }

    @Test(arguments: [
        s(380, 10, 0, 1, .equals("A\nB")), s(301, 10, 0, 1, .equals("A\nB")), s(399, 10, 0, 1, .equals("A\nB")),
        s(150, 10, 0, 0, .equals("A")), s(150, 10, 2, 1)
    ])
    func issue688RSCE5ThreeOnARow(_ sweep: RSSweep) {
        check(RSLayouts.three, anchorPoint: sweep.anchor == 0 ? CGPoint(x: 1, y: 10) : nil, sweep)
    }

    @Test(arguments: [s(110, 40, 0, 1, .equals("A\nB")), s(101, 40, 0, 1, .equals("A\nB")),
                      s(199, 40, 0, 1, .equals("A\nB"))])
    func issue688RSCE5ForwardIntoNextRowGap(_ sweep: RSSweep) {
        check(RSLayouts.forward, anchorPoint: CGPoint(x: 501, y: 10), sweep)
    }

    @Test(arguments: [s(150, 10, 2, 1, .equals("B\n")), s(101, 10, 2, 1, .equals("B\n")),
                      s(199, 10, 2, 1, .equals("B\n"))])
    func issue688RSCE5ReverseIntoUpperGap(_ sweep: RSSweep) {
        check(RSLayouts.reverse, anchorPoint: CGPoint(x: 1, y: 40), sweep)
    }

    @Test func issue688RSCE5RowEndAndAlongTieBreak() {
        check(RSLayouts.rowEnd, anchorPoint: CGPoint(x: 1, y: 10), s(350, 10, 0, 0, .equals("wide")))
        check(RSLayouts.alongTie, anchorPoint: nil, s(50, 23, 0, 1))
        check(RSLayouts.alongTie, anchorPoint: nil, s(50, -1, 0, 0))
    }

    @Test(arguments: [s(40, 105, 0, 1, .equals("A\n")), s(40, 245, 0, 1, .equals("A\nB")),
                      s(40, 129, 0, 1), s(40, 231, 0, 1)])
    func issue688RSCE5VerticalAxis(_ sweep: RSSweep) {
        check(RSLayouts.marginsVertical, anchorPoint: CGPoint(x: 10, y: 1), sweep)
        let swapped = CGPoint(x: sweep.point.y, y: sweep.point.x)
        #expect(RSLayouts.margins.resolver.lineIndex(at: swapped, anchorLine: sweep.anchor) == sweep.line)
    }

    // D4 (midpoint ties), D5 (anchor inside a bridge), straddle (Vision order ≠ geometry).
    @Test(arguments: [
        s(300, 10, 0, 1), s(300, 10, 3, 2), s(300, 30, 3, 3), s(300, 30, 1, 1), s(300, 30, 0, 1),
        s(300, 30, nil, 1), s(50, 61, 0, 3), s(600, 50, 0, 3)
    ])
    func issue688RSDecisionsD4D5(_ sweep: RSSweep) {
        check(RSLayouts.d5, anchorPoint: nil, sweep)
    }

    @Test func issue688RSStraddleUsesAnchorGeometricSide() {
        check(RSLayouts.straddleRight, anchorPoint: nil, s(150, 10, 1, 2))
        check(RSLayouts.straddleRight, anchorPoint: nil, s(150, 10, nil, 0))
        check(RSLayouts.straddleRight, anchorPoint: nil, s(350, 10, 1, 1))
        check(RSLayouts.straddleLeft, anchorPoint: nil, s(350, 10, 1, 2))
        check(RSLayouts.straddleLeft, anchorPoint: nil, s(150, 10, 1, 1))
    }
    // Spec adversary round 1 additions.
    @Test func issue688RSThresholdIsStrictlyMoreThanHalf() {
        let resolver = TextRowResolver(rects: [RS.r(0, 0, 100, 20), RS.r(200, 10, 300, 30)], axis: .horizontal)
        #expect(RS.normalized(resolver.rows) == [[0], [1]])
        #expect(resolver.lineIndex(at: CGPoint(x: 350, y: 15), anchorLine: 0) == 0)
    }

    @Test func issue688RSRowTieTakesLowerIndexNotUpperRow() {
        let resolver = TextRowResolver(rects: [RS.r(0, 40, 100, 60), RS.r(0, 0, 100, 20), RS.r(300, 0, 340, 60)],
                                       axis: .horizontal)
        #expect(RS.normalized(resolver.rows) == [[0], [1]])
        #expect(resolver.lineIndex(at: CGPoint(x: 200, y: 30), anchorLine: 2) == 0)
        #expect(resolver.lineIndex(at: CGPoint(x: 200, y: 30), anchorLine: nil) == 0)
    }

    @Test func issue688RSRowTieIgnoresAnchorIndexDistance() {
        let resolver = TextRowResolver(rects: [RS.r(0, 0, 100, 20), RS.r(0, 40, 100, 60), RS.r(0, 100, 100, 120)],
                                       axis: .horizontal)
        #expect(resolver.lineIndex(at: CGPoint(x: 200, y: 30), anchorLine: 2) == 0)
    }

    @Test func issue688RSFallbackOnlyWhenEveryLineIsABridge() {
        let resolver = TextRowResolver(rects: RSLayouts.allBridge.rects + [RS.r(0, 200, 100, 220)], axis: .horizontal)
        #expect(RS.normalized(resolver.rows) == [[4]])
        #expect(resolver.lineIndex(at: CGPoint(x: 450, y: 50), anchorLine: 0) == 4)
    }

    @Test func issue688RSFallbackRowsAreComponentsOfAllLines() {
        let copy = RSLayouts.allBridge.rects.map { $0.offsetBy(dx: 0, dy: 200) }
        let resolver = TextRowResolver(rects: RSLayouts.allBridge.rects + copy, axis: .horizontal)
        #expect(RS.normalized(resolver.rows) == [[0, 1, 2, 3], [4, 5, 6, 7]])
    }

    @Test func issue688RSNilAnchorTakesLeftCandidate() {
        check(RSLayouts.straddleLeft, anchorPoint: nil, s(350, 10, nil, 2))
    }
    @Test func issue688RSThresholdJustAboveHalfJoinsRow() {
        let resolver = TextRowResolver(rects: [RS.r(0, 0, 100, 20), RS.r(200, 9, 300, 29)], axis: .horizontal)
        #expect(RS.normalized(resolver.rows) == [[0, 1]])
        #expect(resolver.lineIndex(at: CGPoint(x: 150, y: 15), anchorLine: 0) == 0)
        #expect(resolver.lineIndex(at: CGPoint(x: 150, y: 15), anchorLine: 1) == 1)
    }
}
