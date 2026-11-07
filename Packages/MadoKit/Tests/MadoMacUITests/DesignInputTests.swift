import SwiftUI
import AppKit
import Testing
@testable import MadoMacUI

@MainActor @Test func designForcedSamplesIgnoreLiveInput() throws {
    for theme in DesignTheme.allCases {
        for supplied: ComponentState in [[], .hover, .pressed, .selected, .keyboardFocused, .disabled] {
            for input in [ComponentInput.forced, .live] {
                let idle = input.state(supplied)
                let active = input.state(supplied, hover: true, focused: true, pressed: true)
                func pixels(_ state: ComponentState) throws -> Data {
                    let renderer = ImageRenderer(content: ComponentSurface(kind: .icon, state: state, theme: theme)
                        .frame(width: 30, height: 28).background(DesignColor.canvasBackground.color)
                        .environment(\.colorScheme, theme == .light ? .light : .dark))
                    return try #require(renderer.cgImage?.dataProvider?.data) as Data
                }
                if input == .forced {
                    #expect(active == supplied)
                    #expect(try pixels(idle) == pixels(active))
                } else {
                    #expect(active.contains([.hover, .keyboardFocused, .pressed]))
                }
            }
        }
    }
}
