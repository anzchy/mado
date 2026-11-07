import AppKit
import SwiftUI

public enum DesignTheme: CaseIterable, Sendable { case light, dark }
public enum DesignColor: String, CaseIterable, Sendable {
    case waitingIndicator
    case canvasBackground, sidebarBackground, popoverBackground, textPrimary, textSecondary
    case divider, dividerSubtle, hoverBackground, accent, focusRing, selectionFill, selectionText
    case primaryFill, primaryFillHover, onPrimary, controlBorder, inputBackground, error, errorFill, errorText, scrim

    /// Hand-written sRGB bytes (fractional bytes preserve CSS sRGB mixing) and explicit alpha.
    public func components(_ theme: DesignTheme) -> [Double] {
        let dark = theme == .dark
        let text: [Double] = dark ? [229, 231, 235] : [26, 26, 26]
        let blue: [Double] = dark ? [96, 165, 250] : [37, 99, 235]
        let rgb: [Double]; let alpha: Double
        switch self {
        case .waitingIndicator: rgb = [245, 158, 11]; alpha = 1
        case .canvasBackground: rgb = dark ? [15, 17, 21] : [255, 255, 255]; alpha = 1
        case .sidebarBackground: rgb = dark ? [22, 26, 34] : [246, 247, 251]; alpha = 1
        case .popoverBackground: rgb = dark ? [20, 24, 33] : [255, 255, 255]; alpha = 1
        case .textPrimary: rgb = text; alpha = 1
        case .textSecondary: rgb = dark ? [154, 164, 178] : [107, 114, 128]; alpha = 1
        case .divider: rgb = text; alpha = dark ? 0.12 : 0.10
        case .dividerSubtle: rgb = text; alpha = dark ? 0.07 : 0.06
        case .hoverBackground: rgb = text; alpha = dark ? 0.08 : 0.05
        case .accent, .focusRing: rgb = blue; alpha = 1
        case .selectionFill: rgb = blue; alpha = dark ? 0.22 : 0.14
        case .selectionText: rgb = dark ? blue : [34.8, 84.4, 193.2]; alpha = 1
        case .primaryFill: rgb = dark ? [29, 78, 216] : blue; alpha = 1
        case .primaryFillHover: rgb = dark ? [25.52, 68.64, 190.08] : [35.68, 90.24, 209.92]; alpha = 1
        case .onPrimary: rgb = [255, 255, 255]; alpha = 1
        case .controlBorder: rgb = text; alpha = 0.5
        case .inputBackground: rgb = dark ? [15, 18, 28] : [255, 255, 255]; alpha = 0.9
        case .error: rgb = dark ? [248, 113, 113] : [220, 38, 38]; alpha = 1
        case .errorFill: rgb = dark ? [248, 113, 113] : [220, 38, 38]; alpha = dark ? 0.18 : 0.12
        case .errorText: rgb = dark ? [248, 113, 113] : [185, 28, 28]; alpha = 1
        case .scrim: rgb = [15, 23, 42]; alpha = 0.35
        }
        return rgb.map { $0 / 255 } + [alpha]
    }
    public var nsColor: NSColor {
        NSColor(name: NSColor.Name("mado.\(rawValue)")) { appearance in
            let c = components(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
            return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c[3])
        }
    }
    public var color: Color { Color(nsColor: nsColor) }
}
