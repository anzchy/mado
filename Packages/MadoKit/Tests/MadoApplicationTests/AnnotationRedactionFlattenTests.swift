import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #693 slice B (P7-11) WI-2: redactions and the crop in the Annotated Copy (tests-20261114-i693b.md F1–F11; brief §2,
// AC-1 and AC-2). Sources are sRGB 8-bit premultiplied RGBA noise, opaque, so a mean is a plain byte mean.

private let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Seeded noise: every pixel differs from its neighbours, so a uniform cell can only come from the mosaic.
private func noise(width: Int, height: Int, seed: UInt64 = 7) -> CGImage {
    var state = seed
    var bytes = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<(width * height) {
        for c in 0..<3 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            bytes[i * 4 + c] = UInt8(truncatingIfNeeded: state >> 56)
        }
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                   space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// Top-left sRGB RGBA bytes.
private struct Pixels: Equatable {
    let width: Int, height: Int, bytes: [UInt8]
    init(_ image: CGImage) {
        width = image.width; height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let (w, h) = (width, height)
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        bytes = data
    }
    subscript(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return (0..<4).map { Int(bytes[i + $0]) }
    }
    /// The pixels of `rect` (whole pixels), as their own bitmap.
    func cut(_ rect: CGRect) -> [[Int]] {
        var out: [[Int]] = []
        for y in Int(rect.minY)..<Int(rect.maxY) { for x in Int(rect.minX)..<Int(rect.maxX) { out.append(self[x, y]) } }
        return out
    }
    var all: [[Int]] { cut(CGRect(x: 0, y: 0, width: width, height: height)) }
}

private func mean(_ p: Pixels, _ xs: Range<Int>, _ ys: Range<Int>) -> [Int] {
    var sum = [0, 0, 0]
    for y in ys { for x in xs { for c in 0..<3 { sum[c] += p[x, y][c] } } }
    let n = Double(xs.count * ys.count)
    return sum.map { Int((Double($0) / n).rounded()) }
}

private func near(_ a: [Int], _ b: [Int], _ tolerance: Int = 1) -> Bool {
    zip(a, b).allSatisfy { abs($0 - $1) <= tolerance }
}

private let unitStyle = AnnotationStyle(red: 220.0 / 255, green: 38.0 / 255, blue: 38.0 / 255, lineWidth: 3)

@Test(.timeLimit(.minutes(2))) func issue693FlattenSolidReplacesEveryPixelInItsRect() throws {
    let source = noise(width: 64, height: 48)
    let rect = CGRect(x: 10, y: 8, width: 20, height: 12)
    let out = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [.redaction(rect: rect, style: .solid)]))
    let original = Pixels(source)
    for y in 0..<48 { for x in 0..<64 {
        if rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
            #expect(out[x, y] == [0, 0, 0, 255], "inside \(x),\(y)")
        } else {
            #expect(out[x, y] == original[x, y], "outside \(x),\(y)")
        }
    } }
}

