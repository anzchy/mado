import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func issue693RenderClampsMosaicStrengthToTheMinimum() throws {
    let source = RedactionPixels.distinct(width: 48, height: 40)
    let rect = CGRect(x: 2, y: 3, width: 44, height: 35)
    let minimum = RedactionStyle.minimumMosaicStrength
    for weak in [1, minimum - 1] {
        let rendered = try RedactionRenderer.render(source.image, rect: rect, style: .mosaic(strength: weak))
        #expect(RedactionPixels(rendered) == RedactionPixels(try RedactionRenderer.pixelate(source.image, rect: rect,
                                                                                               cell: minimum)))
    }
    let strong = try RedactionRenderer.render(source.image, rect: rect, style: .mosaic(strength: minimum + 4))
    #expect(RedactionPixels(strong) == RedactionPixels(try RedactionRenderer.pixelate(source.image, rect: rect,
                                                                                         cell: minimum + 4)))
}

/// Decision 5.3: the weakest mosaic makes a line of body text unreadable. Vision `.accurate` reads every sample
/// before the mosaic and no character of it afterwards. Serialized: parallel cases starve the cooperative pool
/// while Vision waits for its own capacity-limited queue, and the run deadlocks.
///
/// Opt-in (`MADO_VISION_MEASURE=1`): its result depends on the host's Vision build and system font, so the default
/// lane (and CI) does not run it; the pure tests above and `issue693MinimumMosaicStrengthIsTheMeasuredSafeValue`
/// hold the minimum there. When enabled, a Vision that cannot read the unredacted control fails the test.
/// Rerun: docs/validation/P7-693-mosaic-minimum.md.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MADO_VISION_MEASURE"] == "1", "set MADO_VISION_MEASURE=1"),
      .serialized, .timeLimit(.minutes(2)), arguments: RedactionTextSample.all)
func issue693MinimumMosaicLeavesVisionNoCharacterOfTheLine(sample: RedactionTextSample) throws {
    let original = RedactionVision.characters(sample.text)
    try #require(RedactionVision.matched(try RedactionVision.recognise(sample.image), original: sample.text) == original,
                 "control: Vision must read \(sample) before the mosaic; Vision is unavailable or reads differently here")
    let redacted = try RedactionRenderer.render(sample.image, rect: sample.lineRect, style: .mosaic(strength: 1))
    let read = try RedactionVision.recognise(redacted)
    #expect(RedactionVision.matched(read, original: sample.text).isEmpty, "\(sample) read as \(read)")
}
