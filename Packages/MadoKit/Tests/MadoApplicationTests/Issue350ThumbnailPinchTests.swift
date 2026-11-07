import Foundation
import Testing
import MadoApplication

@Test func issue350PinchMappingLaws() {
    var seed: UInt64 = 0x350
    func random() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double(seed >> 11) / Double(UInt64.max >> 11)
    }
    for _ in 0..<2_000 {
        let start = 100 + random() * 220
        let a = -4 + random() * 8, b = -4 + random() * 8
        let lower = ThumbnailSizeGesture.size(from: start, magnification: min(a, b))
        let upper = ThumbnailSizeGesture.size(from: start, magnification: max(a, b))
        #expect(lower.isFinite && upper.isFinite && lower >= 140 && upper <= 280)
        #expect(lower <= upper)
        #expect(lower == ThumbnailSizeGesture.size(from: start, magnification: min(a, b)))
        #expect(ThumbnailSizeGesture.size(from: start, magnification: 0) == min(280, max(140, start)))
        let interior = 180 + random() * 40
        let x = random() * 0.08 - 0.04, y = random() * 0.08 - 0.04
        let composed = ThumbnailSizeGesture.size(from: ThumbnailSizeGesture.size(from: interior, magnification: x), magnification: y)
        #expect(abs(composed - ThumbnailSizeGesture.size(from: interior, magnification: x + y)) < 0.000_001)
        let normalized = DisplayPreferences.normalizedThumbnailSize(lower)
        #expect((140...280).contains(normalized) && normalized.truncatingRemainder(dividingBy: 10) == 0)
    }
}

@Test func issue350PinchMappingBoundariesAndInvalidValues() {
    #expect(abs(ThumbnailSizeGesture.size(from: 200, magnification: log(1.2)) - 240) < 0.000_001)
    #expect(abs(ThumbnailSizeGesture.size(from: 200, magnification: log(0.8)) - 160) < 0.000_001)
    #expect(ThumbnailSizeGesture.size(from: 220.25, magnification: 0) == 220.25)
    for start in [140.0, 200, 220.25, 280] {
        #expect(ThumbnailSizeGesture.size(from: start, magnification: .greatestFiniteMagnitude) == 280)
        #expect(ThumbnailSizeGesture.size(from: start, magnification: -.greatestFiniteMagnitude) == 140)
        for invalid in [Double.nan, .infinity, -.infinity] {
            #expect(ThumbnailSizeGesture.size(from: start, magnification: invalid) == start)
        }
    }
    for invalid in [Double.nan, .infinity, -.infinity] {
        #expect(ThumbnailSizeGesture.size(from: invalid, magnification: 0) == 220)
        #expect(abs(ThumbnailSizeGesture.size(from: invalid, magnification: log(1.1)) - 242) < 0.000_001)
    }
}
