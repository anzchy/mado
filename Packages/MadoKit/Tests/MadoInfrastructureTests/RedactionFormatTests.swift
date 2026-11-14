import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

/// A stored pixel layout, spelled out here independently of the renderer. `channels` names the stored components in
/// memory order: r, g, b, a (alpha) or x (padding). Integer components are 8 or 16 bits; 32 bits means float.
/// Grey layouts use k for the grey component.
struct RedactionFormat: CustomTestStringConvertible, Sendable {
    let name: String
    let space: String
    let bits: Int
    let channels: String
    let littleEndian: Bool
    let premultiplied: Bool
    let info: UInt32

    var testDescription: String { name }
    var colorSpace: CGColorSpace { CGColorSpace(name: space as CFString)! }
    var componentBytes: Int { bits / 8 }
    var pixelBytes: Int { channels.count * componentBytes }
    var maximum: Double { bits == 32 ? 1 : Double((1 << bits) - 1) }

    private static let float = CGBitmapInfo.floatComponents.rawValue
    private static func alpha(_ info: CGImageAlphaInfo) -> UInt32 { info.rawValue }

    static let preserved: [RedactionFormat] = [
        .init(name: "Display P3 8-bit premultiplied RGBA", space: CGColorSpace.displayP3 as String, bits: 8,
              channels: "rgba", littleEndian: false, premultiplied: true, info: alpha(.premultipliedLast)),
        .init(name: "sRGB 8-bit premultiplied BGRA", space: CGColorSpace.sRGB as String, bits: 8, channels: "bgra",
              littleEndian: false, premultiplied: true,
              info: alpha(.premultipliedFirst) | CGBitmapInfo.byteOrder32Little.rawValue),
        .init(name: "Display P3 16-bit premultiplied big-endian", space: CGColorSpace.displayP3 as String, bits: 16,
              channels: "rgba", littleEndian: false, premultiplied: true,
              info: alpha(.premultipliedLast) | CGBitmapInfo.byteOrder16Big.rawValue),
        .init(name: "Display P3 16-bit premultiplied little-endian", space: CGColorSpace.displayP3 as String, bits: 16,
              channels: "rgba", littleEndian: true, premultiplied: true,
              info: alpha(.premultipliedLast) | CGBitmapInfo.byteOrder16Little.rawValue),
        .init(name: "extended linear sRGB float little-endian", space: CGColorSpace.extendedLinearSRGB as String,
              bits: 32, channels: "rgba", littleEndian: true, premultiplied: true,
              info: alpha(.premultipliedLast) | float | CGBitmapInfo.byteOrder32Little.rawValue),
        .init(name: "extended linear Display P3 float default order", space: CGColorSpace.extendedLinearDisplayP3 as String,
              bits: 32, channels: "rgba", littleEndian: false, premultiplied: true, info: alpha(.premultipliedLast) | float),
        .init(name: "sRGB 8-bit straight-alpha translucent RGBA", space: CGColorSpace.sRGB as String, bits: 8,
              channels: "rgba", littleEndian: false, premultiplied: false, info: alpha(.last)),
        .init(name: "Display P3 16-bit straight-alpha ARGB little-endian", space: CGColorSpace.displayP3 as String,
              bits: 16, channels: "argb", littleEndian: true, premultiplied: false,
              info: alpha(.first) | CGBitmapInfo.byteOrder16Little.rawValue),
        .init(name: "sRGB 8-bit opaque BGRX", space: CGColorSpace.sRGB as String, bits: 8, channels: "bgrx",
              littleEndian: false, premultiplied: false,
              info: alpha(.noneSkipFirst) | CGBitmapInfo.byteOrder32Little.rawValue),
        .init(name: "sRGB 8-bit opaque RGB", space: CGColorSpace.sRGB as String, bits: 8, channels: "rgb",
              littleEndian: false, premultiplied: false, info: alpha(.none)),
    ]
}

/// Source pixels in one of the formats above: a checkerboard of two far-apart colours (and, with alpha, two
/// opacities) with a small gradient, so no cell mean equals any of its pixels.
struct RedactionSource {
    static let width = 12, height = 10, rowPadding = 16
    let format: RedactionFormat
    let bytes: [UInt8]
    let image: CGImage

