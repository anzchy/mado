import Testing
import MadoApplication

@MainActor final class ChromeTestScheduler: ViewerChromeScheduling {
    var deadline: Double?
    var action: (@MainActor () -> Void)?
    var replacements: [Double?] = []
    func replace(deadline: Double?, action: @escaping @MainActor () -> Void) {
        self.deadline = deadline
        self.action = deadline == nil ? nil : action
        replacements.append(deadline)
    }
    func fire() {
        let callback = action
        deadline = nil
        action = nil
        callback?()
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeSchedulerBoundariesAndRearming() {
    let clock = FakeViewerClock()
    let scheduler = ChromeTestScheduler()
    let session = ViewerSession(clock: clock)
    session.installChromeScheduler(scheduler)
    #expect(scheduler.deadline == 2.5)
    clock.now = 2.499
    scheduler.fire()
    #expect(session.chrome.visibility == .visible)
    #expect(scheduler.deadline == 2.5)
    clock.now = 2.5
    scheduler.fire()
    #expect(session.chrome.visibility == .hidden)
    #expect(scheduler.deadline == nil)
    clock.now = 0
    session.activity()
    clock.now = 2
    session.activity()
    #expect(scheduler.deadline == 4.5)
    session.setMenuTracking(true)
    #expect(scheduler.deadline == nil)
    clock.now = 9
    session.advanceChrome()
    #expect(session.chrome.visibility == .locked([.menu]))
    session.setMenuTracking(false)
    #expect(scheduler.deadline == 11.5)
    clock.now = 11.5
    scheduler.fire()
    #expect(session.chrome.visibility == .hidden)
    #expect(scheduler.action == nil)
    #expect(scheduler.replacements == [2.5, 2.5, nil, 2.5, 4.5, nil, 11.5, nil])
}
