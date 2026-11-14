import CoreGraphics
import CoreText
import Foundation
import MadoCore

/// #692: draws marks for both the flattened copy and the screen, so the same marks look the same in each.
public enum AnnotationRenderer {
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
