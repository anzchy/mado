import Testing
import MadoApplication

@Test @MainActor func chromeWindowAlwaysShowPinsAllWindowsAndUnpinRetimes() {
    let clock = FakeViewerClock()
    let store = InMemoryDisplayPreferencesStore()
    let first = ViewerSession(preferencesStore: store, clock: clock)
    let second = ViewerSession(preferencesStore: store, clock: clock)
    let firstTimer = ChromeTestScheduler(), secondTimer = ChromeTestScheduler()
    first.installChromeScheduler(firstTimer); second.installChromeScheduler(secondTimer)
    clock.now = 2.5; firstTimer.fire(); secondTimer.fire()
    #expect(first.chrome.isHidden && second.chrome.isHidden)
    first.activity()
    #expect(!first.chrome.isHidden && second.chrome.isHidden)
    store.value.alwaysShowTools = true
    #expect(first.chrome.visibility == .pinned)
    #expect(second.chrome.visibility == .pinned)
    #expect(firstTimer.deadline == nil && secondTimer.deadline == nil)
    clock.now = 100; first.advanceChrome(); second.advanceChrome()
    #expect(first.chrome.visibility == .pinned && second.chrome.visibility == .pinned)
    store.value.alwaysShowTools = false
    #expect(firstTimer.deadline == 102.5 && secondTimer.deadline == 102.5)
    clock.now = 102.5; firstTimer.fire(); secondTimer.fire()
    #expect(first.chrome.isHidden && second.chrome.isHidden)
    let adjustable = ViewerSession(clock: clock, hideDelay: 1)
    #expect(adjustable.nextHideDeadline == 103.5)
}
