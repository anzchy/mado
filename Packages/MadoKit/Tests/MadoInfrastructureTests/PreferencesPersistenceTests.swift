import Foundation
import Testing
import MadoApplication
import MadoInfrastructure

@MainActor private final class PersistenceObserver: DisplayPreferencesObserver {
    let defaults: UserDefaults
    var values: [DisplayPreferences] = []
    var persisted: [Data?] = []
    init(_ defaults: UserDefaults) { self.defaults = defaults }
    func preferencesDidChange(_ preferences: DisplayPreferences) {
        values.append(preferences)
        persisted.append(defaults.data(forKey: "displayPreferences.v1"))
    }
}

@MainActor private func withPreferencesDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "mado.preferences.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

@Test(.timeLimit(.minutes(2))) @MainActor func preferencesPersistenceRelaunchAndCommittedObserverValues() {
    withPreferencesDefaults { defaults in
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        let first = PersistenceObserver(defaults)
        let second = PersistenceObserver(defaults)
        store.observe(first)
        store.observe(second)
        let dark = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: false, appearance: .dark)
        let light = DisplayPreferences(alwaysShowTools: false, filmstripExpanded: true, appearance: .light)
        let darkJSON = Data(#"{"alwaysShowTools":true,"appearance":"dark","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196,"schemaVersion":1}"#.utf8)
        let lightJSON = Data(#"{"alwaysShowTools":false,"appearance":"light","filmstripExpanded":true,"gridSidebarVisible":true,"gridSidebarWidth":196,"schemaVersion":1}"#.utf8)
        store.value = dark
        #expect(store.value == dark)
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == dark)
        #expect(defaults.data(forKey: "displayPreferences.v1") == darkJSON)
        store.value = light
        #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == light)
        #expect(defaults.data(forKey: "displayPreferences.v1") == lightJSON)
        #expect(first.values == [dark, light])
        #expect(second.values == [dark, light])
        #expect(first.persisted == [darkJSON, lightJSON])
        #expect(second.persisted == [darkJSON, lightJSON])
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func preferencesPersistenceEqualValueDoesNotWriteOrNotify() {
    withPreferencesDefaults { defaults in
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        let observer = PersistenceObserver(defaults)
        store.observe(observer)
        let sentinel = Data("untouched sentinel".utf8)
        defaults.set(sentinel, forKey: "displayPreferences.v1")
        store.value = DisplayPreferences()
        store.value = DisplayPreferences()
        #expect(defaults.data(forKey: "displayPreferences.v1") == sentinel)
        #expect(observer.values.isEmpty)
        store.value = DisplayPreferences(appearance: .dark)
        #expect(observer.values == [DisplayPreferences(appearance: .dark)])
        #expect(defaults.data(forKey: "displayPreferences.v1") ==
            Data(#"{"alwaysShowTools":false,"appearance":"dark","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196,"schemaVersion":1}"#.utf8))
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func preferencesPersistenceMissingCorruptAndWrongTypeRecover() {
    let invalid: [Any?] = [nil, Data([0xff, 0xfe]), "not encoded data",
        Data(#"{"alwaysShowTools":true,"appearance":7,"filmstripExpanded":false}"#.utf8)]
    for input in invalid {
        withPreferencesDefaults { defaults in
            if let input { defaults.set(input, forKey: "displayPreferences.v1") }
            let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
            #expect(store.value == DisplayPreferences())
            let changed = DisplayPreferences(alwaysShowTools: true, filmstripExpanded: false, appearance: .dark)
            store.value = changed
            #expect(UserDefaultsDisplayPreferencesStore(defaults: defaults).value == changed)
            #expect(defaults.data(forKey: "displayPreferences.v1") ==
                Data(#"{"alwaysShowTools":true,"appearance":"dark","filmstripExpanded":false,"gridSidebarVisible":true,"gridSidebarWidth":196,"schemaVersion":1}"#.utf8))
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func preferencesPersistenceLegacyAndUnknownRestore() {
    for literal in [#"{"alwaysShowTools":true,"filmstripExpanded":false}"#,
                    #"{"alwaysShowTools":true,"appearance":"sepia","filmstripExpanded":false,"future":42}"#] {
        withPreferencesDefaults { defaults in
            defaults.set(Data(literal.utf8), forKey: "displayPreferences.v1")
            let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
            #expect(store.value == DisplayPreferences(alwaysShowTools: true, filmstripExpanded: false, appearance: .system))
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue124SortSurvivesUserDefaultsStoreRecreation() {
    withPreferencesDefaults { defaults in
        let first = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        var changed = first.value
        changed.folderSort = .pixelDimensions
        changed.folderSortDirection = .descending
        first.value = changed
        let relaunched = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        #expect(relaunched.value.folderSort == .pixelDimensions)
        #expect(relaunched.value.folderSortDirection == .descending)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func preferencesPersistenceWeakObserverAndSurvivingObserver() {
    withPreferencesDefaults { defaults in
        let store = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        let surviving = PersistenceObserver(defaults)
        store.observe(surviving)
        var temporary: PersistenceObserver? = PersistenceObserver(defaults)
        weak var weakObserver = temporary
        store.observe(temporary!)
        temporary = nil
        #expect(weakObserver == nil)
        store.value = DisplayPreferences(appearance: .light)
        #expect(surviving.values == [DisplayPreferences(appearance: .light)])
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func preferencesPersistenceReloadedSessionsStartPinnedAndSynchronize() {
    withPreferencesDefaults { defaults in
        let initial = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        initial.value = DisplayPreferences(alwaysShowTools: true, appearance: .light)
        let restored = UserDefaultsDisplayPreferencesStore(defaults: defaults)
        let first = ViewerSession(preferencesStore: restored)
        let second = ViewerSession(preferencesStore: restored)
        #expect(first.chrome.isPinned)
        #expect(second.chrome.isPinned)
        #expect(first.nextHideDeadline == nil)
        #expect(second.nextHideDeadline == nil)
        #expect(first.displayPreferences.appearance == .light)
        #expect(second.displayPreferences.appearance == .light)
        restored.value.alwaysShowTools = false
        #expect(!first.chrome.isPinned)
        #expect(!second.chrome.isPinned)
        #expect(first.nextHideDeadline != nil)
        #expect(second.nextHideDeadline != nil)
        restored.value.filmstripExpanded = true
        #expect(first.chrome.locks == [.filmstrip])
        #expect(second.chrome.locks == [.filmstrip])
        restored.value.filmstripExpanded = false
        #expect(first.chrome.locks.isEmpty)
        #expect(second.chrome.locks.isEmpty)
        restored.value.alwaysShowTools = true
        #expect(first.chrome.isPinned)
        #expect(second.chrome.isPinned)
    }
}
