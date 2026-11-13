import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

private let issue114Key = "displayPreferences.v1"

@MainActor private func issue114WithDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "mado.issue114.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@MainActor private final class Issue114StoreObserver: DisplayPreferencesObserver {
    var payloads: [DisplayPreferences] = []
    func preferencesDidChange(_ preferences: DisplayPreferences) { payloads.append(preferences) }
}

private func issue114StoredFields(_ defaults: UserDefaults) throws -> [String: Any] {
    let data = try #require(defaults.data(forKey: issue114Key))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114PrefsUserDefaultsRelaunchRoundTrip() throws {
    try issue114WithDefaults { defaults in
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        var a = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true, appearance: .dark,
                                   gridSidebarWidth: 284, gridSidebarVisible: false)
        a.folderSort = .size
        a.folderSortDirection = .descending
        a.loopThroughImages = true
        a.thumbnailSize = 260
        a.showFileNames = false
        a.thumbnailFit = .fit
        store.value = a
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == a)
        var fields = try issue114StoredFields(defaults)
        #expect(fields["thumbnailSize"] as? Double == 260)
        #expect(fields["showFileNames"] as? Bool == false)
        #expect(fields["thumbnailFit"] as? String == "fit")
        #expect(fields["schemaVersion"] as? Int == 1)

        store.value = DisplayPreferences()
        let relaunched = UserDefaultsDisplayPreferencesStore(defaults: defaults).value
        #expect(relaunched == DisplayPreferences())
        #expect(relaunched.thumbnailSize == 220 && relaunched.showFileNames && relaunched.thumbnailFit == .fill)
        fields = try issue114StoredFields(defaults)
        for key in ["thumbnailSize", "showFileNames", "thumbnailFit"] { #expect(fields[key] == nil, "\(key) stored at default") }
        #expect(fields["schemaVersion"] as? Int == 1)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114PrefsUserDefaultsNormalizesOnSetAndNotifiesOncePerChange() throws {
    try issue114WithDefaults { defaults in
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        let observer = Issue114StoreObserver()
        store.observe(observer)
        store.value.thumbnailSize = 173
        #expect(store.value.thumbnailSize == 170)
        let fields = try issue114StoredFields(defaults)
        #expect(fields["thumbnailSize"] as? Double == 170)
        #expect(observer.payloads.count == 1)
        #expect(observer.payloads.last?.thumbnailSize == 170)
        let bytes = defaults.data(forKey: issue114Key)
        for input in [168.0, 170] {
            store.value.thumbnailSize = input
            #expect(store.value.thumbnailSize == 170, "input \(input)")
            #expect(observer.payloads.count == 1, "input \(input)")
            #expect(defaults.data(forKey: issue114Key) == bytes, "input \(input)")
        }
        store.value.thumbnailSize = 176
        #expect(store.value.thumbnailSize == 180)
        #expect(observer.payloads.count == 2)
        #expect(observer.payloads.last == store.value)
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value.thumbnailSize == 180)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue114PrefsUserDefaultsUnsupportedSchemaKeepsBytes() {
    issue114WithDefaults { defaults in
        let data = Data(#"{"schemaVersion":99,"future":"keep"}"#.utf8)
        defaults.set(data, forKey: issue114Key)
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        #expect(store.value.thumbnailSize == 220)
        store.value.thumbnailSize = 260
        #expect(store.value.thumbnailSize == 260)
        store.value.thumbnailSize = 173
        #expect(store.value.thumbnailSize == 170)
        #expect(defaults.data(forKey: issue114Key) == data)
    }
}
