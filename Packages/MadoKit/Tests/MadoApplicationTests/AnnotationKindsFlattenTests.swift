import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #692 (P7-11) WI-2: every mark kind flattened into the Annotated Copy at image pixels. Sources are 400×300 sRGB
// 8-bit, marks at lineWidth 3 (one image pixel per screen point). Expected pixels were worked out by hand from
// page 39 (annotate.html): #dc2626 = (220,38,38); the highlighter is #dc2626 at 35% over the source.

private let white: [UInt8] = [255, 255, 255]
private let black: [UInt8] = [0, 0, 0]
private let red = [220, 38, 38]

private func source(_ rgb: [UInt8], width: Int = 400, height: Int = 300) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(colorSpace: space, components: rgb.map { CGFloat($0) / 255 } + [1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

/// Top-left-origin sRGB bytes of an image.
private struct Pixels {
    let width: Int, height: Int, bytes: [UInt8]
    init(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        bytes = data
    }
    subscript(_ x: Int, _ y: Int) -> [Int] {
        let i = (y * width + x) * 4
        return [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
    }
    func region(_ r: CGRect) -> [Int] {
        var out: [Int] = []
        for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { out += self[x, y] } }
        return out
    }
}

private func near(_ p: [Int], _ q: [Int], _ tolerance: Int) -> Bool { zip(p, q).allSatisfy { abs($0 - $1) <= tolerance } }

private func flat(_ marks: [AnnotationMark], on rgb: [UInt8] = white, orientation: Int = 1,
                  width: Int = 400, height: Int = 300) throws -> Pixels {
    Pixels(try AnnotationFlattener.flatten(source(rgb, width: width, height: height), orientation: orientation, marks: marks))
}

private let unit = AnnotationStyle.default
private var double: AnnotationStyle { var s = unit; s.lineWidth = 6; return s }

// MARK: - Arrow (F1, F1b, F1c)

@Test(.timeLimit(.minutes(2))) func issue692FlattenArrowShaftAndOpenHead() throws {
    let p = try flat([.arrow(tail: CGPoint(x: 50, y: 250), tip: CGPoint(x: 250, y: 50), style: unit)])
    // The shaft is the line x + y = 300; pixel centres on it and 0.7 px off it are red.
    #expect(near(p[149, 150], red, 6), "\(p[149, 150])")
    #expect(near(p[150, 150], red, 6), "1 px off the shaft: \(p[150, 150])")
    #expect(near(p[153, 151], [255, 255, 255], 2), "3.5 px off the shaft: \(p[153, 151])")
    // The arm ends, by hand: tip (250,50) + 14·(cos 177°, sin 177°) = (236.0, 50.7) and 14·(cos 93°, sin 93°) = (249.3, 64.0).
    #expect(near(p[237, 50], red, 6), "first arm: \(p[237, 50])")
    #expect(near(p[249, 62], red, 6), "second arm: \(p[249, 62])")
    // Inside the V, off the shaft and both arms: page 39's head is open, not a filled triangle.
    #expect(near(p[240, 53], [255, 255, 255], 2), "inside the head: \(p[240, 53])")
    // Past the tip nothing is drawn.
    #expect(near(p[256, 44], [255, 255, 255], 2))
}

// MARK: - Step markers (F2, F3)

@Test(.timeLimit(.minutes(2))) func issue692FlattenStepIsARedDiscWithAWhiteNumber() throws {
    let p = try flat([.step(centre: CGPoint(x: 200, y: 150), style: unit)], on: black)
    #expect(near(p[189, 150], red, 6), "inside the disc, left of the number: \(p[189, 150])")
    #expect(near(p[216, 150], [0, 0, 0], 2), "outside the 28 px disc: \(p[216, 150])")
    #expect(near(p[200, 135], [0, 0, 0], 2), "above the disc")
    let number = p.region(CGRect(x: 194, y: 143, width: 12, height: 14))
    let whites = stride(from: 0, to: number.count, by: 3).filter { number[$0] >= 240 && number[$0 + 1] >= 240 && number[$0 + 2] >= 240 }
    #expect(whites.count >= 6, "the white number: \(whites.count) white pixels")
}

@Test(.timeLimit(.minutes(2))) func issue692FlattenStepNumbersFollowTheMarks() throws {
    let box = CGRect(x: 286, y: 136, width: 28, height: 28)
    let second = try flat([.step(centre: CGPoint(x: 100, y: 150), style: unit), .step(centre: CGPoint(x: 300, y: 150), style: unit)])
    let otherSecond = try flat([.step(centre: CGPoint(x: 50, y: 50), style: unit), .step(centre: CGPoint(x: 300, y: 150), style: unit)])
    let alone = try flat([.step(centre: CGPoint(x: 300, y: 150), style: unit)])
    #expect(second.region(box) == otherSecond.region(box), "both draw 2")
    #expect(second.region(box) != alone.region(box), "a lone marker draws 1")
    // After the middle one of three is deleted, the last draws 2.
    let afterDelete = try flat([.step(centre: CGPoint(x: 100, y: 150), style: unit), .step(centre: CGPoint(x: 300, y: 150), style: unit)])
    #expect(afterDelete.region(box) == second.region(box))
    let three = try flat([.step(centre: CGPoint(x: 100, y: 150), style: unit), .step(centre: CGPoint(x: 200, y: 50), style: unit),
                          .step(centre: CGPoint(x: 300, y: 150), style: unit)])
    #expect(three.region(box) != second.region(box), "the third draws 3")
}

// MARK: - Text (F4, F4b)

@Test(.timeLimit(.minutes(2))) func issue692FlattenTextIsRedWithAWhiteHalo() throws {
    let size = AnnotationRenderer.textSize("Hi", fontSize: 18)
    let mark = AnnotationMark.text("Hi", origin: CGPoint(x: 40, y: 40), size: size, style: unit)
    let p = try flat([mark], on: black)
    let inside = p.region(mark.rect)
    let pixels = stride(from: 0, to: inside.count, by: 3).map { Array(inside[$0..<$0 + 3]) }
    #expect(pixels.contains { near($0, red, 6) }, "red glyph pixels")
    #expect(pixels.contains { $0.allSatisfy { $0 >= 240 } }, "white halo pixels")
    // Nothing is drawn 4 px outside the line box.
    let ring = mark.rect.insetBy(dx: -4, dy: -4)
    for x in Int(ring.minX)..<Int(ring.maxX) {
        #expect(p[x, Int(ring.minY)] == [0, 0, 0] && p[x, Int(ring.maxY)] == [0, 0, 0], "\(x)")
    }
    for y in Int(ring.minY)..<Int(ring.maxY) {
        #expect(p[Int(ring.minX), y] == [0, 0, 0] && p[Int(ring.maxX), y] == [0, 0, 0], "\(y)")
    }
}

@Test(.timeLimit(.minutes(2))) func issue692FlattenTextScalesWithTheStroke() throws {
    func inkRows(_ style: AnnotationStyle) throws -> Int {
        let mark = AnnotationMark.text("H", origin: CGPoint(x: 20, y: 20),
                                       size: AnnotationRenderer.textSize("H", fontSize: 18 * style.unit), style: style)
        let p = try flat([mark], on: black)
        return (0..<300).filter { y in (0..<400).contains { p[$0, y] != [0, 0, 0] } }.count
    }
    let small = try inkRows(unit), large = try inkRows(double)
    // 18 px semibold "H" with its halo: about 16 rows; twice the stroke draws about twice as tall.
    #expect((12...20).contains(small), "\(small)")
    #expect(abs(Double(large) / Double(small) - 2) < 0.3, "\(small) → \(large)")
}

// MARK: - Highlighter (F5–F7)

@Test(.timeLimit(.minutes(2))) func issue692FlattenHighlighterCompositesTranslucently() throws {
    let line = AnnotationMark.stroke(.highlighter, points: [CGPoint(x: 50, y: 150), CGPoint(x: 350, y: 150)], style: unit)
    let p = try flat([line])
    // 0.35·(220,38,38) + 0.65·255 = (242.75, 179.05, 179.05).
    #expect(near(p[200, 150], [243, 179, 179], 3), "\(p[200, 150])")
    #expect(near(p[200, 155], [243, 179, 179], 3), "inside the 14 px band: \(p[200, 155])")
    #expect(near(p[200, 159], [255, 255, 255], 1), "outside it: \(p[200, 159])")
    // On black: 0.35·(220,38,38) = (77, 13.3, 13.3).
    let dark = try flat([line], on: black)
    #expect(near(dark[200, 150], [77, 13, 13], 3), "\(dark[200, 150])")
}

@Test(.timeLimit(.minutes(2))) func issue692FlattenHighlighterCrossingDoesNotDarken() throws {
    // Segments 1 and 3 cross at (200, 150).
    let cross = AnnotationMark.stroke(.highlighter, points: [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 200),
                                                             CGPoint(x: 300, y: 100), CGPoint(x: 100, y: 200)], style: unit)
    let p = try flat([cross])
    #expect(near(p[200, 150], [243, 179, 179], 3), "\(p[200, 150])")
    #expect(near(p[150, 125], [243, 179, 179], 3))
}

// MARK: - Pen (F8)

@Test(.timeLimit(.minutes(2))) func issue692FlattenPenIsOpaqueAndThin() throws {
    let pen = AnnotationMark.stroke(.pen, points: [CGPoint(x: 50, y: 150), CGPoint(x: 200, y: 150), CGPoint(x: 350, y: 150)],
                                    style: unit)
    let p = try flat([pen])
    #expect(near(p[120, 150], red, 4), "\(p[120, 150])")
    #expect(near(p[120, 153], [255, 255, 255], 2), "3.5 px off a 3 px pen")
    let dark = try flat([pen], on: black)
    #expect(near(dark[120, 150], red, 4), "opaque over black too")
}

// MARK: - Orientation (F9)

@Test(.timeLimit(.minutes(2))) func issue692FlattenArrowOnARotatedSource() throws {
    // Stored 300×400 with EXIF 6 (rotate 90° clockwise): the copy is upright 400×300 and marks are in upright pixels.
    let p = try flat([.arrow(tail: CGPoint(x: 50, y: 250), tip: CGPoint(x: 250, y: 50), style: unit)], on: black,
                     orientation: 6, width: 300, height: 400)
    #expect(p.width == 400 && p.height == 300)
    #expect(near(p[149, 150], red, 6))
    #expect(near(p[240, 53], [0, 0, 0], 2))
}

// MARK: - Every kind in one copy

@Test(.timeLimit(.minutes(2))) func issue692FlattenKeepsRectanglesAndDrawsInOrder() throws {
    // A pen drawn after a rectangle sits on top of it; the rectangle still strokes its box.
    let rect = AnnotationMark(rect: CGRect(x: 100, y: 100, width: 200, height: 100), style: unit)
    let pen = AnnotationMark.stroke(.highlighter, points: [CGPoint(x: 50, y: 100), CGPoint(x: 350, y: 100)], style: unit)
    let p = try flat([rect, pen])
    // Under the highlighter the rectangle's red stays red-ish (0.35 red over red is red).
    #expect(near(p[200, 100], red, 6), "\(p[200, 100])")
    #expect(near(p[100, 150], red, 6), "the left edge")
    #expect(near(p[200, 150], [255, 255, 255], 1), "inside the box")
}
