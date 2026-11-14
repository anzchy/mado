import CoreGraphics
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
@Test(.serialized, .timeLimit(.minutes(2)), arguments: RedactionTextSample.all)
func issue693MinimumMosaicLeavesVisionNoCharacterOfTheLine(sample: RedactionTextSample) throws {
    let original = RedactionVision.characters(sample.text)
    #expect(RedactionVision.matched(try RedactionVision.recognise(sample.image), original: sample.text) == original,
            "control: Vision must read \(sample) before the mosaic")
    let redacted = try RedactionRenderer.render(sample.image, rect: sample.lineRect, style: .mosaic(strength: 1))
    let read = try RedactionVision.recognise(redacted)
    #expect(RedactionVision.matched(read, original: sample.text).isEmpty, "\(sample) read as \(read)")
}
