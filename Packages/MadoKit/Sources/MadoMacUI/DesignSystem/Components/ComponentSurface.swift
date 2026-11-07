import SwiftUI
/// Shared state chrome used by reusable components and their App host.
public struct ComponentSurface: View {
    public let kind: ComponentKind
    public let state: ComponentState
    public let theme: DesignTheme
    public init(kind: ComponentKind, state: ComponentState, theme: DesignTheme) {
        self.kind = kind; self.state = state; self.theme = theme
    }
    public var body: some View {
        let style = ComponentResolver.resolve(kind, state: state, theme: theme)
        RoundedRectangle(cornerRadius: DesignMetrics.radii["control"]!)
            .fill(style.background?.color ?? .clear)
            .overlay(RoundedRectangle(cornerRadius: DesignMetrics.radii["control"]!)
                .strokeBorder(style.focusRing ? DesignColor.focusRing.color : style.border?.color ?? .clear, lineWidth: 2))
            .opacity(style.opacity)
    }
}