@Test(.timeLimit(.minutes(2)), arguments: [16, 24]) func issue693FlattenMosaicAtNHasCellSizeN(_ n: Int) throws {
    let source = noise(width: 96, height: 96)
    let rect = CGRect(x: 8, y: 8, width: 64, height: 64)
    let out = Pixels(try AnnotationFlattener.flatten(source, orientation: 1,
                                                     marks: [.redaction(rect: rect, style: .mosaic(strength: n))]))
    let original = Pixels(source)
    var colours: [[Int]] = []
    for cy in stride(from: 8, to: 72, by: n) { for cx in stride(from: 8, to: 72, by: n) {
        let xs = cx..<min(cx + n, 72), ys = cy..<min(cy + n, 72)
        let first = out[cx, cy]
        for y in ys { for x in xs { #expect(out[x, y] == first, "cell \(cx),\(cy) uniform at \(x),\(y)") } }
        #expect(near(Array(first.prefix(3)), mean(original, xs, ys)), "cell \(cx),\(cy) holds its mean")
        colours.append(first)
    } }
    #expect(Set(colours.map { $0.description }).count == colours.count, "neighbouring cells differ")
    for y in 0..<96 { for x in 0..<96 where !rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
        #expect(out[x, y] == original[x, y])
    } }
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenRaisesAWeakMosaicToTheMinimum() throws {
    let source = noise(width: 64, height: 64)
    let rect = CGRect(x: 0, y: 0, width: 64, height: 64)
    let weak = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [.redaction(rect: rect, style: .mosaic(strength: 4))]))
    let minimum = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [.redaction(rect: rect, style: .mosaic(strength: 16))]))
    let four = Pixels(try RedactionRenderer.pixelate(source, rect: rect, cell: 4))
    #expect(weak == minimum, "a mark stored weaker than 16 is drawn at 16")
    #expect(weak != four)
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenCropGivesTheCropSize() throws {
    let source = noise(width: 80, height: 90)
    let crop = CGRect(x: 10, y: 20, width: 30, height: 40)
    let marks: [AnnotationMark] = [AnnotationMark(rect: CGRect(x: 5, y: 5, width: 50, height: 50), style: unitStyle)]
    let cropped = try AnnotationFlattener.flatten(source, orientation: 1, marks: marks, crop: crop)
    #expect(cropped.width == 30 && cropped.height == 40)
    let full = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks))
    #expect(Pixels(cropped).all == full.cut(crop))
    // No crop is the whole image.
    #expect(Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks, crop: nil)) == full)
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenCropComposesWithMarksCrossingItsEdge() throws {
    let source = noise(width: 200, height: 160)
    let crop = CGRect(x: 40, y: 30, width: 100, height: 80)
    let textOrigin = CGPoint(x: 120, y: 60)
    let marks: [AnnotationMark] = [
        AnnotationMark(rect: CGRect(x: 20, y: 50, width: 60, height: 30), style: unitStyle),
        .arrow(tail: CGPoint(x: 90, y: 10), tip: CGPoint(x: 90, y: 70), style: unitStyle),
        .text("Edge", origin: textOrigin, size: AnnotationRenderer.textSize("Edge", fontSize: 18), style: unitStyle),
    ]
    let cropped = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks, crop: crop))
    let full = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks))
    #expect(cropped.width == 100 && cropped.height == 80)
    #expect(cropped.all == full.cut(crop), "the crop cuts the finished copy")
    func isRed(_ p: [Int]) -> Bool { p[0] > 180 && p[1] < 90 && p[2] < 90 }
    // The rectangle's top edge enters at the left crop edge, the arrow's shaft at the top, the text at the right.
    #expect((0..<4).contains { isRed(cropped[$0, 20]) }, "rectangle at the left edge")
    #expect((0..<6).contains { isRed(cropped[50 + $0 - 3, 1]) }, "arrow at the top edge")
    #expect((0..<20).contains { y in (90..<100).contains { isRed(cropped[$0, 30 + y]) } }, "text near the right edge")
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenRedactionFollowsZOrder() throws {
    let source = noise(width: 100, height: 100)
    let rectangle = AnnotationMark(rect: CGRect(x: 20, y: 20, width: 60, height: 60), style: unitStyle)
    let solid = AnnotationMark.redaction(rect: CGRect(x: 10, y: 10, width: 40, height: 40), style: .solid)
    // The rectangle's stroke at (20, 30) lies under the solid when the solid comes last…
    let under = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [rectangle, solid]))
    #expect(under[20, 30] == [0, 0, 0, 255])
    // …and over it when the solid comes first.
    let over = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [solid, rectangle]))
    #expect(near(Array(over[20, 30].prefix(3)), [220, 38, 38], 2))
    #expect(over[15, 15] == [0, 0, 0, 255])
    // A mosaic over a red mark mixes the red into its cells.
    let filled = AnnotationMark(rect: CGRect(x: 0, y: 0, width: 16, height: 16), style: AnnotationStyle(red: 220.0 / 255,
        green: 38.0 / 255, blue: 38.0 / 255, lineWidth: 40))
    let mosaic = AnnotationMark.redaction(rect: CGRect(x: 0, y: 0, width: 16, height: 16), style: .mosaic(strength: 16))
    let withMark = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [filled]))
    let mixed = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: [filled, mosaic]))
    #expect(near(Array(mixed[3, 3].prefix(3)), mean(withMark, 0..<16, 0..<16)), "the cell is the mean of the drawn pixels")
    #expect(!near(Array(mixed[3, 3].prefix(3)), mean(Pixels(source), 0..<16, 0..<16), 4), "not the mean of the bare source")
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenCropAppliesAfterOrientation() throws {
    let source = noise(width: 60, height: 40)
    let crop = CGRect(x: 5, y: 10, width: 20, height: 30)
    let marks: [AnnotationMark] = [.redaction(rect: CGRect(x: 0, y: 0, width: 16, height: 16), style: .solid)]
    let cropped = try AnnotationFlattener.flatten(source, orientation: 6, marks: marks, crop: crop)
    #expect(cropped.width == 20 && cropped.height == 30)
    let full = Pixels(try AnnotationFlattener.flatten(source, orientation: 6, marks: marks))
    #expect(full.width == 40 && full.height == 60)
    #expect(Pixels(cropped).all == full.cut(crop))
}

