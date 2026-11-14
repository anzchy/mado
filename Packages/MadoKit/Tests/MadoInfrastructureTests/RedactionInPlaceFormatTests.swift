import CoreGraphics
import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

/// #693a fix r2: grey layouts and RGB or grey layouts with a decode array are edited in place too, so every pixel
/// outside the rectangle keeps its stored bytes and the image keeps its format, decode array included.
struct RedactionInPlaceCase: CustomTestStringConvertible, Sendable {
    let format: RedactionFormat
    /// Inverts the first colour component; the rest identity. CoreGraphics drops an identity array (measured).
    let decoded: Bool
    /// The colour space's components are linear, so a mean of decoded values is the decoded mean.
    let linear: Bool

    var testDescription: String { format.name + (decoded ? " + decode" : "") }
    var colours: Int { format.channels.contains("k") ? 1 : 3 }
    var decode: [CGFloat]? {
        guard decoded else { return nil }
        let entries = colours + (format.channels.contains("a") ? 1 : 0)
        return [1, 0] + [CGFloat](repeating: 0, count: 2 * (entries - 1)).enumerated().map { $0.offset % 2 == 0 ? 0 : 1 }
    }
    /// Grey has no RGBA float context with alpha, so results are compared in extended linear sRGB.
    var oracleSpace: CGColorSpace {
        colours == 1 ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! : format.colorSpace
    }

    private static let linearGrey = CGColorSpace.linearGray as String
    private static func alpha(_ info: CGImageAlphaInfo) -> UInt32 { info.rawValue }
    private static let float = CGBitmapInfo.floatComponents.rawValue

    private static func grey(_ name: String, bits: Int = 8, _ channels: String, little: Bool = false,
                             premultiplied: Bool = false, _ info: UInt32, space: String = linearGrey) -> RedactionFormat {
        RedactionFormat(name: name, space: space, bits: bits, channels: channels, littleEndian: little,
                        premultiplied: premultiplied, info: info)
    }

    static let all: [RedactionInPlaceCase] = {
        let greys = [
            grey("linear grey 8-bit opaque", "k", alpha(.none)),
            grey("linear grey 8-bit premultiplied", "ka", premultiplied: true, alpha(.premultipliedLast)),
            grey("linear grey 8-bit straight alpha first", "ak", alpha(.first)),
            grey("linear grey 8-bit premultiplied 16-bit little", "ka", premultiplied: true,
                 alpha(.premultipliedLast) | CGBitmapInfo.byteOrder16Little.rawValue),
            grey("linear grey 16-bit opaque big-endian", bits: 16, "k", alpha(.none) | CGBitmapInfo.byteOrder16Big.rawValue),
            grey("linear grey 16-bit straight alpha little-endian", bits: 16, "ka", little: true,
                 alpha(.last) | CGBitmapInfo.byteOrder16Little.rawValue),
            grey("linear grey 8-bit padding", "kx", alpha(.noneSkipLast)),
            grey("linear grey float little-endian", bits: 32, "k", little: true,
                 alpha(.none) | float | CGBitmapInfo.byteOrder32Little.rawValue),
        ]
        let gamma = grey("grey gamma 2.2 8-bit opaque", "k", alpha(.none), space: CGColorSpace.genericGrayGamma2_2 as String)
        let p3 = CGColorSpace.displayP3 as String
        let decodedRGB = [
            RedactionFormat(name: "Display P3 8-bit RGBX", space: p3, bits: 8, channels: "rgbx", littleEndian: false,
                            premultiplied: false, info: alpha(.noneSkipLast)),
            RedactionFormat(name: "Display P3 16-bit RGB big-endian", space: p3, bits: 16, channels: "rgb",
                            littleEndian: false, premultiplied: false,
                            info: alpha(.none) | CGBitmapInfo.byteOrder16Big.rawValue),
            RedactionFormat(name: "extended linear sRGB float RGBX little-endian",
                            space: CGColorSpace.extendedLinearSRGB as String, bits: 32, channels: "rgbx",
                            littleEndian: true, premultiplied: false,
                            info: alpha(.noneSkipLast) | float | CGBitmapInfo.byteOrder32Little.rawValue),
            RedactionFormat(name: "sRGB 8-bit straight-alpha RGBA", space: CGColorSpace.sRGB as String, bits: 8,
                            channels: "rgba", littleEndian: false, premultiplied: false, info: alpha(.last)),
        ]
        return greys.map { .init(format: $0, decoded: false, linear: true) }
            + [.init(format: gamma, decoded: false, linear: false)]
            + decodedRGB.map { .init(format: $0, decoded: true, linear: true) }
            + [.init(format: greys[0], decoded: true, linear: true), .init(format: greys[5], decoded: true, linear: true)]
    }()
}

