import CoreGraphics
import Foundation
import Testing
import MadoCore
import MadoApplication

// #690 (P7-11) WI-1: flattening marks into the upright pixels of an image.

private typealias RGBA = (r: UInt8, g: UInt8, b: UInt8, a: UInt8)

/// A sRGB RGBA8 bitmap with its top row first.
private struct Bitmap: Equatable {
    let width: Int, height: Int
    var bytes: [UInt8]
    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let i = (y * width + x) * 4
        return Array(bytes[i..<i + 4])
    }
}

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

private func makeImage(_ bitmap: Bitmap) -> CGImage {
    let provider = CGDataProvider(data: Data(bitmap.bytes) as CFData)!
    return CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: bitmap.width * 4, space: sRGB,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func read(_ image: CGImage) -> Bitmap {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return Bitmap(width: image.width, height: image.height, bytes: bytes)
}

/// Top-left red, top-right green, bottom-left blue, bottom-right grey.
private func quadrant(width: Int = 64, height: Int = 32) -> Bitmap {
    var bytes: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            switch (x < width / 2, y < height / 2) {
            case (true, true): bytes += [255, 0, 0, 255]
            case (false, true): bytes += [0, 255, 0, 255]
            case (true, false): bytes += [0, 0, 255, 255]
            case (false, false): bytes += [128, 128, 128, 255]
            }
        }
    }
    return Bitmap(width: width, height: height, bytes: bytes)
}

/// EXIF orientation as a hand-written index remap: the stored pixel shown at displayed (x, y).
private func upright(_ source: Bitmap, _ orientation: Int) -> Bitmap {
    let w = source.width, h = source.height
    let swapped = orientation >= 5
    let dw = swapped ? h : w, dh = swapped ? w : h
    var bytes = [UInt8](repeating: 0, count: dw * dh * 4)
    for y in 0..<dh {
        for x in 0..<dw {
            let (sx, sy): (Int, Int) = switch orientation {
            case 2: (w - 1 - x, y)
            case 3: (w - 1 - x, h - 1 - y)
            case 4: (x, h - 1 - y)
            case 5: (y, x)
            case 6: (y, h - 1 - x)
            case 7: (w - 1 - y, h - 1 - x)
            case 8: (w - 1 - y, x)
            default: (x, y)
            }
            let s = (sy * w + sx) * 4, d = (y * dw + x) * 4
            bytes[d..<d + 4] = source.bytes[s..<s + 4]
        }
    }
    return Bitmap(width: dw, height: dh, bytes: bytes)
}

private var styleRGBA: [UInt8] {
    let style = AnnotationStyle.default
    return [UInt8((style.red * 255).rounded()), UInt8((style.green * 255).rounded()), UInt8((style.blue * 255).rounded()), 255]
}

private func near(_ a: [UInt8], _ b: [UInt8], tolerance: Int = 2) -> Bool {
    zip(a, b).allSatisfy { abs(Int($0) - Int($1)) <= tolerance }
}

@Test(.timeLimit(.minutes(2))) func flattenStrokeTakesStyleColour() throws {
    let source = quadrant()
    let mark = AnnotationMark(rect: CGRect(x: 8, y: 8, width: 24, height: 16))
    let out = read(try AnnotationFlattener.flatten(makeImage(source), orientation: 1, marks: [mark]))
    try #require(out.width == 64 && out.height == 32)
    #expect(near(out.pixel(8, 16), styleRGBA), "\(out.pixel(8, 16))")
    #expect(near(out.pixel(31, 12), styleRGBA), "right edge at x = 32")
    #expect(near(out.pixel(20, 8), styleRGBA), "top edge at y = 8")
    #expect(near(out.pixel(20, 14), [255, 0, 0, 255]), "inside, off the stroke: not filled")
}

@Test(.timeLimit(.minutes(2))) func flattenFarPixelKeepsSource() throws {
    let source = quadrant()
    let mark = AnnotationMark(rect: CGRect(x: 8, y: 8, width: 24, height: 16))
    let out = read(try AnnotationFlattener.flatten(makeImage(source), orientation: 1, marks: [mark]))
    #expect(out.pixel(60, 28) == [128, 128, 128, 255])
    #expect(out.pixel(60, 2) == [0, 255, 0, 255])
}

@Test(.timeLimit(.minutes(2))) func flattenOrientation6PlacesMarkAtDisplayedSpot() throws {
    let source = quadrant()
    let mark = AnnotationMark(rect: CGRect(x: 2, y: 2, width: 8, height: 8))
    let out = read(try AnnotationFlattener.flatten(makeImage(source), orientation: 6, marks: [mark]))
    try #require(out.width == 32 && out.height == 64)
    #expect(near(out.pixel(2, 6), styleRGBA), "\(out.pixel(2, 6))")
    #expect(out.pixel(28, 4) == [255, 0, 0, 255], "the stored top-left shows at the displayed top-right")
    #expect(out.pixel(4, 60) == [128, 128, 128, 255])
    #expect(AnnotationFlattener.uprightSize(width: 64, height: 32, orientation: 6) == (32, 64))
}

