import SwiftUI

private struct DesignReduceMotionKey: EnvironmentKey { static let defaultValue = false }
public extension EnvironmentValues {
    var designReduceMotion: Bool {
        get { self[DesignReduceMotionKey.self] }
        set { self[DesignReduceMotionKey.self] = newValue }
    }
}

/// Components default to live input; preview samples explicitly opt into forced state.
struct DesignCommandStyle: ButtonStyle {
    let kind: ComponentKind; let state: ComponentState; let theme: DesignTheme; let input: ComponentInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.designReduceMotion) private var designReduceMotion
    func makeBody(configuration: Configuration) -> some View {
        let current = input.state(state, pressed: configuration.isPressed)
        let style = ComponentResolver.resolve(kind, state: current, theme: theme)
        configuration.label.padding(6).foregroundStyle(style.foreground.color.opacity(style.opacity))
            .background(ComponentSurface(kind: kind, state: current, theme: theme))
            .animation(.easeOut(duration: ComponentResolver.transition(reduceMotion: reduceMotion || designReduceMotion)), value: current)
    }
}
public struct IconCommandButton: View {
    public init(symbol: DesignSymbol, state: ComponentState, theme: DesignTheme, input: ComponentInput = .live, action: @escaping () -> Void) {
        self.symbol = symbol; self.state = state; self.theme = theme; self.input = input; self.action = action
    }
    func activate() { guard input == .live else { return }; ComponentResolver.activate(.click, state: current, action: action) }
    func activateFromKeyboard() -> KeyPress.Result {
        guard input == .live else { return .ignored }
        ComponentResolver.activate(.keyboard, state: current, action: action)
        return .handled
    }
    let symbol: DesignSymbol; let state: ComponentState; let theme: DesignTheme; let input: ComponentInput; let action: () -> Void
    var receiveHoverHandler: ((@escaping (Bool) -> Void) -> Void)?
    @State private var hover = false
    @FocusState private var focused: Bool
    var current: ComponentState { input.state(state, hover: hover, focused: focused) }
    func updateHover(_ value: Bool) { hover = value }
    public var body: some View {
        let hoverHandler = updateHover
        Button(action: activate) {
            Image(nsImage: symbol.image()).resizable().scaledToFit().frame(width: 16, height: 16)
                .frame(width: DesignMetrics.hitArea[0]-12, height: DesignMetrics.hitArea[1]-12)
        }
        .buttonStyle(DesignCommandStyle(kind: .icon, state: current, theme: theme, input: input))
        .disabled(state.contains(.disabled)).allowsHitTesting(input == .live).focusable(input == .live).focused($focused).focusEffectDisabled(input == .forced).onHover(perform: hoverHandler)
        .onAppear { receiveHoverHandler?(hoverHandler) }
        .onKeyPress(.space, action: activateFromKeyboard)
        .accessibilityLabel(Text(String(localized: String.LocalizationValue(symbol.label)))).help(Text(String(localized: String.LocalizationValue(symbol.label))))
    }
}
public struct ShortcutHint: View {
    public init(text: String) { self.text = text }
    let text: String
    public var body: some View {
        Text(text).foregroundStyle(DesignColor.textPrimary.color).font(Font(DesignMetrics.font("uiSmall", monospaced: true))).padding(4)
            .background(DesignColor.hoverBackground.color, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DesignColor.divider.color))
    }
}
public struct FolderNavigationRow: View {
    public init(nodeID: String, name: String, count: Int?, expanded: Bool, state: ComponentState, theme: DesignTheme, input: ComponentInput = .live, onSelect: @escaping () -> Void, onExpand: @escaping () -> Void) {
        self.nodeID = nodeID; self.name = name; self.count = count; self.expanded = expanded; self.state = state; self.theme = theme; self.input = input; self.onSelect = onSelect; self.onExpand = onExpand
    }
    func select() { guard input == .live else { return }; ComponentResolver.activate(.click, state: state, action: onSelect) }
    func expand() { guard input == .live else { return }; ComponentResolver.activate(.click, state: state, action: onExpand) }
    func selectFromKeyboard() -> KeyPress.Result {
        guard input == .live else { return .ignored }
        ComponentResolver.activate(.keyboard, state: state, action: onSelect)
        return .handled
    }
    func expandFromKeyboard() -> KeyPress.Result {
        guard input == .live else { return .ignored }
        ComponentResolver.activate(.keyboard, state: state, action: onExpand)
        return .handled
    }
    let nodeID: String; let name: String; let count: Int?; let expanded: Bool
    let state: ComponentState; let theme: DesignTheme; let input: ComponentInput; let onSelect: () -> Void; let onExpand: () -> Void
    var receiveHoverHandler: ((@escaping (Bool) -> Void) -> Void)?
    @State private var hover = false
    @FocusState private var focused: Bool
    var current: ComponentState { input.state(state, hover: hover, focused: focused) }
    func updateHover(_ value: Bool) { hover = value }
    public var body: some View {
        let hoverHandler = updateHover
        HStack(spacing: 4) {
            Button(expanded ? "▾" : "▸", action: expand).focusable(input == .live).focusEffectDisabled(input == .forced)
                .onKeyPress(.space, action: expandFromKeyboard)
                .accessibilityLabel(Text(expanded ? "Collapse folder" : "Expand folder"))
            Button(action: select) {
                HStack {
                    Image(nsImage: DesignSymbol.folder.image()); Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let count { Text(count.formatted()).font(Font(DesignMetrics.font("uiSmall", monospaced: true))).foregroundStyle(DesignColor.textSecondary.color) }
                }.frame(maxWidth: .infinity, minHeight: 20)
            }.focusable(input == .live).focused($focused).focusEffectDisabled(input == .forced).onKeyPress(.space, action: selectFromKeyboard).accessibilityLabel(name).help(name)
        }
        .buttonStyle(DesignCommandStyle(kind: .folder, state: current, theme: theme, input: input))
        .disabled(state.contains(.disabled)).allowsHitTesting(input == .live).onHover(perform: hoverHandler).id(nodeID)
        .onAppear { receiveHoverHandler?(hoverHandler) }
        .accessibilityAddTraits(state.contains(.selected) ? .isSelected : [])
    }
}
public struct ThumbnailSelectionFrame: View {
    public init(filename: String, state: ComponentState, theme: DesignTheme, input: ComponentInput = .live, action: @escaping () -> Void) {
        self.filename = filename; self.state = state; self.theme = theme; self.input = input; self.action = action
    }
    func activate() { guard input == .live else { return }; ComponentResolver.activate(.click, state: state, action: action) }
    let filename: String; let state: ComponentState; let theme: DesignTheme; let input: ComponentInput; let action: () -> Void
    public var body: some View {
        Button(action: activate) {
            VStack(spacing: 4) {
                // Drawn preview data, independent of image loading and file access.
                ZStack { Rectangle().fill(DesignColor.sidebarBackground.color); Image(systemName: "mountain.2").font(.system(size: 28)) }
                    .frame(width: 120, height: 64)
                    .overlay(ComponentSurface(kind: .thumbnail, state: state, theme: theme))
                Text(filename).lineLimit(1).truncationMode(.middle).frame(width: 120)
                    .background(state.contains(.selected) ? DesignColor.selectionFill.color : .clear)
            }
        }.buttonStyle(.plain).focusable(input == .live).disabled(state.contains(.disabled)).allowsHitTesting(input == .live).help(filename).accessibilityLabel(filename)
    }
}
public struct SearchFilterField: View {
    public init(query: Binding<String>, resultCount: Int, state: ComponentState, theme: DesignTheme, input: ComponentInput = .live, clear: @escaping () -> Void) {
        self._query = query; self.resultCount = resultCount; self.state = state; self.theme = theme; self.input = input; self.clear = clear
    }
    func activate() { guard input == .live else { return }; ComponentResolver.activate(.click, state: state, action: clear) }
    @Binding var query: String
    let resultCount: Int; let state: ComponentState; let theme: DesignTheme; let input: ComponentInput; let clear: () -> Void
    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search current folder", text: $query).textFieldStyle(.roundedBorder).focusable(input == .live)
                .background(ComponentSurface(kind: .search, state: state, theme: theme))
            HStack {
                Text("Filter: \(query) · \(resultCount) results").foregroundStyle(DesignColor.selectionText.color)
                Button("Clear search", action: activate).focusable(input == .live)
            }.padding(4).background(DesignColor.selectionFill.color)
            if resultCount == 0 { Text("No matching images").foregroundStyle(DesignColor.textSecondary.color) }
        }.disabled(state.contains(.disabled)).allowsHitTesting(input == .live)
    }
}
public struct ScaleIndicator: View {
    static func modeLabel(actualPixels: Bool, customZoom: Double?) -> String {
        if actualPixels { return "1:1 · 100%" }
        if let customZoom { return customZoom.formatted(.percent.precision(.fractionLength(0...2))) }
        return String(localized: "Fit window")
    }
    /// Own the complete label appearance so disabled ink is dimmed exactly once.
    private struct LabelStyle: ButtonStyle {
        let state: ComponentState
        let fill: DesignColor?
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(fill?.color ?? .clear, in: RoundedRectangle(cornerRadius: DesignMetrics.radii["inner"]!))
                .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radii["inner"]!)
                    .strokeBorder(state.contains(.keyboardFocused) ? DesignColor.focusRing.color : .clear, lineWidth: 2))
                .opacity(state.contains(.disabled) ? 0.4 : 1)
        }
    }
    public init(actualPixels: Bool, customZoom: Double? = nil, state: ComponentState = [], theme: DesignTheme = .light, input: ComponentInput = .live, action: @escaping () -> Void) {
        self.actualPixels = actualPixels; self.customZoom = customZoom; self.state = state; self.theme = theme; self.input = input; self.action = action
    }
    func activate() { guard input == .live else { return }; action() }
    public var label: String { Self.modeLabel(actualPixels: actualPixels, customZoom: customZoom) }
    let state: ComponentState; let theme: DesignTheme
    let actualPixels: Bool; let customZoom: Double?; let input: ComponentInput; let action: () -> Void
    @State private var hover = false
    @FocusState private var focused: Bool
    private var current: ComponentState { input.state(state, hover: hover, focused: focused) }
    private var fill: DesignColor? {
        if current.contains(.selected) || current.contains(.pressed) { return .selectionFill }
        return current.contains(.hover) ? .hoverBackground : nil
    }
    func updateHover(_ value: Bool) { hover = value }
    /// Receives the installed `onHover` handler; tests drive hover without a real pointer.
    var receiveHoverHandler: ((@escaping (Bool) -> Void) -> Void)?
    public var body: some View {
        let hoverHandler = updateHover
        Button(action: activate) {
            Text(label)
                .font(Font(DesignMetrics.font("uiSmall")))
                .foregroundStyle(DesignColor.textPrimary.color)
                .padding(5)
                .frame(minWidth: 100)
        }
        .buttonStyle(LabelStyle(state: current, fill: fill))
        .disabled(state.contains(.disabled))
        .focusable(input == .live)
        .focused($focused)
        .focusEffectDisabled(input == .forced)
        .onHover(perform: hoverHandler)
        .onAppear { receiveHoverHandler?(hoverHandler) }
        .allowsHitTesting(input == .live)
    }
}
public struct IndeterminateProgressRow: View {
    public init(label: String) { self.label = label }
    let label: String
    public var body: some View { HStack { ProgressView().controlSize(.small); Text(label) } }
}
public struct ImageErrorRow: View {
    public init(message: String, state: ComponentState, input: ComponentInput = .live, retry: @escaping () -> Void) {
        self.message = message; self.state = state; self.input = input; self.retry = retry
    }
    func activate() { guard input == .live else { return }; ComponentResolver.activate(.click, state: state, action: retry) }
    let message: String; let state: ComponentState; let input: ComponentInput; let retry: () -> Void
    public var body: some View {
        HStack {
            Text(message).foregroundStyle(DesignColor.errorText.color)
            Button("Retry", action: activate).focusable(input == .live)
                .disabled(state.contains(.disabled)).allowsHitTesting(input == .live)
        }
    }
}
public struct ImageStatusCount: View {
    public init(count: Int) { self.count = count }
    let count: Int
    public var body: some View { Text("\(count) images").font(Font(DesignMetrics.font("uiSmall", monospaced: true))).foregroundStyle(DesignColor.textSecondary.color) }
}
