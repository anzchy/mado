import Foundation
import PicseeApplication

@MainActor public final class UserDefaultsDisplayPreferencesStore: DisplayPreferencesStore {
    private static let key = "displayPreferences.v1"
    private static let logURL = URL(fileURLWithPath: "/UserDefaults/displayPreferences.v1")
    private struct Header: Decodable { let schemaVersion: Int? }
    private struct Envelope: Codable {
        let schemaVersion: Int
        let value: DisplayPreferences
    }
    private let defaults: UserDefaults
    private struct WeakObserver { weak var value: (any DisplayPreferencesObserver)? }
    private var observers: [WeakObserver] = []
    private var storedValue: DisplayPreferences

    public var value: DisplayPreferences {
        get { storedValue }
        set {
            var normalized = newValue
            normalized.gridSidebarWidth = DisplayPreferences.normalizedSidebarWidth(normalized.gridSidebarWidth)
            normalized.thumbnailSize = DisplayPreferences.normalizedThumbnailSize(normalized.thumbnailSize)
            normalized.toolBackgroundOpacity = DisplayPreferences.normalizedToolBackgroundOpacity(normalized.toolBackgroundOpacity)
            guard normalized != storedValue else { return }
            storedValue = normalized
            if let existing = defaults.data(forKey: Self.key), let version = Self.unsupportedVersion(existing) {
                StoredSchema.logUnsupportedOnce(at: Self.logURL, category: "preferences", store: "display-preferences", version: version)
            } else {
                if let data = try? Self.encode(normalized) {
                    defaults.set(data, forKey: Self.key)
                }
            }
            observers.removeAll { $0.value == nil }
            for observer in observers { observer.value?.preferencesDidChange(normalized) }
        }
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let version = Self.unsupportedVersion(data) {
            StoredSchema.logUnsupportedOnce(at: Self.logURL, category: "preferences", store: "display-preferences", version: version)
            storedValue = DisplayPreferences()
        } else {
            storedValue = defaults.data(forKey: Self.key).flatMap { data in
                let decoder = JSONDecoder()
                if let header = try? decoder.decode(Header.self, from: data), header.schemaVersion == StoredSchema.current {
                    if let envelope = try? decoder.decode(Envelope.self, from: data) { return envelope.value }
                }
                return try? decoder.decode(DisplayPreferences.self, from: data)
            } ?? DisplayPreferences()
        }
    }

    private static func unsupportedVersion(_ data: Data) -> Int? {
        guard let header = try? JSONDecoder().decode(Header.self, from: data),
              let version = header.schemaVersion, version != StoredSchema.current else { return nil }
        return version
    }

    private static func encode(_ value: DisplayPreferences) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(value)
        // DisplayPreferences encodes as a keyed object.
        var fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        fields["schemaVersion"] = StoredSchema.current
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    public func observe(_ observer: any DisplayPreferencesObserver) {
        observers.append(WeakObserver(value: observer))
    }
}