@Test(.timeLimit(.minutes(2)), arguments: [1, 6]) func issue693RedactionPatchMatchesTheCopy(_ orientation: Int) throws {
    let source = noise(width: 120, height: 100)
    let marks: [AnnotationMark] = [
        AnnotationMark(rect: CGRect(x: 10, y: 10, width: 50, height: 40), style: unitStyle),
        .redaction(rect: CGRect(x: 5.5, y: 8.25, width: 40, height: 30), style: .mosaic(strength: 16)),
        .redaction(rect: CGRect(x: 30, y: 20, width: 30, height: 30), style: .solid),
        AnnotationMark.arrow(tail: CGPoint(x: 0, y: 0), tip: CGPoint(x: 80, y: 60), style: unitStyle),
        .redaction(rect: CGRect(x: 20, y: 15, width: 60, height: 50), style: .mosaic(strength: 24)),
    ]
    for index in [1, 2, 4] {
        let patch = try #require(try AnnotationFlattener.redactionPatch(source, orientation: orientation, marks: marks, index: index))
        let area = patch.area
        #expect(area.contains(marks[index].rect), "the patch covers the mark \(index)")
        #expect(area == area.integral, "whole pixels")
        #expect(patch.image.width == Int(area.width) && patch.image.height == Int(area.height))
        let expected = Pixels(try AnnotationFlattener.flatten(source, orientation: orientation,
                                                              marks: Array(marks[0...index]))).cut(area)
        #expect(Pixels(patch.image).all == expected, "patch \(index) is the copy's pixels with the marks up to it")
    }
    #expect(try AnnotationFlattener.redactionPatch(source, orientation: orientation, marks: marks, index: 0) == nil,
            "not a redaction")
    #expect(try AnnotationFlattener.redactionPatch(source, orientation: orientation, marks: marks, index: 9) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenCropCutsAfterAMosaicAcrossItsEdge() throws {
    let source = noise(width: 96, height: 96)
    let marks: [AnnotationMark] = [.redaction(rect: CGRect(x: 8, y: 8, width: 64, height: 64), style: .mosaic(strength: 16))]
    let crop = CGRect(x: 20, y: 20, width: 40, height: 40)
    let cropped = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks, crop: crop))
    let full = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks))
    #expect(cropped.all == full.cut(crop))
    // The cell straddling x = 20 holds the mean over x 8…23, not 20…23.
    #expect(near(Array(cropped[0, 0].prefix(3)), mean(Pixels(source), 8..<24, 8..<24)))
}

@Test(.timeLimit(.minutes(2))) func issue693FlattenMosaicOverASolidStaysBlack() throws {
    let source = noise(width: 64, height: 64)
    let marks: [AnnotationMark] = [.redaction(rect: CGRect(x: 0, y: 0, width: 32, height: 32), style: .solid),
                                   .redaction(rect: CGRect(x: 0, y: 0, width: 48, height: 48), style: .mosaic(strength: 16))]
    let out = Pixels(try AnnotationFlattener.flatten(source, orientation: 1, marks: marks))
    for y in 0..<32 { for x in 0..<32 { #expect(out[x, y] == [0, 0, 0, 255], "\(x),\(y)") } }
}

// Coverage (tests-20261114-i693b.md, coverage phase): the edge cases the matrix rows imply.

@Test(.timeLimit(.minutes(2))) func issue693FlattenRejectsACropOutsideTheImage() throws {
    let source = noise(width: 32, height: 24)
    #expect(throws: (any Error).self) {
        try AnnotationFlattener.flatten(source, orientation: 1, marks: [], crop: CGRect(x: 40, y: 30, width: 8, height: 8))
    }
    // Partly outside: cut to the image.
    let partial = try AnnotationFlattener.flatten(source, orientation: 1, marks: [], crop: CGRect(x: 24, y: 16, width: 20, height: 20))
    #expect(partial.width == 8 && partial.height == 8)
}

@Test(.timeLimit(.minutes(2))) func issue693RedactionPatchIsNilOffTheImageOrForOtherMarks() throws {
    let source = noise(width: 32, height: 24)
    let outside = AnnotationMark.redaction(rect: CGRect(x: 40, y: 30, width: 8, height: 8), style: .solid)
    #expect(try AnnotationFlattener.redactionPatch(source, orientation: 1, marks: [outside], index: 0) == nil)
    let rectangle = AnnotationMark(rect: CGRect(x: 2, y: 2, width: 8, height: 8))
    #expect(try AnnotationFlattener.redactionPatch(source, orientation: 1, marks: [rectangle], index: 0) == nil)
    #expect(try AnnotationFlattener.redactionPatch(source, orientation: 1, marks: [rectangle], index: 3) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue693RendererNeverDrawsARedactionItself() throws {
    let width = 24, height = 16
    var data = [UInt8](repeating: 200, count: width * height * 4)
    let unchanged = data
    data.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        AnnotationRenderer.draw([.redaction(rect: CGRect(x: 2, y: 2, width: 12, height: 8), style: .solid)], in: context)
    }
    #expect(data == unchanged, "without a redact closure a redaction leaves the context as it was")
}
