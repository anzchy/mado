import CoreGraphics
import Testing
import MadoCore

@Suite struct CanvasPixelSnapTests {
    @Test func actualPixelsSnapsFractionalAnchorAtBothBackingScales() {
        for scale in [1.0, 2.0] {
            var transform = CanvasTransform(backingScale: scale, zoom: 0.37,
                                            origin: CGPoint(x: 13.17, y: -28.23))
            let anchor = CGPoint(x: 91.125, y: 183.75)
            let pixel = transform.viewToImage(anchor)
            transform.actualPixels(about: anchor)
            let origin = transform.imageToBacking(.zero)
            #expect(abs(origin.x - origin.x.rounded()) < 1e-10)
            #expect(abs(origin.y - origin.y.rounded()) < 1e-10)
            let snappedAnchor = transform.imageToBacking(pixel)
            #expect(abs(snappedAnchor.x - anchor.x * scale) <= 0.5 + 1e-10)
            #expect(abs(snappedAnchor.y - anchor.y * scale) <= 0.5 + 1e-10)
            let adjacent = transform.imageToBacking(CGPoint(x: 1, y: 1))
            #expect(abs(adjacent.x - origin.x - 1) < 1e-10)
            #expect(abs(adjacent.y - origin.y - 1) < 1e-10)
            transform.actualPixels(about: anchor)
            #expect(transform.imageToBacking(.zero) == origin)
        }
    }
}
