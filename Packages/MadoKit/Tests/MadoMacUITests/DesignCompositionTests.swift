import SwiftUI
import AppKit
import Testing
@testable import MadoMacUI

@MainActor @Test func designCompositionsRenderAndRespectInputPolicy() throws {
    for theme in DesignTheme.allCases {
        for input in [ComponentInput.forced, .live] {
            for state: ComponentState in [[], .hover, .pressed, .selected, .keyboardFocused, .disabled, [.selected, .keyboardFocused]] {
                var calls = 0
                let icon = IconCommandButton(symbol: .sidebar, state: state, theme: theme, input: input) { calls += 1 }
                let folder = FolderNavigationRow(nodeID: "folder", name: "Long folder name", count: 12, expanded: true, state: state, theme: theme, input: input, onSelect: { calls += 1 }, onExpand: { calls += 1 })
                let thumbnail = ThumbnailSelectionFrame(filename: "Long filename.jpg", state: state, theme: theme, input: input) { calls += 1 }
                let search = SearchFilterField(query: .constant("旅行"), resultCount: 0, state: state, theme: theme, input: input) { calls += 1 }
                let scale = ScaleIndicator(actualPixels: true, input: input) { calls += 1 }
                let error = ImageErrorRow(message: "Cannot read image", state: state, input: input) { calls += 1 }
                icon.updateHover(true); icon.updateHover(false)
                folder.updateHover(true); folder.updateHover(false)
                icon.activate(); folder.select(); folder.expand(); thumbnail.activate(); search.activate(); error.activate()
                #expect(calls == (input == .live && !state.contains(.disabled) ? 6 : 0))
                let beforeScale = calls
                scale.activate()
                #expect(calls == beforeScale + (input == .live ? 1 : 0))
                let views: [AnyView] = [AnyView(icon), AnyView(folder), AnyView(thumbnail), AnyView(search), AnyView(scale), AnyView(error), AnyView(ShortcutHint(text: "Space")), AnyView(IndeterminateProgressRow(label: "Reading folder…")), AnyView(ImageStatusCount(count: 12)), AnyView(ScaleIndicator(actualPixels: false) {}), AnyView(FolderNavigationRow(nodeID: "empty", name: "No count", count: nil, expanded: false, state: [], theme: theme, onSelect: {}, onExpand: {})), AnyView(SearchFilterField(query: .constant("a"), resultCount: 1, state: [], theme: theme, clear: {}))]
                for view in views {
                    let renderer = ImageRenderer(content: view.frame(width: 260, height: 140)
                        .background(DesignColor.canvasBackground.color)
                        .environment(\.colorScheme, theme == .light ? .light : .dark)
                        .environment(\.designReduceMotion, state.contains(.hover)))
                    renderer.scale = 1
                    let cg = try #require(renderer.cgImage)
                    #expect(cg.width == 260 && cg.height == 140)
                    let pixels = NSBitmapImageRep(cgImage: cg)
                    let base = try #require(pixels.colorAt(x: 0, y: 0))
                    var changed = false
                    for y in stride(from: 40, to: 100, by: 3) {
                        for x in stride(from: 10, to: 250, by: 3) {
                            if pixels.colorAt(x: x, y: y) != base { changed = true }
                        }
                    }
                    #expect(changed, "Component must draw visible content in \(theme)")
                }
            }
        }
    }
}
