import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// The built-in sample the Settings Test sends instead of the user's image (#869 AC-6, spec #866 story 14): a small
/// ruled table drawn here, so the expected cells and the picture cannot drift apart. ASCII only, large and plain, so
/// any vision model that works at all reads it exactly.
enum TableRecognitionSample {
    static let rows: [[String]] = [
        ["Item", "Qty", "Price"],
        ["Apple", "3", "1.20"],
        ["Pear", "5", "0.80"],
    ]

    /// Rendered once; every Test sends the same bytes.
    static let png: Data = render()

    /// Same shape, and every cell equal after trimming and ignoring case. Anything else is not a pass.
    static func matches(_ candidate: [[String]]) -> Bool {
        guard candidate.count == rows.count else { return false }
        return zip(candidate, rows).allSatisfy { got, want in
            got.count == want.count && zip(got, want).allSatisfy { cell, expected in
                cell.trimmingCharacters(in: .whitespacesAndNewlines)
                    .compare(expected, options: [.caseInsensitive]) == .orderedSame
            }
        }
    }

    private static let cellWidth = 220, cellHeight = 72, margin = 24

    private static func render() -> Data {
        let columns = rows[0].count
        let width = margin * 2 + cellWidth * columns, height = margin * 2 + cellHeight * rows.count
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(2)
        // Core Graphics' origin is bottom-left; row 0 is drawn at the top.
        let top = height - margin
        for line in 0...rows.count {
            let y = CGFloat(top - line * cellHeight)
            context.strokeLineSegments(between: [CGPoint(x: margin, y: Int(y)), CGPoint(x: width - margin, y: Int(y))])
        }
        for line in 0...columns {
            let x = CGFloat(margin + line * cellWidth)
            context.strokeLineSegments(between: [CGPoint(x: x, y: CGFloat(margin)), CGPoint(x: x, y: CGFloat(top))])
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 34, nil)
        let black = CGColor(gray: 0, alpha: 1)
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, text) in row.enumerated() {
                let attributes = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: black] as CFDictionary
                guard let string = CFAttributedStringCreate(nil, text as CFString, attributes) else { continue }
                let line = CTLineCreateWithAttributedString(string)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let textWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                let cellX = CGFloat(margin + columnIndex * cellWidth)
                let cellY = CGFloat(top - (rowIndex + 1) * cellHeight)
                // Centre on the typographic box (baseline + descent … ascent), independent of earlier draws.
                context.textPosition = CGPoint(x: cellX + (CGFloat(cellWidth) - textWidth) / 2,
                                               y: cellY + (CGFloat(cellHeight) - ascent - descent) / 2 + descent)
                CTLineDraw(line, context)
            }
        }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : Data()
    }
}