    init(_ format: RedactionFormat, decode: [CGFloat]? = nil) {
        self.format = format
        let bytesPerRow = Self.width * format.pixelBytes + Self.rowPadding
        var bytes = [UInt8](repeating: 0xA5, count: bytesPerRow * Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let (colour, alpha) = Self.logical(x, y, hasAlpha: format.channels.contains("a"))
                for (i, channel) in format.channels.enumerated() {
                    let value: Double = switch channel {
                    case "r": colour[0] * (format.premultiplied ? alpha : 1)
                    case "k": colour[0] * (format.premultiplied ? alpha : 1)
                    case "g": colour[1] * (format.premultiplied ? alpha : 1)
                    case "b": colour[2] * (format.premultiplied ? alpha : 1)
                    case "a": alpha
                    default: 1
                    }
                    let raw: UInt32 = format.bits == 32 ? Float(value).bitPattern : UInt32((value * format.maximum).rounded())
                    let at = y * bytesPerRow + x * format.pixelBytes + i * format.componentBytes
                    for b in 0..<format.componentBytes {
                        let shift = format.littleEndian ? 8 * b : 8 * (format.componentBytes - 1 - b)
                        bytes[at + b] = UInt8(truncatingIfNeeded: raw >> shift)
                    }
                }
            }
        }
        self.bytes = bytes
        image = CGImage(width: Self.width, height: Self.height, bitsPerComponent: format.bits,
                        bitsPerPixel: format.pixelBytes * 8, bytesPerRow: bytesPerRow, space: format.colorSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: format.info),
                        provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: decode,
                        shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func logical(_ x: Int, _ y: Int, hasAlpha: Bool) -> (colour: [Double], alpha: Double) {
        let even = (x + y) % 2 == 0
        let base = even ? [0.85, 0.2, 0.7] : [0.15, 0.75, 0.3]
        return ([base[0] + 0.004 * Double(x), base[1] + 0.003 * Double(y), base[2]], hasAlpha && !even ? 0.55 : 1)
    }

    /// The stored bytes of pixel (x, y) of an image, row 0 at the top.
    static func stored(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let size = image.bitsPerPixel / 8
        let at = y * image.bytesPerRow + x * size
        return Array(data[at..<at + size])
    }

    /// Premultiplied RGBA of every pixel, decoded by CoreGraphics into a float buffer of `space`; row 0 at the top.
    static func decoded(_ image: CGImage, in space: CGColorSpace) -> [[Float]] {
        var floats = [Float](repeating: -1, count: image.width * image.height * 4)
        floats.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 32,
                                    bytesPerRow: image.width * 16, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                        | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 0, to: floats.count, by: 4).map { Array(floats[$0..<$0 + 4]) }
    }
}

private let rect = CGRect(x: 3, y: 2, width: 8, height: 4)
private let xs = 3..<11, ys = 2..<6, cell = 4

private func redactions(_ image: CGImage) throws -> [(String, CGImage)] {
    [("solid", try RedactionRenderer.render(image, rect: rect, style: .solid)),
     ("mosaic", try RedactionRenderer.pixelate(image, rect: rect, cell: cell))]
}

@Test(arguments: RedactionFormat.preserved)
func issue693RedactionKeepsTheSourceFormatAndEveryOutsidePixelBitIdentical(format: RedactionFormat) throws {
    let source = RedactionSource(format)
    for (style, result) in try redactions(source.image) {
        #expect(result.colorSpace?.name == source.image.colorSpace?.name, "\(style)")
        #expect(result.bitsPerComponent == format.bits && result.bitsPerPixel == format.pixelBytes * 8, "\(style)")
        #expect(result.bitmapInfo == source.image.bitmapInfo, "\(style)")
        for y in 0..<RedactionSource.height {
            for x in 0..<RedactionSource.width where !(xs.contains(x) && ys.contains(y)) {
                #expect(RedactionSource.stored(result, x, y) == RedactionSource.stored(source.image, x, y),
                        "\(style) outside (\(x), \(y))")
            }
        }
    }
}

@Test(arguments: RedactionFormat.preserved)
func issue693RedactionLeavesNoOriginalPixelInsideTheRect(format: RedactionFormat) throws {
    let source = RedactionSource(format)
    for (style, result) in try redactions(source.image) {
        for y in ys {
            for x in xs {
                #expect(RedactionSource.stored(result, x, y) != RedactionSource.stored(source.image, x, y),
                        "\(style) inside (\(x), \(y))")
            }
        }
    }
    let solid = RedactionSource.decoded(try RedactionRenderer.render(source.image, rect: rect, style: .solid),
                                        in: format.colorSpace)
    for y in ys { for x in xs { #expect(solid[y * RedactionSource.width + x] == [0, 0, 0, 1], "solid (\(x), \(y))") } }
}

/// The mean is taken in the source's own colour space and depth: CoreGraphics decodes source and result into a
/// float buffer of that space, and each result pixel is the premultiplied mean of its cell's source pixels.
@Test(arguments: RedactionFormat.preserved)
func issue693MosaicMeansAreComputedInTheSourceSpace(format: RedactionFormat) throws {
    let source = RedactionSource(format)
    let before = RedactionSource.decoded(source.image, in: format.colorSpace)
    let after = RedactionSource.decoded(try RedactionRenderer.pixelate(source.image, rect: rect, cell: cell),
                                        in: format.colorSpace)
    let tolerance: Float = format.bits == 32 ? 1e-5 : Float(1.5 / format.maximum)
    for y in ys {
        for x in xs {
            let cx = xs.lowerBound + (x - xs.lowerBound) / cell * cell, cy = ys.lowerBound + (y - ys.lowerBound) / cell * cell
            var mean: [Float] = [0, 0, 0, 0]
            for sy in cy..<cy + cell { for sx in cx..<cx + cell { for c in 0..<4 { mean[c] += before[sy * RedactionSource.width + sx][c] } } }
            mean = mean.map { $0 / Float(cell * cell) }
            let got = after[y * RedactionSource.width + x]
            for c in 0..<4 { #expect(abs(got[c] - mean[c]) <= tolerance, "(\(x), \(y)) channel \(c): \(got) vs \(mean)") }
        }
    }
}
