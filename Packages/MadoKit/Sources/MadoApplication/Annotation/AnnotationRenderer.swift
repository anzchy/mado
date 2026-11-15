import CoreGraphics
import CoreText
import Foundation
import MadoCore

/// #692: draws marks for both the flattened copy and the screen, so the same marks look the same in each.
public enum AnnotationRenderer {
    /// Draws `marks` in order. The context's user space must be the image's upright pixels with the origin at the top
    /// left (y down); the flattener sets that up for the copy and the overlay concatenates the image-to-view transform.
    /// `hiding` leaves out one mark (a text mark being edited) without changing the step numbers.
    public static func draw(_ marks: [AnnotationMark], in context: CGContext, hiding: Int? = nil) {
        let numbers = AnnotationGeometry.stepNumbers(marks)
        for (index, mark) in marks.enumerated() {
            guard index != hiding else { continue }
            context.saveGState()
            draw(mark, number: numbers[index] ?? 0, in: context)
            context.restoreGState()
        }
    }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static func paint(_ style: AnnotationStyle, alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: space, components: [style.red, style.green, style.blue, alpha])!
    }
    private static let white = CGColor(colorSpace: space, components: [1, 1, 1, 1])!

    private static func draw(_ mark: AnnotationMark, number: Int, in context: CGContext) {
        let style = mark.style, unit = style.unit
        context.setStrokeColor(paint(style))
        context.setFillColor(paint(style))
        context.setLineWidth(style.lineWidth)
        switch mark.kind {
        case .rectangle:
            context.stroke(mark.rect)
        case .arrow:
            guard mark.points.count == 2 else { return }
            let tail = mark.points[0], tip = mark.points[1]
            let (a, b) = AnnotationGeometry.arrowHead(tail: tail, tip: tip, lineWidth: style.lineWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addLines(between: [tail, tip])
            context.addLines(between: [a, tip, b])
            context.strokePath()
        case .pen, .highlighter:
            guard let first = mark.points.first else { return }
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(AnnotationMetrics.drawnWidth(mark))
            if mark.kind == .highlighter { context.setStrokeColor(paint(style, alpha: AnnotationMetrics.highlighterOpacity)) }
            // One path, stroked once: where it crosses itself the highlighter does not darken.
            context.addLines(between: mark.points.count == 1 ? [first, first] : mark.points)
            context.strokePath()
        case .step:
            guard let centre = mark.points.first else { return }
            let radius = AnnotationMetrics.stepDiameter * unit / 2
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            let size = AnnotationMetrics.stepFontSize * unit
            let line = self.line(String(number), fontSize: size)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            let capHeight = CTFontGetCapHeight(font(size))
            context.setFillColor(white)
            text(line, at: CGPoint(x: centre.x - width / 2, y: centre.y + capHeight / 2), in: context)
        case .text:
            guard let origin = mark.points.first else { return }
            let line = self.line(mark.text, fontSize: AnnotationMetrics.textFontSize * unit)
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            let baseline = CGPoint(x: origin.x, y: origin.y + ascent)
            // Page 39's `paint-order="stroke"`: the white halo first, the red fill over it.
            context.setTextDrawingMode(.stroke)
            context.setStrokeColor(white)
            context.setLineWidth(AnnotationMetrics.textHalo * unit)
            context.setLineJoin(.round)
            text(line, at: baseline, in: context)
            context.setTextDrawingMode(.fill)
            text(line, at: baseline, in: context)
        }
    }

    /// Draws a line upright with its baseline at `baseline` in the y-down user space.
    private static func text(_ line: CTLine, at baseline: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: baseline.x, y: baseline.y)
        context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }

    /// The line box of `text` set in the text mark's font at `fontSize` image pixels.
    public static func textSize(_ text: String, fontSize: Double) -> CGSize {
        let line = self.line(text, fontSize: fontSize)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        return CGSize(width: ceil(width), height: ceil(ascent + descent + leading))
    }

    /// Page 39's mark font: the system font, semibold (`font-weight: 600`).
    static func font(_ size: Double) -> CTFont {
        let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
        let traits = [kCTFontWeightTrait: 0.3] as CFDictionary
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(system),
                                                                  [kCTFontTraitsAttribute: traits] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func line(_ text: String, fontSize: Double) -> CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font(fontSize), kCTForegroundColorFromContextAttributeName: true]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes as [NSAttributedString.Key: Any]))
    }
}
