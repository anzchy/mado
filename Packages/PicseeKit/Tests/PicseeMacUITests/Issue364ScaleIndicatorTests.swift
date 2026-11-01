import AppKit
import SwiftUI
import Testing
@testable import PicseeMacUI

private struct Issue364PinnedScaleLabel: View {
    let label: String
    let hovered: Bool

    var body: some View {
        Button(action: {}) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(DesignColor.textSecondary.color)
                .padding(5)
                .frame(minWidth: 68)
        }
        .buttonStyle(.plain)
        .background(hovered ? DesignColor.hoverBackground.color : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
    }
}

@MainActor private func issue364Pixels<V: View>(_ view: V, theme: DesignTheme) throws -> Data {
    let renderer = ImageRenderer(content: view
        .frame(width: 122, height: 28)
        .background(DesignColor.popoverBackground.color)
        .environment(\.colorScheme, theme == .dark ? .dark : .light))
    renderer.scale = 1
    let image = try #require(renderer.cgImage)
    #expect(image.width == 122 && image.height == 28)
    return try #require(image.dataProvider?.data) as Data
}

@Test @MainActor func issue364ScaleLabelsMatchPinnedPlainAppearanceAndFit() throws {
    _ = NSApplication.shared
    let design = try PinnedDesign.page("viewer-controls")
    #expect(try design.exactDeclaration(".zoom-label", "background") == "transparent")
    #expect(try design.exactDeclaration(".zoom-label", "border") == "0")
    #expect(try design.length(".zoom-label", "padding", viewport: 1280) == 5)

    var liveScale = ScaleIndicator(actualPixels: false) {}
    liveScale.updateHover(true)
    liveScale.updateHover(false)

    for theme in DesignTheme.allCases {
        for (actualPixels, customZoom) in [(false, nil), (true, nil), (false, 12.34)] {
            let scale = ScaleIndicator(actualPixels: actualPixels, customZoom: customZoom,
                                       theme: theme, input: .forced) {}
            for hovered in [false, true] {
                let state: ComponentState = hovered ? .hover : []
                let actual = ScaleIndicator(actualPixels: actualPixels, customZoom: customZoom,
                                            state: state, theme: theme, input: .forced) {}
                let reference = Issue364PinnedScaleLabel(label: scale.label, hovered: hovered)
                #expect(try issue364Pixels(actual, theme: theme) == issue364Pixels(reference, theme: theme),
                        "page 14 .zoom-label \(scale.label), hovered=\(hovered), theme=\(theme)")
            }

            let actualHost = NSHostingView(rootView: scale)
            let referenceHost = NSHostingView(rootView: Issue364PinnedScaleLabel(label: scale.label, hovered: false))
            actualHost.layoutSubtreeIfNeeded()
            referenceHost.layoutSubtreeIfNeeded()
            #expect(referenceHost.fittingSize.width >= 68)
            #expect(abs(actualHost.fittingSize.width - referenceHost.fittingSize.width) < 0.01,
                    "min-width 68 and unpadded text must fit \(scale.label)")
        }

        let rest = ScaleIndicator(actualPixels: false, theme: theme, input: .forced) {}
        let focused = ScaleIndicator(actualPixels: false, state: .keyboardFocused,
                                     theme: theme, input: .forced) {}
        #expect(try issue364Pixels(rest, theme: theme) != issue364Pixels(focused, theme: theme),
                "keyboard focus keeps its visible ring")
    }
}
