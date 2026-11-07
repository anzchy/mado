import CoreGraphics
import Testing
import MadoCore

@Test func canvasFitLandscapePortraitAndDisplayedOrientation() {
    // Each tuple is independently worked in view points: source, viewport, scale, zoom, origin.
    let cases: [(CGSize, CGSize, Double, Double, CGPoint)] = [
        (.init(width: 800, height: 400), .init(width: 432, height: 232), 1, 0.5, .init(x: 16, y: 16)),
        (.init(width: 800, height: 400), .init(width: 232, height: 432), 1, 0.25, .init(x: 16, y: 166)),
        (.init(width: 400, height: 800), .init(width: 432, height: 232), 1, 0.25, .init(x: 166, y: 16)),
        (.init(width: 400, height: 800), .init(width: 232, height: 432), 1, 0.5, .init(x: 16, y: 16)),
        (.init(width: 800, height: 400), .init(width: 432, height: 232), 2, 1, .init(x: 16, y: 16)),
        (.init(width: 800, height: 400), .init(width: 232, height: 432), 2, 0.5, .init(x: 16, y: 166)),
        (.init(width: 400, height: 800), .init(width: 432, height: 232), 2, 0.5, .init(x: 166, y: 16)),
        (.init(width: 400, height: 800), .init(width: 232, height: 432), 2, 1, .init(x: 16, y: 16)),
        (.init(width: 80, height: 40), .init(width: 432, height: 232), 1, 1, .init(x: 176, y: 96)),
        (.init(width: 80, height: 40), .init(width: 432, height: 232), 2, 1, .init(x: 196, y: 106))
    ]
    for (source, viewport, scale, zoom, origin) in cases {
        let fit = CanvasTransform.fitted(source: source, viewport: viewport, backingScale: scale)
        #expect(fit.zoom == zoom)
        #expect(fit.origin == origin)
    }

}

@Test func canvasFitAtOneSnapsOddDifferencesToBackingGrid() {
    let cases: [(CGSize, Double, CGPoint)] = [
        (.init(width: 433, height: 233), 1, .init(x: 177, y: 97)),
        (.init(width: 432.5, height: 232.5), 2, .init(x: 196.5, y: 106.5)),
        (.init(width: 433, height: 233), 2, .init(x: 196.5, y: 106.5))
    ]
    for (viewport, scale, origin) in cases {
        let fit = CanvasTransform.fitted(source: .init(width: 80, height: 40),
                                         viewport: viewport, backingScale: scale)
        #expect(fit.zoom == 1)
        #expect(fit.origin == origin)
    }
}
