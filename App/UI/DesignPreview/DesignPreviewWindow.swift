#if DEBUG
import AppKit
import SwiftUI
import MadoMacUI

/// Menu target is cheap; the window and both hosting trees are created on first activation.
@MainActor final class DesignPreviewLauncher: NSObject {
    static let shared = DesignPreviewLauncher()
    @objc func openPreview(_ sender: Any?) { DesignPreviewWindow.shared.openPreview(sender) }
}
@MainActor final class DesignPreviewWindow: NSWindowController {
    static let shared = DesignPreviewWindow()
    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 900),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Component Preview — Preview data"
        window.isReleasedWhenClosed = false
        let columns = NSStackView()
        columns.orientation = .horizontal; columns.distribution = .fillEqually; columns.spacing = 0
        for theme in DesignTheme.allCases {
            let host = NSHostingView(rootView: DesignPreviewPage(theme: theme).environment(\.colorScheme, theme == .light ? .light : .dark))
            host.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
            columns.addArrangedSubview(host)
        }
        window.contentView = columns
        window.minSize = NSSize(width: 900, height: 500)
        super.init(window: window)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    @objc func openPreview(_ sender: Any?) { showWindow(sender); window?.makeKeyAndOrderFront(sender) }
}
struct AppKitColorSwatch: NSViewRepresentable {
    let role: DesignColor
    func makeNSView(context: Context) -> NativeSwatch { NativeSwatch(role: role) }
    func updateNSView(_ view: NativeSwatch, context: Context) { view.role = role; view.needsDisplay = true }
    final class NativeSwatch: NSView {
        var role: DesignColor
        init(role: DesignColor) { self.role = role; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance { role.nsColor.setFill(); bounds.fill() }
        }
    }
}
struct DesignPreviewPage: View {
    let theme: DesignTheme
    @State private var query = "旅行"
    @State private var activations = 0
    @State private var expanded = false
    @State private var reduceMotion = false
    private let states: [(String, ComponentState)] = [("Default", []), ("Hover", .hover), ("Pressed", .pressed), ("Selected", .selected), ("Keyboard focus", .keyboardFocused), ("Disabled", .disabled), ("Selected + focus", [.selected, .keyboardFocused])]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(theme == .light ? "Light · Preview data" : "Dark · Preview data").font(Font(DesignMetrics.font("title")))
                Text("Page 30 · forced states and native live controls").foregroundStyle(DesignColor.textSecondary.color)
                Text("Icon command button")
                HStack(alignment: .top, spacing: 12) {
                    ForEach(states, id: \.0) { title, state in
                        VStack { IconCommandButton(symbol: .sidebar, state: state, theme: theme, input: .forced) { activations += 1 }; Text(title).font(.system(size: 12)).frame(width: 55) }
                    }
                }
                Text("Folder navigation · selection and disclosure are independent")
                ForEach(states, id: \.0) { title, state in
                    VStack(alignment: .leading, spacing: 2) {
                        FolderNavigationRow(nodeID: title, name: "日本 · 山海之间 · 很长的文件夹名称用于检查截断与完整名称访问", count: 12, expanded: expanded, state: state, theme: theme, input: .forced, onSelect: { activations += 1 }, onExpand: { expanded.toggle() })
                        Text(title).font(.system(size: 12)).foregroundStyle(DesignColor.textSecondary.color)
                    }
                }
                Text("Thumbnail selection")
                HStack { ForEach([false, true], id: \.self) { selected in
                    VStack { ThumbnailSelectionFrame(filename: "DSC_0341_very_long_preview_filename.jpg", state: selected ? .selected : [], theme: theme, input: .forced) { activations += 1 }; Text(selected ? "Selected" : "Unselected") }
                } }
                Text("Search · active filter, zero results, clear action")
                SearchFilterField(query: $query, resultCount: 0, state: .keyboardFocused, theme: theme, input: .forced) { query = "" }
                HStack { ScaleIndicator(actualPixels: false, input: .forced) { activations += 1 }; ScaleIndicator(actualPixels: true, input: .forced) { activations += 1 } }
                Text("Scale · fit / actual pixels")
                IndeterminateProgressRow(label: "Reading folder…")
                Text("Indeterminate · no total available").foregroundStyle(DesignColor.textSecondary.color)
                ImageErrorRow(message: "Can't read this image", state: [], input: .forced) { activations += 1 }
                HStack { ImageStatusCount(count: 12); ShortcutHint(text: "Space"); Text("Quick Look · preview hint") }
                Text("Live · hover, press and Tab · \(activations) activations")
                HStack { ForEach([DesignSymbol.previous, .next, .info], id: \.self) { role in
                    IconCommandButton(symbol: role, state: [], theme: theme, input: .live) { activations += 1 }
                } }
                FolderNavigationRow(nodeID: "live-folder", name: "Live folder · preview data", count: activations, expanded: expanded, state: [], theme: theme, input: .live, onSelect: { activations += 1 }, onExpand: { expanded.toggle() })
                SearchFilterField(query: $query, resultCount: 0, state: [], theme: theme, input: .live) { query = "" }
                HStack { ScaleIndicator(actualPixels: false, input: .live) { activations += 1 }; ImageErrorRow(message: "Live retry", state: [], input: .live) { activations += 1 } }
                Toggle("Reduce Motion (preview override)", isOn: $reduceMotion)
                Text("Transition: \(ComponentResolver.transition(reduceMotion: reduceMotion).formatted()) s")
                Text("Colour roles · AppKit / SwiftUI on canvas background")
                ForEach(DesignColor.allCases, id: \.self) { role in
                    HStack {
                        Text(role.rawValue).frame(width: 180, alignment: .leading)
                        AppKitColorSwatch(role: role).frame(width: 90, height: 22)
                        Rectangle().fill(role.color).frame(width: 90, height: 22)
                    }
                }
            }.font(Font(DesignMetrics.font("ui"))).foregroundStyle(DesignColor.textPrimary.color)
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.designReduceMotion, reduceMotion)
        }.background(DesignColor.canvasBackground.color)
    }
}
#endif
