import CoreGraphics
import Foundation
import MadoCore

/// Renders one redaction into the upright pixels of an image. CoreGraphics only; no file I/O.
///
/// The result has the size, colour space and stored layout of the input, and every pixel outside the rectangle keeps
/// its exact bits (#693 fix r1). A layout not read here directly is first redrawn by #690's flattener rule: an RGB
/// source keeps its colour space and depth (8-bit, 16-bit, or 32-bit float), premultiplied RGBA; any other source
/// becomes sRGB 8-bit. The rectangle is widened to whole pixels and clipped to the image; a rectangle that covers no
/// pixel returns the input itself.
public enum RedactionRenderer {
    public enum Failure: Error, Equatable { case contextUnavailable }

    /// `rect` is in image pixels with the origin at the top left, like an annotation mark. A mosaic weaker than
    /// `RedactionStyle.minimumMosaicStrength` is drawn at the minimum.
    public static func render(_ image: CGImage, rect: CGRect, style: RedactionStyle) throws -> CGImage {
        switch style.enforced {
        case .solid: try redact(image, rect: rect) { pixels, area in pixels.fill(area) }
        case .mosaic(let strength): try pixelate(image, rect: rect, cell: strength)
        }
    }

    /// Mosaic with square cells exactly `cell` pixels wide, before the minimum strength is applied.
    static func pixelate(_ image: CGImage, rect: CGRect, cell: Int) throws -> CGImage {
        try redact(image, rect: rect) { pixels, area in pixels.pixelate(area, cell: cell) }
    }

    /// Applies `change` to the covered pixels of `image`, in its own layout when it can be read directly.
    private static func redact(_ image: CGImage, rect: CGRect,
                               change: (inout Pixels, PixelArea) -> Void) throws -> CGImage {
        guard let area = PixelArea(rect, width: image.width, height: image.height) else { return image }
        guard var pixels = try Pixels(image) ?? Pixels(redrawn(image)) else { throw Failure.contextUnavailable }
        change(&pixels, area)
        return pixels.image
    }

