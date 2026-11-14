import CoreGraphics
import Foundation
import MadoCore

/// Renders one redaction into the upright pixels of an image. CoreGraphics only; no file I/O.
///
/// The result is sRGB RGBA8 with premultiplied alpha and the size of the input. The rectangle is widened to whole
/// pixels and clipped to the image; a rectangle that covers no pixel leaves every pixel as it was.
public enum RedactionRenderer {
    public enum Failure: Error, Equatable { case contextUnavailable }

    /// `rect` is in image pixels with the origin at the top left, like an annotation mark.
    public static func render(_ image: CGImage, rect: CGRect, style: RedactionStyle) throws -> CGImage {
        switch style {
        case .solid: try redact(image, rect: rect) { pixels, area in pixels.fill(area) }
        case .mosaic(let strength): try redact(image, rect: rect) { pixels, area in pixels.pixelate(area, cell: strength) }
        }
    }

    /// Draws `image` into a top-left pixel buffer, applies `change` to the covered pixels and returns the result.
    private static func redact(_ image: CGImage, rect: CGRect,
                               change: (inout Buffer, PixelArea) -> Void) throws -> CGImage {
        var buffer = try Buffer(image)
        if let area = PixelArea(rect, width: image.width, height: image.height) { change(&buffer, area) }
        return buffer.image
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

    /// RGBA8 premultiplied-last pixels; row 0 is the top of the image.
    struct Buffer {
        let width: Int, height: Int
        var bytes: [UInt8]

        /// The upright pixels of `image`; a context's memory starts at its top row.
        init(_ image: CGImage) throws {
            let (width, height) = (image.width, image.height)
            self.width = width; self.height = height
            bytes = [UInt8](repeating: 0, count: width * height * 4)
            let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
                // A very large image can exceed what CoreGraphics allocates; that is reported, not trapped.
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: Self.space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.setBlendMode(.copy)
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard drawn else { throw Failure.contextUnavailable }
        }

        static let space = CGColorSpace(name: CGColorSpace.sRGB)!

        var image: CGImage {
            let provider = CGDataProvider(data: Data(bytes) as CFData)!
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: Self.space,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }

        /// Every pixel in `area` becomes opaque black.
        mutating func fill(_ area: PixelArea) {
            for y in area.minY..<area.maxY {
                for x in area.minX..<area.maxX {
                    let start = (y * width + x) * 4
                    bytes[start] = 0; bytes[start + 1] = 0; bytes[start + 2] = 0; bytes[start + 3] = 255
                }
            }
        }

        mutating func pixelate(_ area: PixelArea, cell: Int) {}
    }
}
