import CoreGraphics
import MadoCore

/// Merges marks into the upright pixels of an image. CoreGraphics only; no file I/O.
public enum AnnotationFlattener {
    public enum Failure: Error, Equatable { case contextUnavailable }

    /// #693: a redaction's on-screen pixels: the copy's pixels in `area`, with the marks up to the redaction.
    public struct RedactionPatch: @unchecked Sendable {
        public let image: CGImage
        /// Whole upright image pixels, top-left origin.
        public let area: CGRect
    }

    /// `orientation` is the EXIF orientation (1…8) of `image`; the result is upright and has no orientation.
    /// Marks are drawn in order; a redaction (#693) hides the pixels drawn so far (the image and the marks before it)
    /// through `RedactionRenderer`. A crop is applied last, so the result is the crop's size and holds exactly the
    /// uncropped result's pixels inside it.
    public static func flatten(_ image: CGImage, orientation: Int, marks: [AnnotationMark],
                               crop: CGRect? = nil) throws -> CGImage {
        let size = uprightSize(width: image.width, height: image.height, orientation: orientation)
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let result = try draw(image, orientation: orientation, marks: marks, size: size)
        guard let crop else { return result }
        let cut = crop.integral.intersection(bounds)
        guard !cut.isNull, cut.width > 0, cut.height > 0, let cropped = result.cropping(to: cut) else {
            throw Failure.contextUnavailable
        }
        return cropped
    }

    /// #693: what the copy shows where the redaction at `index` is, so the screen can show the same pixels: the
    /// flatten of the marks up to it, cut to its whole pixels. (Drawing only a part of the image was measured to
    /// antialias a mark crossing that part's edge one level differently, so the whole image is drawn.) Nil when
    /// `index` is not a redaction on the image.
    public static func redactionPatch(_ image: CGImage, orientation: Int, marks: [AnnotationMark],
                                      index: Int) throws -> RedactionPatch? {
        guard marks.indices.contains(index), marks[index].kind == .redaction else { return nil }
        let size = uprightSize(width: image.width, height: image.height, orientation: orientation)
        guard let pixels = RedactionRenderer.PixelArea(marks[index].rect, width: size.width, height: size.height) else {
            return nil
        }
        let area = CGRect(x: pixels.minX, y: pixels.minY, width: pixels.maxX - pixels.minX, height: pixels.maxY - pixels.minY)
        return RedactionPatch(image: try flatten(image, orientation: orientation, marks: Array(marks[...index]), crop: area),
                              area: area)
    }

    /// Draws the upright image and `marks` in order.
    private static func draw(_ image: CGImage, orientation: Int, marks: [AnnotationMark],
                             size: (width: Int, height: Int)) throws -> CGImage {
        guard let context = bitmap(size, format: BitmapFormat(image)) else { throw Failure.contextUnavailable }
        context.saveGState()
        context.concatenate(uprightTransform(width: CGFloat(image.width), height: CGFloat(image.height),
                                             orientation: orientation))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.restoreGState()
        // Marks use a top-left origin; CoreGraphics draws from the bottom left. The renderer is the overlay's (#692).
        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(size.height))
        context.scaleBy(x: 1, y: -1)
        var failure: Error?
        AnnotationRenderer.draw(marks, in: context) { mark in
            guard failure == nil, let style = mark.redaction else { return }
            do { try redact(context, rect: mark.rect, style: style) } catch { failure = error }
        }
        context.restoreGState()
        if let failure { throw failure }
        guard let result = context.makeImage() else { throw Failure.contextUnavailable }
        return result
    }

    /// Replaces the pixels of `context` under `rect` (context pixels, top-left origin) with their redaction.
    private static func redact(_ context: CGContext, rect: CGRect, style: RedactionStyle) throws {
        guard let drawn = context.makeImage() else { throw Failure.contextUnavailable }
        let width = context.width, height = context.height
        guard let area = RedactionRenderer.PixelArea(rect, width: width, height: height) else { return }
        let redacted = try RedactionRenderer.render(drawn, rect: rect, style: style)
        context.saveGState()
        context.concatenate(context.ctm.inverted())
        context.clip(to: CGRect(x: area.minX, y: height - area.maxY, width: area.maxX - area.minX,
                                height: area.maxY - area.minY))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(redacted, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.restoreGState()
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