@Test(.timeLimit(.minutes(2))) func flattenEmptyMarksPixelIdenticalAllOrientations() throws {
    let source = quadrant(width: 6, height: 4)
    for orientation in 1...8 {
        let out = read(try AnnotationFlattener.flatten(makeImage(source), orientation: orientation, marks: []))
        #expect(out == upright(source, orientation), "orientation \(orientation)")
        let size = AnnotationFlattener.uprightSize(width: 6, height: 4, orientation: orientation)
        #expect(size == (orientation >= 5 ? (4, 6) : (6, 4)), "orientation \(orientation)")
    }
    #expect(AnnotationFlattener.uprightSize(width: 6, height: 4, orientation: 0) == (6, 4), "unknown is upright")
}

@Test(.timeLimit(.minutes(2))) func flattenOutsideStrokeBandUnchangedSeeded() throws {
    let source = quadrant(width: 40, height: 24)
    let image = makeImage(source)
    let half = AnnotationStyle.default.lineWidth / 2 + 2
    for seed in UInt64(0)..<200 {
        var random = AnnotationRandom(seed: seed)
        let orientation = Int.random(in: 1...8, using: &random)
        let expected = upright(source, orientation)
        var marks: [AnnotationMark] = []
        for _ in 0..<Int.random(in: 1...4, using: &random) {
            let x = Int.random(in: 0..<(expected.width - 6), using: &random)
            let y = Int.random(in: 0..<(expected.height - 6), using: &random)
            let w = Int.random(in: 6...(expected.width - x), using: &random)
            let h = Int.random(in: 6...(expected.height - y), using: &random)
            marks.append(AnnotationMark(rect: CGRect(x: x, y: y, width: w, height: h)))
        }
        let out = read(try AnnotationFlattener.flatten(image, orientation: orientation, marks: marks))
        try #require(out.width == expected.width && out.height == expected.height, "seed \(seed)")
        func distance(_ px: Double, _ py: Double, _ r: CGRect) -> Double {
            let edges = [abs(px - r.minX), abs(px - r.maxX), abs(py - r.minY), abs(py - r.maxY)]
            let inX = px >= r.minX - half && px <= r.maxX + half, inY = py >= r.minY - half && py <= r.maxY + half
            return min(inY ? min(edges[0], edges[1]) : .infinity, inX ? min(edges[2], edges[3]) : .infinity)
        }
        var mismatches = 0
        for y in 0..<out.height {
            for x in 0..<out.width {
                let centre = (Double(x) + 0.5, Double(y) + 0.5)
                guard marks.allSatisfy({ distance(centre.0, centre.1, $0.rect) > half }) else { continue }
                if out.pixel(x, y) != expected.pixel(x, y) { mismatches += 1 }
            }
        }
        #expect(mismatches == 0, "seed \(seed) orientation \(orientation)")
        let first = marks[0].rect
        #expect(near(out.pixel(Int(first.minX), Int(first.midY)), styleRGBA), "seed \(seed)")
    }
}

@Test(.timeLimit(.minutes(2))) func flattenClipsOutOfBoundsMark() throws {
    let source = quadrant()
    let image = makeImage(source)
    let crossing = read(try AnnotationFlattener.flatten(image, orientation: 1,
        marks: [AnnotationMark(rect: CGRect(x: -20, y: -20, width: 200, height: 200))]))
    try #require(crossing.width == 64 && crossing.height == 32)
    #expect(crossing.pixel(32, 16) == source.pixel(32, 16))
    #expect(crossing.pixel(1, 1) == source.pixel(1, 1))
    let outside = read(try AnnotationFlattener.flatten(image, orientation: 1,
        marks: [AnnotationMark(rect: CGRect(x: 500, y: 500, width: 10, height: 10))]))
    #expect(outside == source)
}

@Test(.timeLimit(.minutes(2))) func flattenDoesNotMutateSource() throws {
    let source = quadrant()
    let image = makeImage(source)
    let marks = [AnnotationMark(rect: CGRect(x: 4, y: 4, width: 10, height: 10))]
    let first = read(try AnnotationFlattener.flatten(image, orientation: 6, marks: marks))
    #expect(read(image) == source)
    let second = read(try AnnotationFlattener.flatten(image, orientation: 6, marks: marks))
    #expect(first == second)
    #expect(first != upright(source, 6), "the mark was drawn")
}