private let rect = CGRect(x: 3, y: 2, width: 8, height: 4)
private let xs = 3..<11, ys = 2..<6, cell = 4

private func redactions(_ image: CGImage) throws -> [(String, CGImage)] {
    [("solid", try RedactionRenderer.render(image, rect: rect, style: .solid)),
     ("mosaic", try RedactionRenderer.pixelate(image, rect: rect, cell: cell))]
}

/// The colour pairs of an image's decode array (CoreGraphics ignores the alpha pair, measured).
private func decodeArray(_ image: CGImage) -> [CGFloat]? {
    guard let decode = image.decode else { return nil }
    return Array(UnsafeBufferPointer(start: decode, count: 2 * (image.colorSpace?.numberOfComponents ?? 0)))
}

@Test(arguments: RedactionInPlaceCase.all)
func issue693InPlaceLayoutKeepsItsFormatAndEveryOutsideStoredByte(layout: RedactionInPlaceCase) throws {
    let source = RedactionSource(layout.format, decode: layout.decode)
    let expectedDecode = layout.decode.map { Array($0.prefix(2 * layout.colours)) }
    #expect(decodeArray(source.image) == expectedDecode, "the source must keep its decode array")
    for (style, result) in try redactions(source.image) {
        #expect(result.colorSpace?.name == source.image.colorSpace?.name, "\(style)")
        #expect(result.bitsPerComponent == source.image.bitsPerComponent, "\(style)")
        #expect(result.bitsPerPixel == source.image.bitsPerPixel, "\(style)")
        #expect(result.bytesPerRow == source.image.bytesPerRow, "\(style)")
        #expect(result.bitmapInfo == source.image.bitmapInfo, "\(style)")
        #expect(decodeArray(result) == expectedDecode, "\(style)")
        for y in 0..<RedactionSource.height {
            for x in 0..<RedactionSource.width where !(xs.contains(x) && ys.contains(y)) {
                #expect(RedactionSource.stored(result, x, y) == RedactionSource.stored(source.image, x, y),
                        "\(style) outside (\(x), \(y))")
            }
        }
    }
}

@Test(arguments: RedactionInPlaceCase.all)
func issue693InPlaceLayoutLeavesNoOriginalPixelInsideAndSolidShowsBlack(layout: RedactionInPlaceCase) throws {
    let source = RedactionSource(layout.format, decode: layout.decode)
    for (style, result) in try redactions(source.image) {
        for y in ys {
            for x in xs {
                #expect(RedactionSource.stored(result, x, y) != RedactionSource.stored(source.image, x, y),
                        "\(style) inside (\(x), \(y))")
            }
        }
    }
    let solid = RedactionSource.decoded(try RedactionRenderer.render(source.image, rect: rect, style: .solid),
                                        in: layout.oracleSpace)
    let tolerance: Float = layout.format.bits == 32 ? 1e-6 : Float(1.5 / layout.format.maximum)
    for y in ys {
        for x in xs {
            let pixel = solid[y * RedactionSource.width + x]
            #expect(zip(pixel, [0, 0, 0, 1] as [Float]).allSatisfy { abs($0 - $1) <= tolerance }, "solid (\(x), \(y)): \(pixel)")
        }
    }
}

/// Means are taken in stored units; a decode array is an affine map of each stored component, so the decoded
/// result is the premultiplied mean of the decoded source cell.
@Test(arguments: RedactionInPlaceCase.all.filter(\.linear))
func issue693InPlaceLayoutMosaicShowsTheDecodedMean(layout: RedactionInPlaceCase) throws {
    let source = RedactionSource(layout.format, decode: layout.decode)
    let before = RedactionSource.decoded(source.image, in: layout.oracleSpace)
    let after = RedactionSource.decoded(try RedactionRenderer.pixelate(source.image, rect: rect, cell: cell),
                                        in: layout.oracleSpace)
    let tolerance: Float = layout.format.bits == 32 ? 1e-5 : Float(1.5 / layout.format.maximum)
    for y in ys {
        for x in xs {
            let cx = xs.lowerBound + (x - xs.lowerBound) / cell * cell, cy = ys.lowerBound + (y - ys.lowerBound) / cell * cell
            var mean: [Float] = [0, 0, 0, 0]
            for sy in cy..<cy + cell { for sx in cx..<cx + cell { for c in 0..<4 { mean[c] += before[sy * RedactionSource.width + sx][c] } } }
            mean = mean.map { $0 / Float(cell * cell) }
            let got = after[y * RedactionSource.width + x]
            #expect(zip(got, mean).allSatisfy { abs($0 - $1) <= tolerance }, "(\(x), \(y)): \(got) vs \(mean)")
        }
    }
}

