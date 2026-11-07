import Foundation
import Testing
import MadoCore

@Suite struct CanvasDecodePolicyTests {
    @Test func zoomSequenceNeedsOnlyPreviewAndOneDetailDecode() {
        for source in [CGSize(width: 8000, height: 6000), CGSize(width: 6000, height: 8000)] {
            let viewport = CGSize(width: 1920, height: 1280)
            let fit = min(viewport.width / source.width, viewport.height / source.height)
            var completed = 0
            var requested: [Int] = []
            // Model the adapter's completed-maximum guard with each decode finishing
            // before the next input: this is the worst case for repeated zoom decodes.
            for zoom in [fit] + (1...100).map({ fit * pow(1.025, Double($0)) }) + [1, 0.1, 2, 64] {
                let maximum = CanvasDecodePolicy.maximumPixelSize(source: source, viewport: viewport, zoom: zoom)
                if maximum > completed {
                    requested.append(maximum)
                    completed = maximum
                }
            }
            #expect(requested == [1920, 8000])
            #expect(CanvasDecodePolicy.maximumPixelSize(source: source, viewport: viewport, zoom: fit / 2) == 1920)
        }
        #expect(CanvasDecodePolicy.maximumPixelSize(source: CGSize(width: 64, height: 32),
            viewport: CGSize(width: 1920, height: 1280), zoom: 1) == 64)
    }
}
