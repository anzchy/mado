import Foundation
import Observation
import Testing
import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func sessionSearchIsTransientPreferencesSharedAndRestored() throws {
    let store = InMemoryDisplayPreferencesStore()
    let first = ViewerSession(preferencesStore: store)
    let second = ViewerSession(preferencesStore: store)
    #expect(first.displayPreferences == DisplayPreferences())
    first.searchTerm = "sunset"
    #expect(second.searchTerm.isEmpty)
    store.value = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: true)
    #expect(first.displayPreferences.alwaysShowTools)
    #expect(second.displayPreferences.filmstripExpanded)
    let data = try JSONEncoder().encode(store.value)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["alwaysShowTools"] as? Bool == true)
    #expect(object["filmstripExpanded"] as? Bool == true)
    #expect(object["appearance"] as? String == "system")
    #expect(!String(decoding: data, as: UTF8.self).contains("sunset"))
    #expect(!String(decoding: data, as: UTF8.self).contains("search"))
    let relaunchedStore = InMemoryDisplayPreferencesStore(try JSONDecoder().decode(DisplayPreferences.self, from: data))
    let relaunched = ViewerSession(preferencesStore: relaunchedStore)
    #expect(relaunched.searchTerm.isEmpty)
    #expect(relaunched.displayPreferences == first.displayPreferences)
    store.value.alwaysShowTools = false
    #expect(!first.displayPreferences.alwaysShowTools)
    #expect(!second.displayPreferences.alwaysShowTools)
    #expect(relaunched.displayPreferences.alwaysShowTools)
}
