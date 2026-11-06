import Foundation
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure

@MainActor private final class Issue349PreferenceObserver: DisplayPreferencesObserver {
    var latest: DisplayPreferences?
    func preferencesDidChange(_ preferences: DisplayPreferences) { latest = preferences }
}

@Test @MainActor func issue349LegacyPreferencesAndStoredSizesSurviveRelaunch() throws {
    // Literal payloads from pre-114 and #114's flat schema-1 encoding, not re-encoded by the new model.
    let old = #"{"alwaysShowTools":true,"filmstripExpanded":true,"appearance":"dark","gridSidebarWidth":284,"gridSidebarVisible":false,"folderSort":"size","folderSortDirection":"descending","loopThroughImages":true}"#
    let versioned = #"{"schemaVersion":1,"alwaysShowTools":true,"filmstripExpanded":true,"appearance":"dark","gridSidebarWidth":284,"gridSidebarVisible":false,"folderSort":"size","folderSortDirection":"descending","loopThroughImages":true}"#
    let saved = #"{"schemaVersion":1,"alwaysShowTools":true,"filmstripExpanded":true,"appearance":"dark","gridSidebarWidth":284,"gridSidebarVisible":false,"folderSort":"size","folderSortDirection":"descending","loopThroughImages":true,"thumbnailSize":170,"showFileNames":false,"thumbnailFit":"fit"}"#
    for (payload, size) in [(old, 220.0), (versioned, 220), (saved, 170),
                            (saved.replacingOccurrences(of: "170", with: "260"), 260)] {
        let suite = "picsee.issue349.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(payload.utf8), forKey: "displayPreferences.v1")
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        var expected = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true, appearance: .dark,
            gridSidebarWidth: 284, gridSidebarVisible: false)
        expected.folderSort = .size; expected.folderSortDirection = .descending; expected.loopThroughImages = true
        expected.thumbnailSize = size
        if size != 220 { expected.showFileNames = false; expected.thumbnailFit = .fit }
        #expect(store.value == expected)
        let first = Issue349PreferenceObserver(), second = Issue349PreferenceObserver()
        store.observe(first); store.observe(second)
        for next in stride(from: 140.0, through: 280, by: 10) {
            expected.thumbnailSize = next
            store.value.thumbnailSize = next
            #expect(store.value == expected)
            #expect(first.latest == expected)
            #expect(second.latest == expected)
            #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == expected)
        }
        expected.thumbnailSize = 220
        store.value.thumbnailSize = 220
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == expected)
        let bytes = try #require(defaults.data(forKey: "displayPreferences.v1"))
        let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(fields["schemaVersion"] as? Int == 1)
        #expect(fields["thumbnailSize"] == nil, "220 retains existing default omission")
    }
}
