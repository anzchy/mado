import CoreGraphics
import Foundation
import MadoCore

/// Renders one redaction into the upright pixels of an image. CoreGraphics only; no file I/O.
///
/// Contract (#693a fix r2): for an RGB or grey image whose components are byte-aligned (8- or 16-bit integers or
/// 32-bit floats, any alpha placement, either byte order, with or without a decode array), the result keeps the
/// input's colour space, bitmap info, depth, bytes per row and decode array, and every pixel outside the rectangle
/// keeps its exact stored bytes. Any other layout (half-float, packed 5-5-5 or 10-10-10, colour models such as CMYK,
/// or a decode array in a space CoreGraphics cannot draw into) is first redrawn by #690's flattener rule: an RGB
/// source keeps its colour space and depth (8-bit, 16-bit, or 32-bit float), premultiplied RGBA; any other source
/// becomes sRGB 8-bit; outside pixels then change only by that conversion. The rectangle is widened to whole pixels
/// and clipped to the image; a rectangle that covers no pixel returns the input itself.
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

    /// The stored pixels of an RGB or grey image whose layout is read here directly: one or three colour components
    /// and an optional alpha or padding component, 8- or 16-bit integers or 32-bit floats, either byte order, with or
    /// without a decode array. Writing keeps that layout; bytes that are not written keep their exact value.
    struct Pixels {
        enum Alpha { case none, premultiplied, straight }

        let source: CGImage
        var width: Int, height: Int, bytesPerRow: Int
        var bytes: [UInt8]
        let componentBytes: Int, pixelBytes: Int
        let isFloat: Bool, littleEndian: Bool
        /// Byte offsets within a pixel of the colour components, then alpha or padding when stored.
        let offsets: [Int]
        let colours: Int
        let alpha: Alpha
        let maximum: Double
        /// The stored value of each component that shows as opaque black.
        private(set) var black: [Double]

        init?(_ image: CGImage) {
            let bits = image.bitsPerComponent, isFloat = image.bitmapInfo.contains(.floatComponents)
            guard let space = image.colorSpace, space.model == .rgb || space.model == .monochrome,
                  image.pixelFormatInfo == .packed, let (order, alpha) = Self.order(image.alphaInfo, colours: space.numberOfComponents),
                  image.bitsPerPixel == bits * order.count, isFloat ? bits == 32 : bits == 8 || bits == 16,
                  let (littleEndian, reversed) = Self.byteOrder(bits: bits, count: order.count, image.byteOrderInfo),
                  let data = image.dataProvider?.data as Data?,
                  data.count >= (image.height - 1) * image.bytesPerRow + image.width * image.bitsPerPixel / 8
            else { return nil }
            source = image; bytes = [UInt8](data)
            width = image.width; height = image.height; bytesPerRow = image.bytesPerRow
            componentBytes = bits / 8; pixelBytes = image.bitsPerPixel / 8
            self.isFloat = isFloat; self.littleEndian = littleEndian; self.alpha = alpha
            let colours = space.numberOfComponents, maximum = isFloat ? 1 : Double((1 << bits) - 1)
            self.colours = colours; self.maximum = maximum
            offsets = order.map { (reversed ? order.count - 1 - $0 : $0) * bits / 8 }
            black = order.indices.map { $0 < colours ? 0 : maximum }
            if image.decode != nil { guard let measured = measuredBlack() else { return nil }; black = measured }
        }

        /// Where the colour components and the extra component sit in memory order, before an 8-bit swap.
        private static func order(_ info: CGImageAlphaInfo, colours n: Int) -> ([Int], Alpha)? {
            let last = Array(0...n), first = Array(1...n) + [0]
            switch info {
            case .premultipliedLast: return (last, .premultiplied)
            case .last: return (last, .straight)
            case .noneSkipLast: return (last, .none)
            case .premultipliedFirst: return (first, .premultiplied)
            case .first: return (first, .straight)
            case .noneSkipFirst: return (first, .none)
            case .none: return (Array(0..<n), .none)
            default: return nil
            }
        }

        /// The default order is big-endian (measured: CoreGraphics reads 16-bit and float components that way).
        /// 8-bit pixels in 32-bit little order (four components) are stored reversed; a 16-bit order on two 8-bit
        /// components changes nothing (measured on grey with alpha).
        private static func byteOrder(bits: Int, count: Int, _ order: CGImageByteOrderInfo) -> (Bool, Bool)? {
            switch (bits, order) {
            case (8, .orderDefault), (8, .order32Big), (16, .orderDefault), (16, .order16Big), (32, .orderDefault),
                 (32, .order32Big): (false, false)
            case (8, .order16Little) where count == 2, (8, .order16Big) where count == 2: (false, false)
            case (8, .order32Little) where count == 4: (false, true)
            case (16, .order16Little), (32, .order32Little): (true, false)
            default: nil
            }
        }

        var image: CGImage {
            CGImage(width: width, height: height, bitsPerComponent: source.bitsPerComponent,
                    bitsPerPixel: source.bitsPerPixel, bytesPerRow: bytesPerRow, space: source.colorSpace!,
                    bitmapInfo: source.bitmapInfo, provider: CGDataProvider(data: Data(bytes) as CFData)!,
                    decode: source.decode, shouldInterpolate: source.shouldInterpolate, intent: source.renderingIntent)!
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

        /// With a decode array the stored value that shows as black is measured, not assumed. CoreGraphics applies
        /// the array as an affine map of each stored colour component, but forward for some depths and spaces and
        /// inverted (and clamped) for others, and it ignores the alpha pair (all measured, #693a fix r2). Probe
        /// pixels in this layout are decoded and each component solved for its target; nil when the probes cannot
        /// be decoded in the image's own space.
        private func measuredBlack() -> [Double]? {
            var target = black
            if alpha != .none {
                let opaque = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
                guard let decoded = decode(probes: [target.map { _ in 0 }, black], space: opaque, channels: 4) else { return nil }
                target[colours] = solve(decoded[0][3], decoded[1][3], for: 1)
            }
            let probes = [target] + (0..<colours).map { c in target.enumerated().map { $0.offset == c ? maximum : $0.element } }
            let info = colours == 1 ? CGImageAlphaInfo.none : .noneSkipLast
            guard let decoded = decode(probes: probes, space: source.colorSpace!, channels: colours == 1 ? 1 : 4, info: info)
            else { return nil }
            for c in 0..<colours { target[c] = solve(decoded[0][c], decoded[c + 1][c], for: 0) }
            return target
        }

        /// The stored value, within 0…maximum, that decodes nearest to `target`, given what 0 and maximum decode to.
        private func solve(_ low: Float, _ high: Float, for target: Double) -> Double {
            guard low != high else { return 0 }
            return min(max((target - Double(low)) / Double(high - low) * maximum, 0), maximum)
        }

        /// Draws one-row probe pixels in this layout into a float context of `space` and returns their components.
        private func decode(probes: [[Double]], space: CGColorSpace, channels: Int,
                            info: CGImageAlphaInfo = .premultipliedLast) -> [[Float]]? {
            var probe = self
            probe.width = probes.count; probe.height = 1; probe.bytesPerRow = probes.count * pixelBytes
            probe.bytes = [UInt8](repeating: 0, count: probe.bytesPerRow)
            for (x, values) in probes.enumerated() { for (c, value) in values.enumerated() { probe.set(x, 0, c, value) } }
            var floats = [Float](repeating: 0, count: probes.count * channels)
            let drawn = floats.withUnsafeMutableBytes { raw -> Bool in
                guard let context = CGContext(data: raw.baseAddress, width: probes.count, height: 1, bitsPerComponent: 32,
                                              bytesPerRow: probes.count * channels * 4, space: space,
                                              bitmapInfo: info.rawValue | CGBitmapInfo.floatComponents.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
                context.setBlendMode(.copy)
                context.draw(probe.image, in: CGRect(x: 0, y: 0, width: probes.count, height: 1))
                return true
            }
            return drawn ? stride(from: 0, to: floats.count, by: channels).map { Array(floats[$0..<$0 + channels]) } : nil
        }

        /// Every pixel in `area` shows opaque black; padding is written as full, like an opaque alpha.
        mutating func fill(_ area: PixelArea) {
            for y in area.minY..<area.maxY {
                for x in area.minX..<area.maxX {
                    for c in offsets.indices { set(x, y, c, black[c]) }
                }
            }
        }

        /// Square cells `cell` pixels wide start at the area's top-left corner; cells at the far edges are clipped
        /// to the area, and a cell wider than the area is the area (a huge strength must not overflow `left + cell`).
        /// Each cell takes the mean of its pixels in the source's own stored units, colour weighted by alpha (the
        /// premultiplied mean), rounded for integer components. A decode array is affine per component, so the
        /// decoded result is the decoded mean.
        mutating func pixelate(_ area: PixelArea, cell: Int) {
            let cell = min(cell, max(area.maxX - area.minX, area.maxY - area.minY))
            for top in stride(from: area.minY, to: area.maxY, by: cell) {
                for left in stride(from: area.minX, to: area.maxX, by: cell) {
                    let xs = left..<min(left + cell, area.maxX), ys = top..<min(top + cell, area.maxY)
                    let count = Double(xs.count * ys.count)
                    var sums = [Double](repeating: 0, count: offsets.count)
                    for y in ys {
                        for x in xs {
                            let weight = alpha == .straight ? component(x, y, colours) : 1
                            for c in offsets.indices { sums[c] += component(x, y, c) * (c < colours ? weight : 1) }
                        }
                    }
                    let colourWeight = alpha == .straight ? sums[colours] : count
                    let mean = sums.indices.map { c in
                        c < colours ? (colourWeight > 0 ? sums[c] / colourWeight : 0) : sums[c] / count
                    }
                    for y in ys { for x in xs { for c in offsets.indices { set(x, y, c, mean[c]) } } }
                }
            }
        }
    }
}
