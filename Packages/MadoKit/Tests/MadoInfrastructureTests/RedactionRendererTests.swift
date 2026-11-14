import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

/// RGBA8 premultiplied-last pixels, row 0 at the top. Shared by the #693 redaction tests.
struct RedactionPixels: Equatable {
    var width: Int
    var height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width; self.height = height; self.bytes = bytes
    }

    /// Every pixel gets a distinct opaque colour derived from its position.
    static func distinct(width: Int, height: Int) -> RedactionPixels {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                bytes += [UInt8((x * 37 + y * 11) % 251), UInt8((x * 13 + y * 29 + 7) % 241), UInt8((x * y + 3) % 239), 255]
            }
        }
        return RedactionPixels(width: width, height: height, bytes: bytes)
    }

    init(_ image: CGImage) {
        width = image.width; height = image.height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    var image: CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    func pixel(_ x: Int, _ y: Int) -> [UInt8] {
        let start = (y * width + x) * 4
        return Array(bytes[start..<start + 4])
    }

    mutating func set(_ x: Int, _ y: Int, _ value: [UInt8]) {
        let start = (y * width + x) * 4
        bytes.replaceSubrange(start..<start + 4, with: value)
    }
}

/// The pixel rows/columns a rect touches, top-left origin, for checking "inside" against "outside".
private func inside(_ x: Int, _ y: Int, _ rect: (x: Range<Int>, y: Range<Int>)) -> Bool {
    rect.x.contains(x) && rect.y.contains(y)
}

private func expectSolid(_ result: RedactionPixels, source: RedactionPixels, covering rect: (x: Range<Int>, y: Range<Int>)) {
    #expect(result.width == source.width && result.height == source.height)
    for y in 0..<source.height {
        for x in 0..<source.width {
            let expected = inside(x, y, rect) ? [0, 0, 0, 255] : source.pixel(x, y)
            #expect(result.pixel(x, y) == expected, "pixel (\(x), \(y))")
        }
    }
}

@Test func issue693SolidBlackensEveryPixelInRectAndKeepsTheRest() throws {
    let source = RedactionPixels.distinct(width: 8, height: 6)
    let result = RedactionPixels(try RedactionRenderer.render(source.image, rect: CGRect(x: 2, y: 1, width: 3, height: 4),
                                                              style: .solid))
    expectSolid(result, source: source, covering: (2..<5, 1..<5))
}

@Test func issue693SolidMakesTransparentSourcePixelsOpaqueBlack() throws {
    var source = RedactionPixels.distinct(width: 4, height: 4)
    source.set(1, 1, [0, 0, 0, 0])
    source.set(2, 2, [40, 20, 10, 128])
    source.set(3, 3, [0, 0, 0, 0])
    let result = RedactionPixels(try RedactionRenderer.render(source.image, rect: CGRect(x: 1, y: 1, width: 2, height: 2),
                                                              style: .solid))
    expectSolid(result, source: source, covering: (1..<3, 1..<3))
    #expect(result.pixel(3, 3) == [0, 0, 0, 0])
}

@Test func issue693FractionalRectExpandsOutwardToWholePixels() throws {
    let source = RedactionPixels.distinct(width: 8, height: 6)
    let result = RedactionPixels(try RedactionRenderer.render(source.image,
                                                              rect: CGRect(x: 1.5, y: 0.25, width: 2.2, height: 1.5),
                                                              style: .solid))
    expectSolid(result, source: source, covering: (1..<4, 0..<2))
}

@Test func issue693RectIsClippedToTheImage() throws {
    let source = RedactionPixels.distinct(width: 6, height: 5)
    let result = RedactionPixels(try RedactionRenderer.render(source.image, rect: CGRect(x: -3, y: 3, width: 5, height: 9),
                                                              style: .solid))
    expectSolid(result, source: source, covering: (0..<2, 3..<5))
}

@Test(arguments: [CGRect(x: 10, y: 0, width: 4, height: 4), CGRect(x: 1, y: 1, width: 0, height: 3),
                  CGRect(x: 0, y: -8, width: 6, height: 8), CGRect.null])
func issue693RectOutsideTheImageLeavesItUnchanged(rect: CGRect) throws {
    let source = RedactionPixels.distinct(width: 6, height: 5)
    for style in [RedactionStyle.solid, .mosaic(strength: 1)] {
        #expect(RedactionPixels(try RedactionRenderer.render(source.image, rect: rect, style: style)) == source)
    }
}
