import AppKit
import MadoApplication

@MainActor public final class WindowAppearanceAdapter: NSObject, DisplayPreferencesObserver {
    private struct WeakWindow { weak var value: NSWindow? }
    private var windows: [WeakWindow] = []
    private let preferencesStore: any DisplayPreferencesStore

    public init(preferencesStore: any DisplayPreferencesStore) {
        self.preferencesStore = preferencesStore
        super.init()
        preferencesStore.observe(self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil)
    }

    /// Register again before showing a previously closed window.
    public func register(_ window: NSWindow) {
        windows.removeAll { $0.value == nil || $0.value === window }
        windows.append(WeakWindow(value: window))
        DesignAppearance(preferencesStore.value.appearance).apply(to: window)
    }

    public func preferencesDidChange(_ preferences: DisplayPreferences) {
        for registration in windows {
            if let window = registration.value { DesignAppearance(preferences.appearance).apply(to: window) }
        }
    }

    @objc private func windowWillClose(_ notification: Notification) {
        windows.removeAll { $0.value == nil || $0.value === (notification.object as? NSWindow) }
    }
}