/// The layouts that are still redrawn, by #690's flattener rule, because they have no byte-aligned component per
/// channel to edit: half-float, packed 5-5-5 and 10-10-10 RGB, and colour models other than RGB and grey (CMYK here).
struct RedactionRedrawnCase: CustomTestStringConvertible, Sendable {
    let name: String
    let space: String
    let bits: Int, bitsPerPixel: Int
    let info: UInt32
    let resultSpace: String, resultBits: Int

    var testDescription: String { name }

    var image: CGImage {
        let bytesPerRow = RedactionSource.width * bitsPerPixel / 8
        var bytes = (0..<bytesPerRow * RedactionSource.height).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) }
        if bits == 16 {  // half floats in 0…1, so the pattern decodes to finite colours
            for i in stride(from: 0, to: bytes.count, by: 2) {
                let half = Float16(Float(i % 97) / 97).bitPattern
                bytes[i] = UInt8(truncatingIfNeeded: half); bytes[i + 1] = UInt8(truncatingIfNeeded: half >> 8)
            }
        }
        return CGImage(width: RedactionSource.width, height: RedactionSource.height, bitsPerComponent: bits,
                       bitsPerPixel: bitsPerPixel, bytesPerRow: bytesPerRow, space: CGColorSpace(name: space as CFString)!,
                       bitmapInfo: CGBitmapInfo(rawValue: info), provider: CGDataProvider(data: Data(bytes) as CFData)!,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static let all: [RedactionRedrawnCase] = [
        .init(name: "Display P3 half-float RGBA", space: CGColorSpace.displayP3 as String, bits: 16, bitsPerPixel: 64,
              info: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue,
              resultSpace: CGColorSpace.displayP3 as String, resultBits: 32),
        .init(name: "Display P3 packed 10-10-10", space: CGColorSpace.displayP3 as String, bits: 10, bitsPerPixel: 32,
              info: CGImageAlphaInfo.noneSkipLast.rawValue | CGImagePixelFormatInfo.RGB101010.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue,
              resultSpace: CGColorSpace.displayP3 as String, resultBits: 16),
        .init(name: "sRGB packed 5-5-5", space: CGColorSpace.sRGB as String, bits: 5, bitsPerPixel: 16,
              info: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder16Little.rawValue,
              resultSpace: CGColorSpace.sRGB as String, resultBits: 8),
        .init(name: "generic CMYK 8-bit", space: CGColorSpace.genericCMYK as String, bits: 8, bitsPerPixel: 32,
              info: CGImageAlphaInfo.none.rawValue, resultSpace: CGColorSpace.sRGB as String, resultBits: 8),
    ]
}

@Test(arguments: RedactionRedrawnCase.all)
func issue693NamedLayoutsAreRedrawnByTheFlattenerRule(layout: RedactionRedrawnCase) throws {
    let image = layout.image
    // Compared in the result's space; an integer result cannot hold out-of-range values (CMYK decodes slightly
    // below 0 in sRGB), so the source is clamped to 0…1 there.
    let space = CGColorSpace(name: layout.resultSpace as CFString)!
    let before = RedactionSource.decoded(image, in: space).map { $0.map { layout.resultBits == 32 ? $0 : min(max($0, 0), 1) } }
    for (style, result) in try redactions(image) {
        #expect(result.colorSpace?.name == layout.resultSpace as CFString, "\(style)")
        #expect(result.bitsPerComponent == layout.resultBits && result.alphaInfo == .premultipliedLast, "\(style)")
        let after = RedactionSource.decoded(result, in: space)
        for y in 0..<RedactionSource.height {
            for x in 0..<RedactionSource.width where !(xs.contains(x) && ys.contains(y)) {
                let (a, b) = (after[y * RedactionSource.width + x], before[y * RedactionSource.width + x])
                #expect(zip(a, b).allSatisfy { abs($0 - $1) <= 0.01 }, "\(style) (\(x), \(y)): \(a) vs \(b)")
            }
        }
        if style == "solid" {
            for y in ys { for x in xs { #expect(after[y * RedactionSource.width + x] == [0, 0, 0, 1], "(\(x), \(y))") } }
        }
    }
}