    /// #690's `AnnotationFlattener.BitmapFormat` rule, kept local until the full #693 merges the two.
    static func redrawn(_ image: CGImage) throws -> CGImage {
        var space = CGColorSpace(name: CGColorSpace.sRGB)!, bits = 8
        var info = CGImageAlphaInfo.premultipliedLast.rawValue
        if let source = image.colorSpace, source.model == .rgb, source.supportsOutput {
            space = source
            if image.bitmapInfo.contains(.floatComponents) {
                // Host (little-endian) order: drawing a little-endian float source into a big-endian float
                // context was measured to lose its last pixel.
                bits = 32; info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            } else if image.bitsPerComponent > 8 {
                bits = 16
            }
        }
        // A very large image can exceed what CoreGraphics allocates; that is reported, not trapped.
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: bits,
                                      bytesPerRow: 0, space: space, bitmapInfo: info) else { throw Failure.contextUnavailable }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = context.makeImage() else { throw Failure.contextUnavailable }
        return result
    }

    /// The whole pixels a rectangle touches, clipped to the image; nil when it touches none.
    struct PixelArea: Equatable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int

        init?(_ rect: CGRect, width: Int, height: Int) {
            let clipped = rect.standardized.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            minX = Int(clipped.minX.rounded(.down)); minY = Int(clipped.minY.rounded(.down))
            maxX = Int(clipped.maxX.rounded(.up)); maxY = Int(clipped.maxY.rounded(.up))
        }
    }

    /// The stored pixels of an RGB image whose layout is read here directly: three colour components and an optional
    /// alpha or padding component, 8- or 16-bit integers or 32-bit floats, either byte order, no decode array.
    /// Writing keeps that layout; bytes that are not written keep their exact value.
    struct Pixels {
        enum Alpha { case none, premultiplied, straight }

        let source: CGImage
        var bytes: [UInt8]
        let componentBytes: Int, pixelBytes: Int, bytesPerRow: Int
        let isFloat: Bool, littleEndian: Bool
        /// Byte offsets within a pixel of red, green, blue and, when stored, alpha or padding.
        let offsets: [Int]
        let alpha: Alpha
        let maximum: Double

        init?(_ image: CGImage) {
            let bits = image.bitsPerComponent, isFloat = image.bitmapInfo.contains(.floatComponents)
            guard image.colorSpace?.model == .rgb, image.decode == nil,
                  let (order, alpha) = Self.order(image.alphaInfo), image.bitsPerPixel == bits * order.count,
                  isFloat ? bits == 32 : bits == 8 || bits == 16,
                  let (littleEndian, reversed) = Self.byteOrder(bits: bits, count: order.count, image.byteOrderInfo),
                  let data = image.dataProvider?.data as Data?,
                  data.count >= (image.height - 1) * image.bytesPerRow + image.width * image.bitsPerPixel / 8
            else { return nil }
            source = image; bytes = [UInt8](data)
            componentBytes = bits / 8; pixelBytes = image.bitsPerPixel / 8; bytesPerRow = image.bytesPerRow
            self.isFloat = isFloat; self.littleEndian = littleEndian; self.alpha = alpha
            offsets = order.map { (reversed ? order.count - 1 - $0 : $0) * bits / 8 }
            maximum = isFloat ? 1 : Double((1 << bits) - 1)
        }

        /// Where red, green, blue and the fourth component sit in memory order, before an 8-bit 32-bit-little swap.
        private static func order(_ info: CGImageAlphaInfo) -> ([Int], Alpha)? {
            switch info {
            case .premultipliedLast: ([0, 1, 2, 3], .premultiplied)
            case .last: ([0, 1, 2, 3], .straight)
            case .noneSkipLast: ([0, 1, 2, 3], .none)
            case .premultipliedFirst: ([1, 2, 3, 0], .premultiplied)
            case .first: ([1, 2, 3, 0], .straight)
            case .noneSkipFirst: ([1, 2, 3, 0], .none)
            case .none: ([0, 1, 2], .none)
            default: nil
            }
        }

        /// The default order is big-endian (measured: CoreGraphics reads 16-bit and float components that way).
        /// 8-bit pixels in 32-bit little order are stored with their four components reversed.
        private static func byteOrder(bits: Int, count: Int, _ order: CGImageByteOrderInfo) -> (Bool, Bool)? {
            switch (bits, order) {
            case (8, .orderDefault), (8, .order32Big), (16, .orderDefault), (16, .order16Big), (32, .orderDefault),
                 (32, .order32Big): (false, false)
            case (8, .order32Little) where count == 4: (false, true)
            case (16, .order16Little), (32, .order32Little): (true, false)
            default: nil
            }
        }

        var image: CGImage {
            CGImage(width: source.width, height: source.height, bitsPerComponent: source.bitsPerComponent,
                    bitsPerPixel: source.bitsPerPixel, bytesPerRow: bytesPerRow, space: source.colorSpace!,
                    bitmapInfo: source.bitmapInfo, provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
                    shouldInterpolate: source.shouldInterpolate, intent: source.renderingIntent)!
        }

        func component(_ x: Int, _ y: Int, _ c: Int) -> Double {
            let at = y * bytesPerRow + x * pixelBytes + offsets[c]
            var raw: UInt32 = 0
            for i in 0..<componentBytes { raw = raw << 8 | UInt32(bytes[at + i]) }
            if littleEndian { raw = raw.byteSwapped >> (32 - 8 * componentBytes) }
            return isFloat ? Double(Float(bitPattern: raw)) : Double(raw)
        }

        mutating func set(_ x: Int, _ y: Int, _ c: Int, _ value: Double) {
            let at = y * bytesPerRow + x * pixelBytes + offsets[c]
            var raw = isFloat ? Float(value).bitPattern : UInt32(value.rounded())
            if littleEndian { raw = raw.byteSwapped >> (32 - 8 * componentBytes) }
            for i in 0..<componentBytes { bytes[at + i] = UInt8(truncatingIfNeeded: raw >> (8 * (componentBytes - 1 - i))) }
        }

        /// Every pixel in `area` becomes opaque black; padding is written as full, like an opaque alpha.
        mutating func fill(_ area: PixelArea) {
            for y in area.minY..<area.maxY {
                for x in area.minX..<area.maxX {
                    for c in offsets.indices { set(x, y, c, c < 3 ? 0 : maximum) }
                }
            }
        }

        /// Square cells `cell` pixels wide start at the area's top-left corner; cells at the far edges are clipped
        /// to the area, and a cell wider than the area is the area (a huge strength must not overflow `left + cell`).
        /// Each cell takes the mean of its pixels in the source's
        /// own space and depth, colour weighted by alpha (the premultiplied mean), rounded for integer components.
        mutating func pixelate(_ area: PixelArea, cell: Int) {
            let cell = min(cell, max(area.maxX - area.minX, area.maxY - area.minY))
            for top in stride(from: area.minY, to: area.maxY, by: cell) {
                for left in stride(from: area.minX, to: area.maxX, by: cell) {
                    let xs = left..<min(left + cell, area.maxX), ys = top..<min(top + cell, area.maxY)
                    let count = Double(xs.count * ys.count)
                    var sums = [Double](repeating: 0, count: offsets.count)
                    for y in ys {
                        for x in xs {
                            let weight = alpha == .straight ? component(x, y, 3) : 1
                            for c in offsets.indices { sums[c] += component(x, y, c) * (c < 3 ? weight : 1) }
                        }
                    }
                    let colourWeight = alpha == .straight ? sums[3] : count
                    let mean = sums.indices.map { c in
                        c < 3 ? (colourWeight > 0 ? sums[c] / colourWeight : 0) : sums[c] / count
                    }
                    for y in ys { for x in xs { for c in offsets.indices { set(x, y, c, mean[c]) } } }
                }
            }
        }
    }
}
