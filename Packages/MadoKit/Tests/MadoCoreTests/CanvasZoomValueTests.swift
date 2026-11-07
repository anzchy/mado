import CoreGraphics
import Testing
import MadoCore

@Suite struct CanvasZoomValueTests {
    @Test func interiorZoomHasRequestedValueAndBackingPixelDistance() {
        for scale in [1.0, 2.0] {
            var transform = CanvasTransform(backingScale: scale, origin: CGPoint(x: 13.75, y: -8.125))
            let anchor = CGPoint(x: 91.125, y: 183.75)
            for requested in [0.5, 1.25, 3.75, 1.1, 1.0 / 1.1] {
                transform.zoom(to: requested, about: anchor)
                #expect(abs(transform.zoom - requested) < 1e-10)
                let a = transform.imageToBacking(CGPoint(x: 7, y: 11))
                let b = transform.imageToBacking(CGPoint(x: 8, y: 12))
                #expect(abs(b.x - a.x - requested) < 1e-10)
                #expect(abs(b.y - a.y - requested) < 1e-10)
            }
            transform.zoom(to: 1, about: anchor)
            for _ in 0..<100 {
                transform.zoom(to: transform.zoom * 1.1, about: anchor)
                #expect(abs(transform.zoom - 1.1) < 1e-10)
                transform.zoom(to: transform.zoom / 1.1, about: anchor)
                #expect(abs(transform.zoom - 1) < 1e-10)
            }
            let nextScale = scale == 1 ? 2.0 : 1.0
            transform.setBackingScale(nextScale, about: anchor)
            #expect(transform.backingScale == nextScale)
        }
    }
}
