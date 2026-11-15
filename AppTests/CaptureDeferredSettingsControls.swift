import AppKit

/// The only disabled Settings controls owned by later Capture tickets.
@MainActor enum CaptureDeferredSettingsControls {
    /// Empty since #689 slice B made the 文字识别 controls live.
    static let tickets: [String: Int] = [:]

    /// Live controls that are greyed and not editable while the Capture Bar is off (grilling 5.2, #684, #685).
    static let barDependent: Set<String> = [
        "settings.capture.after-save", "settings.capture.after-copy", "settings.capture.login",
        "settings.capture.folder-change", "settings.capture.shortcut-region", "settings.capture.shortcut-1",
        "settings.capture.shortcut-2", "settings.capture.shortcut-3", "settings.capture.shortcut-4",
        "settings.capture.shortcut-restore",
    ]

    static func unexpectedDisabledIDs(_ controls: [NSControl]) -> [String] {
        controls.filter { !$0.isEnabled }.compactMap { control in
            let id = control.accessibilityIdentifier()
            guard !id.isEmpty else { return "(unidentified disabled control)" }
            return tickets[id] == nil && !barDependent.contains(id) ? id : nil
        }
    }
}
