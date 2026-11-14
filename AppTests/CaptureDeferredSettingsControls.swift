import AppKit

/// The only disabled Settings controls owned by later Capture tickets.
@MainActor enum CaptureDeferredSettingsControls {
    static let tickets: [String: Int] = [
        "settings.capture.login": 685,
        "settings.capture.folder-change": 684,
        "settings.capture.after-save": 684,
        "settings.capture.after-copy": 684,
        "settings.capture.shortcut-region": 685,
        "settings.capture.shortcut-1": 685,
        "settings.capture.shortcut-2": 685,
        "settings.capture.shortcut-3": 685,
        "settings.capture.shortcut-4": 685,
        "settings.capture.ocr-cloud": 689,
        "settings.capture.ocr-service": 689,
    ]

    static func unexpectedDisabledIDs(_ controls: [NSControl]) -> [String] {
        controls.filter { !$0.isEnabled }.compactMap { control in
            let id = control.accessibilityIdentifier()
            guard !id.isEmpty else { return "(unidentified disabled control)" }
            return tickets[id] == nil ? id : nil
        }
    }
}
