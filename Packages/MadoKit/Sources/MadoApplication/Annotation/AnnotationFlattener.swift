import CoreGraphics
import MadoCore

/// Merges marks into the upright pixels of an image. CoreGraphics only; no file I/O.
public enum AnnotationFlattener {
    public enum Failure: Error, Equatable { case contextUnavailable }

    /// `orientation` is the EXIF orientation (1…8) of `image`; the result is upright and has no orientation.
    public static func flatten(_ image: CGImage, orientation: Int, marks: [AnnotationMark]) throws -> CGImage {
        let size = uprightSize(width: image.width, height: image.height, orientation: orientation)
        let format = BitmapFormat(image)
        let markSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        // A very large image can exceed what CoreGraphics allocates; that is reported, not trapped.
        guard let context = bitmap(size, format: format) else { throw Failure.contextUnavailable }
        let height = CGFloat(size.height)
        context.saveGState()
        context.concatenate(uprightTransform(width: CGFloat(image.width), height: CGFloat(image.height),
                                             orientation: orientation))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        for mark in marks {
            let style = mark.style
            context.setStrokeColor(CGColor(colorSpace: markSpace, components: [style.red, style.green, style.blue, 1])!)
            context.setLineWidth(style.lineWidth)
            // Marks use a top-left origin; CoreGraphics draws from the bottom left.
            let rect = mark.rect
            context.stroke(CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height))
        }
        guard let result = context.makeImage() else { throw Failure.contextUnavailable }
        return result
    }

    /// The copy keeps the source's RGB colour space (Display P3, extended ranges) and depth: 8-bit, 16-bit, or 32-bit
    /// float for float (HDR) sources, so pixels outside the marks are unchanged (#690 fix r1). Sources without an RGB
    /// colour space CoreGraphics can draw into (grey, CMYK, none) fall back to sRGB 8-bit, which can hold the red marks.
    struct BitmapFormat {
        let space: CGColorSpace
        let bitsPerComponent: Int
        let bitmapInfo: UInt32

        init(_ image: CGImage) {
            let premultipliedLast = CGImageAlphaInfo.premultipliedLast.rawValue
            guard let space = image.colorSpace, space.model == .rgb, space.supportsOutput else {
                self.init(space: CGColorSpace(name: CGColorSpace.sRGB)!, bitsPerComponent: 8, bitmapInfo: premultipliedLast)
                return
            }
            if image.bitmapInfo.contains(.floatComponents) {
                self.init(space: space, bitsPerComponent: 32,
                          bitmapInfo: premultipliedLast | CGBitmapInfo.floatComponents.rawValue)
            } else {
                self.init(space: space, bitsPerComponent: image.bitsPerComponent > 8 ? 16 : 8, bitmapInfo: premultipliedLast)
            }
        }

        private init(space: CGColorSpace, bitsPerComponent: Int, bitmapInfo: UInt32) {
            self.space = space; self.bitsPerComponent = bitsPerComponent; self.bitmapInfo = bitmapInfo
        }
    }

    private static func bitmap(_ size: (width: Int, height: Int), format: BitmapFormat) -> CGContext? {
        CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: format.bitsPerComponent,
                  bytesPerRow: 0, space: format.space, bitmapInfo: format.bitmapInfo)
    }

    /// The displayed size of an image with this EXIF orientation.
    public static func uprightSize(width: Int, height: Int, orientation: Int) -> (width: Int, height: Int) {
        (5...8).contains(orientation) ? (height, width) : (width, height)
    }

    /// Maps the stored image, drawn at the origin in CoreGraphics' bottom-left space, to its upright position.
    private static func uprightTransform(width w: CGFloat, height h: CGFloat, orientation: Int) -> CGAffineTransform {
        switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: .identity
        }
    }
}
