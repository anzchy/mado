import CoreGraphics
import Testing
import MadoCore
@testable import MadoInfrastructure

/// `left + cell` overflowed for `.mosaic(strength: .max)` with a rect not at the origin, and the process trapped.
@Test(.timeLimit(.minutes(2))) func issue693HugeMosaicStrengthDoesNotTrap() async {
    await #expect(processExitsWith: .success) {
        let source = RedactionPixels.distinct(width: 12, height: 10)
        _ = try? RedactionRenderer.render(source.image, rect: CGRect(x: 5, y: 3, width: 6, height: 4),
                                          style: .mosaic(strength: .max))
    }
}

/// A cell wider than the rect is the rect: the whole rect becomes one cell.
@Test func issue693MosaicStrengthBeyondTheRectIsOneCell() throws {
    let source = RedactionPixels.distinct(width: 40, height: 30)
    let rect = CGRect(x: 5, y: 3, width: 30, height: 20)
    let whole = try RedactionRenderer.pixelate(source.image, rect: rect, cell: 30)
    for strength in [31, 1_000, Int.max] {
        let result = try RedactionRenderer.render(source.image, rect: rect, style: .mosaic(strength: strength))
        #expect(RedactionPixels(result) == RedactionPixels(whole), "strength \(strength)")
    }
}
