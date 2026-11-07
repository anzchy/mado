import Testing
import MadoApplication

@Test @MainActor func chromeLocksEachReasonAndLastRelease() {
    for reason in ChromeLockReason.allCases {
        let clock = FakeViewerClock()
        let store = InMemoryDisplayPreferencesStore()
        let scheduler = ChromeTestScheduler()
        let session = ViewerSession(preferencesStore: store, clock: clock)
        session.installChromeScheduler(scheduler)
        func set(_ active: Bool) {
            switch reason {
            case .menu: session.setMenuTracking(active)
            case .inspector: session.setInspectorVisible(active)
            case .filmstrip: store.value.filmstripExpanded = active
            case .keyboardFocus: session.updateFocus(active ? .tools : .canvas)
            case .pointerHover, .pointerPress: session.setChromeInteraction(reason, active: active)
            }
        }
        clock.now = 2.5; session.advanceChrome()
        set(true)
        #expect(session.chrome.locks.contains(reason))
        #expect(scheduler.deadline == nil)
        clock.now = 100; session.advanceChrome()
        #expect(!session.chrome.isHidden)
        set(false)
        #expect(session.nextHideDeadline == 102.5)
        #expect(scheduler.deadline == 102.5)
        clock.now = 102.499; scheduler.fire()
        #expect(!session.chrome.isHidden)
        clock.now = 102.5; scheduler.fire()
        #expect(session.chrome.isHidden)
    }
    let clock = FakeViewerClock()
    let session = ViewerSession(clock: clock)
    session.setMenuTracking(true)
    session.setChromeInteraction(.pointerPress, active: true)
    clock.now = 100; session.setMenuTracking(false)
    #expect(session.chrome.visibility == .locked([.pointerPress]))
    clock.now = 105; session.advanceChrome()
    session.setChromeInteraction(.pointerPress, active: false)
    #expect(session.nextHideDeadline == 107.5)
}
