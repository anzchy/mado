import AppKit
import MadoApplication
public enum DesignAppearance: CaseIterable {
    case system, light, dark
    public var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
    @MainActor public func apply(to window: NSWindow) { window.appearance = appearance }
}

public extension DesignAppearance {
    init(_ preference: DisplayAppearance) {
        switch preference {
        case .system: self = .system
        case .light: self = .light
        case .dark: self = .dark
        }
    }
}
