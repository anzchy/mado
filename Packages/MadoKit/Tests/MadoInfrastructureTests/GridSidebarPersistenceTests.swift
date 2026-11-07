import Foundation
import Testing
import MadoApplication
@testable import MadoInfrastructure

@Test @MainActor func gridSidebarPreferenceSurvivesRelaunchAndLegacyPayload() throws {
    let suite = "grid-sidebar-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(first.value.gridSidebarWidth == 196)
    #expect(first.value.gridSidebarVisible)

    var changed = first.value
    changed.gridSidebarWidth = 284
    changed.gridSidebarVisible = false
    first.value = changed
    let reopened = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(reopened.value.gridSidebarWidth == 284)
    #expect(!reopened.value.gridSidebarVisible)
    changed.gridSidebarVisible = true
    reopened.value = changed
    #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value.gridSidebarWidth == 284)

    defaults.set(Data(#"{"alwaysShowTools":false,"filmstripExpanded":false,"appearance":"system"}"#.utf8),
                 forKey: "displayPreferences.v1")
    let legacy = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    #expect(legacy.value.gridSidebarWidth == 196)
    #expect(legacy.value.gridSidebarVisible)
}

@Test @MainActor func gridSidebarPreferenceNormalizesBadFieldsWithoutLosingOtherPreferences() throws {
    let suite = "grid-sidebar-bad-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    for (raw, expected) in [("-1000", 160.0), ("9999", 320.0), ("\"bad\"", 196.0)] {
        defaults.set(Data("{\"alwaysShowTools\":true,\"filmstripExpanded\":true,\"appearance\":\"dark\",\"gridSidebarVisible\":\"bad\",\"gridSidebarWidth\":\(raw)}".utf8),
                     forKey: "displayPreferences.v1")
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        #expect(store.value.gridSidebarWidth == expected)
        #expect(store.value.gridSidebarVisible)
        #expect(store.value.alwaysShowTools)
        #expect(store.value.filmstripExpanded)
        #expect(store.value.appearance == .dark)
    }
    #expect(DisplayPreferences(gridSidebarWidth: .nan).gridSidebarWidth == 196)
    let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    store.value.gridSidebarWidth = .nan
    #expect(store.value.gridSidebarWidth == 196)
    #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value.gridSidebarWidth == 196)
}
