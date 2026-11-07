import Foundation
import Testing
import MadoCore

/// ImageIO keeps the source ratio: the long side becomes the edge and the short side is at least ⌊edge·S/L⌋.
private func covers(_ edge: Int, source: (Double, Double), tile: ThumbnailCoverage) -> Bool {
    let (w, h) = source
    let long = max(w, h), short = min(w, h)
    let outLong = Double(edge), outShort = (Double(edge) * short / long).rounded(.down)
    let (outW, outH) = w >= h ? (outLong, outShort) : (outShort, outLong)
    return outW >= tile.width.rounded(.up) && outH >= tile.height.rounded(.up)
}

@Suite struct ThumbnailCoverageTests {
    // #161: square, 3:2, 2:1 and portrait sources request the smallest covering edge.
    @Test(arguments: [
        (1000.0, 1000.0, 424), (600.0, 400.0, 444), (800.0, 400.0, 592), (800.0, 1200.0, 636),
    ])
    func thumbnailCoverageRequestsSmallestCoveringEdge(width: Double, height: Double, expected: Int) {
        let tile = ThumbnailCoverage(width: 424, height: 296)
        let edge = tile.edge(sourceWidth: width, sourceHeight: height)
        #expect(edge == expected)
        #expect(covers(edge, source: (width, height), tile: tile))
        #expect(!covers(edge - 1, source: (width, height), tile: tile))
        #expect(tile.fallbackEdge == 848)
    }

    @Test func thumbnailCoverageAtOneXAndOldRuleSavings() {
        let tile = ThumbnailCoverage(width: 212, height: 148)
        for source in [(1000.0, 1000.0), (600.0, 400.0), (800.0, 400.0), (400.0, 600.0)] {
            let edge = tile.edge(sourceWidth: source.0, sourceHeight: source.1)
            #expect(covers(edge, source: source, tile: tile))
            #expect(!covers(edge - 1, source: source, tile: tile))
        }
        // Square and 3:2 sources decode about a quarter of the old 2× rule's pixels.
        let retina = ThumbnailCoverage(width: 424, height: 296)
        for source in [(1000.0, 1000.0), (600.0, 400.0)] {
            let edge = Double(retina.edge(sourceWidth: source.0, sourceHeight: source.1))
            #expect(edge * edge <= 0.28 * Double(retina.fallbackEdge * retina.fallbackEdge))
        }
    }

    @Test func thumbnailCoverageClampsAndFallsBack() {
        let tile = ThumbnailCoverage(width: 424, height: 296)
        #expect(tile.edge(sourceWidth: 400, sourceHeight: 1600) == 1024)
        #expect(tile.edge(sourceWidth: 100, sourceHeight: 80) == 100)
        for (w, h) in [(0.0, 0.0), (.nan, 400), (600, .infinity), (-600, 400)] {
            #expect(tile.edge(sourceWidth: w, sourceHeight: h) == 848)
        }
        #expect(ThumbnailCoverage(width: 0, height: 0).fallbackEdge == 0)
        #expect(ThumbnailCoverage(width: 0, height: 0).edge(sourceWidth: 600, sourceHeight: 400) == 0)
        #expect(ThumbnailCoverage(width: 900, height: 700).fallbackEdge == 1024)
    }

    @Test func thumbnailCoverageLawHoldsForRandomTilesAndSources() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let tile = ThumbnailCoverage(width: Double(Int.random(in: 1...1024, using: &generator)),
                                         height: Double(Int.random(in: 1...1024, using: &generator)))
            let source = (Double(Int.random(in: 1...20000, using: &generator)), Double(Int.random(in: 1...20000, using: &generator)))
            let edge = tile.edge(sourceWidth: source.0, sourceHeight: source.1)
            let long = Int(max(source.0, source.1))
            #expect(edge >= 1 && edge <= tile.ceiling && edge <= long)
            if edge < min(tile.ceiling, long) {
                #expect(covers(edge, source: source, tile: tile), "\(tile) \(source) \(edge)")
                #expect(!covers(edge - 1, source: source, tile: tile), "\(tile) \(source) \(edge)")
            }
        }
    }
}
