import Foundation
import Testing
import PicseeCore
import PicseeApplication
import PicseeInfrastructure

private let issue351LegacyPreferences = #"{"alwaysShowTools":true,"filmstripExpanded":true,"appearance":"dark","gridSidebarWidth":284,"gridSidebarVisible":false,"folderSort":"size","folderSortDirection":"descending","loopThroughImages":true,"thumbnailSize":170,"showFileNames":false,"thumbnailFit":"fit"}"#

private func issue351Expected(_ opacity: Double = 50) -> DisplayPreferences {
    var value = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true, appearance: .dark,
        gridSidebarWidth: 284, gridSidebarVisible: false)
    value.folderSort = .size; value.folderSortDirection = .descending; value.loopThroughImages = true
    value.thumbnailSize = 170; value.showFileNames = false; value.thumbnailFit = .fit
    value.toolBackgroundOpacity = opacity
    return value
}

@MainActor private final class Issue351Observer: DisplayPreferencesObserver {
    var latest: DisplayPreferences?
    func preferencesDidChange(_ preferences: DisplayPreferences) { latest = preferences }
}

@Test func issue351LegacyAndMalformedOpacityPreserveAllOtherPreferences() throws {
    for schema in ["", #""schemaVersion":1,"#] {
        let legacy = "{" + schema + issue351LegacyPreferences.dropFirst()
        #expect(try JSONDecoder().decode(DisplayPreferences.self, from: Data(legacy.utf8)) == issue351Expected())
        for (raw, expected) in [("null", 50.0), (#""garbage""#, 50), ("true", 50), ("[]", 50),
                                ("{}", 50), ("30", 30), ("50", 50), ("100", 100),
                                ("29", 30), ("101", 100), ("63.5", 63.5)] {
            let payload = legacy.dropLast() + #", "toolBackgroundOpacity":"# + raw + "}"
            #expect(try JSONDecoder().decode(DisplayPreferences.self, from: Data(payload.utf8)) == issue351Expected(expected))
        }
    }
}

@Test func issue351OpacityNormalizationAndCodingAreIdempotent() throws {
    let inputs = (30...100).map(Double.init) + [30.1, 49.5, 99.9, -1000, 0, 29.9, 100.1, 1000,
                                                 .nan, .infinity, -.infinity]
    for input in inputs {
        let expected = input.isFinite ? min(100, max(30, input)) : 50
        let normalized = DisplayPreferences.normalizedToolBackgroundOpacity(input)
        #expect(normalized == expected)
        #expect(DisplayPreferences.normalizedToolBackgroundOpacity(normalized) == normalized)
        let value = issue351Expected(normalized)
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(DisplayPreferences.self, from: data) == value)
        let fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((fields["toolBackgroundOpacity"] == nil) == (normalized == 50))
    }
}

@Test @MainActor func issue351StoresPublishNormalizedValuesAndPersistAcrossRecreation() throws {
    let suite = "picsee.issue351.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data(issue351LegacyPreferences.utf8), forKey: "displayPreferences.v1")
    let persistent = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let memory = InMemoryDisplayPreferencesStore(issue351Expected())
    #expect(persistent.value == issue351Expected())
    #expect(defaults.data(forKey: "displayPreferences.v1") == Data(issue351LegacyPreferences.utf8), "load leaves old bytes intact")
    let first = Issue351Observer(), second = Issue351Observer()
    persistent.observe(first); persistent.observe(second)
    let memoryObserver = Issue351Observer()
    memory.observe(memoryObserver)
    let inputs = [30.0, 63.5, 100, 50] + (30...100).map(Double.init)
        + [-1000, 0, 29.9, 100.1, 1000, .nan, .infinity, -.infinity, 50]
    for input in inputs {
        let opacity = input.isFinite ? min(100, max(30, input)) : 50
        let expected = issue351Expected(opacity)
        persistent.value.toolBackgroundOpacity = input
        memory.value.toolBackgroundOpacity = input
        #expect(persistent.value == expected)
        #expect(memory.value == expected)
        #expect(first.latest == expected && second.latest == expected)
        #expect(memoryObserver.latest == expected)
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == expected)
        persistent.value = persistent.value
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == expected)
    }
    let bytes = try #require(defaults.data(forKey: "displayPreferences.v1"))
    let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(fields["schemaVersion"] as? Int == 1)
    #expect(fields["toolBackgroundOpacity"] == nil)
    for input in [-100.0, 101, Double.nan] {
        var initial = issue351Expected(); initial.toolBackgroundOpacity = input
        #expect(InMemoryDisplayPreferencesStore(initial).value == issue351Expected(input.isFinite ? min(100, max(30, input)) : 50))
    }
}

@Test @MainActor func issue351DefaultLoadingDoesNotWriteAndFutureSchemaRemainsUntouched() throws {
    let suite = "picsee.issue351.load.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let empty = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(empty.value.toolBackgroundOpacity == 50)
    #expect(defaults.object(forKey: "displayPreferences.v1") == nil)
    for versioned in [false, true] {
        let legacy = versioned ? "{\"schemaVersion\":1," + issue351LegacyPreferences.dropFirst() : issue351LegacyPreferences
        let malformed = legacy.dropLast() + #", "toolBackgroundOpacity":"garbage"}"#
        let bytes = Data(malformed.utf8)
        defaults.set(bytes, forKey: "displayPreferences.v1")
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == issue351Expected())
        #expect(defaults.data(forKey: "displayPreferences.v1") == bytes)
    }
    let future = Data(#"{"schemaVersion":999,"toolBackgroundOpacity":30}"#.utf8)
    defaults.set(future, forKey: "displayPreferences.v1")
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(store.value == DisplayPreferences())
    store.value.toolBackgroundOpacity = 100
    #expect(store.value.toolBackgroundOpacity == 100)
    #expect(defaults.data(forKey: "displayPreferences.v1") == future)
}
