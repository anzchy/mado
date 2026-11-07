import SwiftUI
import AppKit
import Testing
@testable import MadoMacUI
@MainActor @Test func designSurfacesRenderBothThemes() throws {
    // NSBitmapImageRep.colorAt labels RGB samples as calibrated, losing this image's sRGB profile.
    // Read its encoded components directly after requiring an sRGB output image below.
    func channels(_ color: NSColor) -> [Double] {
        [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
    for theme in DesignTheme.allCases {
        for kind in ComponentKind.allCases {
            for state: ComponentState in [[], .hover, .pressed, .selected, .keyboardFocused, .disabled, [.selected, .keyboardFocused]] {
                let renderer = ImageRenderer(content: ComponentSurface(kind: kind, state: state, theme: theme)
                    .frame(width: 100, height: 40)
                    .background(DesignColor.canvasBackground.color)
                    .environment(\.colorScheme, theme == .light ? .light : .dark))
                renderer.scale = 1
                let cg = try #require(renderer.cgImage)
                #expect(cg.colorSpace?.name == CGColorSpace.sRGB)
                let pixels = NSBitmapImageRep(cgImage: cg)
                #expect(cg.width == 100 && cg.height == 40)
                if kind == .thumbnail && state == .selected {
                    let pixel = channels(try #require(pixels.colorAt(x: 50, y: 20)))
                    let base = DesignColor.canvasBackground.components(theme)
                    for i in 0..<3 { #expect(abs(pixel[i] - base[i]) < 0.03) }
                    continue
                }
                if state.contains(.keyboardFocused) {
                    let pixel = channels(try #require(pixels.colorAt(x: 50, y: 1)))
                    let expected = DesignColor.focusRing.components(theme)
                    for i in 0..<3 { #expect(abs(pixel[i] - expected[i]) < 0.03, "focus \(kind) \(theme)") }
                } else if state.contains(.selected) {
                    let pixel = channels(try #require(pixels.colorAt(x: 50, y: 20)))
                    let fill = (kind == .search ? DesignColor.inputBackground : .selectionFill).components(theme)
                    let base = DesignColor.canvasBackground.components(theme)
                    for i in 0..<3 { #expect(abs(pixel[i] - (fill[i]*fill[3]+base[i]*(1-fill[3]))) < 0.03, "selected \(kind) \(theme)") }
                }
            }
        }
    }
}
