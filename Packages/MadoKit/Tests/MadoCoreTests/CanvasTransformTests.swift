import CoreGraphics
import Foundation
import Testing
import MadoCore

@Suite struct CanvasTransformTests {
    private func close(_ a: CGPoint, _ b: CGPoint) {
        #expect(abs(a.x - b.x) < 0.0000001)
        #expect(abs(a.y - b.y) < 0.0000001)
    }

    @Test func actualPixelsAndInverseAtBothBackingScales() {
        for scale in [1.0, 2.0] {
            var transform = CanvasTransform(backingScale: scale, zoom: 0.25, origin: CGPoint(x: 17, y: -9))
            let centre = CGPoint(x: 320.5, y: 210.25)
            let centredPixel = transform.viewToImage(centre)
            transform.actualPixels(about: centre)
            #expect(transform.zoom == 1)
            let snappedCentre = transform.imageToView(centredPixel)
            #expect(abs(snappedCentre.x - centre.x) <= 0.5 / scale)
            #expect(abs(snappedCentre.y - centre.y) <= 0.5 / scale)
            for pixel in [CGPoint.zero, CGPoint(x: 3.25, y: 8.75), CGPoint(x: -123.5, y: 900.125)] {
                close(transform.viewToImage(transform.imageToView(pixel)), pixel)
                let start = transform.imageToBacking(pixel)
                let diagonal = transform.imageToBacking(CGPoint(x: pixel.x + 1, y: pixel.y + 1))
                close(CGPoint(x: diagonal.x - start.x, y: diagonal.y - start.y), CGPoint(x: 1, y: 1))
            }
            var known = CanvasTransform(backingScale: scale, origin: CGPoint(x: 10, y: 20))
            close(known.imageToView(CGPoint(x: 4, y: 8)), CGPoint(x: 10 + 4 / scale, y: 20 + 8 / scale))
            known.setBackingScale(scale == 1 ? 2 : 1, about: centre)
            #expect(known.zoom == 1)
            let a = known.imageToBacking(.zero)
            let b = known.imageToBacking(CGPoint(x: 1, y: 1))
            close(CGPoint(x: b.x - a.x, y: b.y - a.y), CGPoint(x: 1, y: 1))
        }
    }

    @Test func anchorsSurviveRepeatedStepsLimitsAndScaleChanges() {
        for scale in [1.0, 2.0] {
            for anchor in [CGPoint.zero, CGPoint(x: 91.125, y: 183.75), CGPoint(x: -17.25, y: 42.5)] {
                var transform = CanvasTransform(backingScale: scale, origin: CGPoint(x: 13.75, y: -28.25))
                let pixel = transform.viewToImage(anchor)
                for proposed in [2.0, 0.5, 1.25, 3.75, 0.125, 0, 1000, .infinity, .nan, 1] {
                    transform.zoom(to: proposed, about: anchor)
                    #expect(CanvasTransform.zoomLimits.contains(transform.zoom))
                    close(transform.imageToView(pixel), anchor)
                }
                for _ in 0..<100 {
                    transform.zoom(to: transform.zoom * 1.1, about: anchor)
                    close(transform.imageToView(pixel), anchor)
                    transform.zoom(to: transform.zoom / 1.1, about: anchor)
                    close(transform.imageToView(pixel), anchor)
                }
                transform.zoom(to: 0, about: anchor)
                #expect(transform.zoom == CanvasTransform.zoomLimits.lowerBound)
                transform.zoom(to: 1000, about: anchor)
                #expect(transform.zoom == CanvasTransform.zoomLimits.upperBound)
                transform.setBackingScale(scale == 1 ? 2 : 1, about: anchor)
                close(transform.imageToView(pixel), anchor)
            }
        }
    }
}
