import Foundation
import Testing
import PicseeApplication
import PicseeInfrastructure

private func issue344NondefaultPreferences(loop: Bool) -> DisplayPreferences {
    var value = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true, appearance: .dark,
                                   gridSidebarWidth: 284, gridSidebarVisible: false)
    value.folderSort = .size
    value.folderSortDirection = .descending
    value.loopThroughImages = loop
    return value
}

@MainActor private func issue344WithDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "picsee.issue344.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Test @MainActor func issue344LegacyLoopPreferencePreservesOtherValues() throws {
    #expect(!DisplayPreferences().loopThroughImages)
    let fields: [String: Any] = ["alwaysShowTools": true, "filmstripExpanded": true, "appearance": "dark",
        "gridSidebarWidth": 284, "gridSidebarVisible": false, "folderSort": "size", "folderSortDirection": "descending"]
    for version in [nil, 1] as [Int?] {
        var object = fields
        if let version { object["schemaVersion"] = version }
        let data = try JSONSerialization.data(withJSONObject: object)
        let expected = issue344NondefaultPreferences(loop: false)
        #expect(try JSONDecoder().decode(DisplayPreferences.self, from: data) == expected)
        try issue344WithDefaults { defaults in
            defaults.set(data, forKey: "displayPreferences.v1")
            #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == expected)
        }
    }
}

@Test(arguments: [false, true]) @MainActor
func issue344LoopPreferenceRoundTripAndPrefilledSession(loop: Bool) throws {
    let expected = issue344NondefaultPreferences(loop: loop)
    let data = try JSONEncoder().encode(expected)
    let decoded = try JSONDecoder().decode(DisplayPreferences.self, from: data)
    #expect(decoded == expected)
    let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect((fields["loopThroughImages"] as? Bool ?? false) == loop)
    let session = ViewerSession(preferencesStore: InMemoryDisplayPreferencesStore(decoded))
    #expect(session.displayPreferences == expected)
}

@Test @MainActor func issue344LoopPreferenceRealDefaultsRelaunch() throws {
    try issue344WithDefaults { defaults in
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        #expect(!store.value.loopThroughImages)
        for loop in [true, false] {
            let expected = issue344NondefaultPreferences(loop: loop)
            store.value = expected
            let relaunched = UserDefaultsDisplayPreferencesStore(defaults: defaults)
            #expect(relaunched.value == expected)
            let data = try #require(defaults.data(forKey: "displayPreferences.v1"))
            let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(fields["schemaVersion"] as? Int == 1)
            #expect((fields["loopThroughImages"] as? Bool ?? false) == loop)
        }
    }
}

@Test(arguments: [0, 99]) @MainActor
func issue344LoopPreferenceProtectsUnsupportedSchema(version: Int) throws {
    issue344WithDefaults { defaults in
        let data = Data("{\"schemaVersion\":\(version),\"future\":\"keep these exact bytes\"}".utf8)
        defaults.set(data, forKey: "displayPreferences.v1")
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        #expect(!store.value.loopThroughImages)
        store.value.loopThroughImages = true
        #expect(store.value.loopThroughImages)
        #expect(defaults.data(forKey: "displayPreferences.v1") == data)
    }
}
