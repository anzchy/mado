import Foundation
import Testing
import MadoApplication

@MainActor final class FakeViewerClock: ViewerClock {
    var now: TimeInterval = 0
}

@Test(.timeLimit(.minutes(2))) @MainActor func chromeClockBoundariesActivityAndLocks() {
    let clock = FakeViewerClock()
    var chrome = ViewerChromeState(now: clock.now)
    #expect(chrome.hideDelay == 2.5)
    #expect(chrome.visibility == .visible)
    #expect(chrome.nextHideDeadline == 2.5)
    clock.now = 2.499
    chrome.advance(to: clock.now)
    #expect(chrome.visibility == .visible)
    clock.now = 2.5
    chrome.advance(to: clock.now)
    #expect(chrome.visibility == .hidden)
    #expect(chrome.nextHideDeadline == nil)
    chrome.activity(at: 3)
    #expect(chrome.visibility == .visible)
    chrome.activity(at: 5)
    chrome.advance(to: 5.5)
    #expect(chrome.visibility == .visible)
    #expect(chrome.nextHideDeadline == 7.5)
    chrome.advance(to: 7.5)
    #expect(chrome.visibility == .hidden)
    for reason in ChromeLockReason.allCases {
        chrome.setLock(reason, active: true, at: 10)
        #expect(chrome.visibility == .locked([reason]))
        #expect(chrome.nextHideDeadline == nil)
        chrome.advance(to: 100)
        #expect(chrome.visibility == .locked([reason]))
        chrome.setLock(reason, active: false, at: 100)
        #expect(chrome.visibility == .visible)
        #expect(chrome.nextHideDeadline == 102.5)
        chrome.advance(to: 102.499)
        #expect(chrome.visibility == .visible)
        chrome.advance(to: 102.5)
        #expect(chrome.visibility == .hidden)
    }
    chrome.setLock(.menu, active: true, at: 110)
    chrome.setLock(.inspector, active: true, at: 110)
    chrome.setLock(.menu, active: false, at: 111)
    #expect(chrome.visibility == .locked([.inspector]))
    chrome.setLock(.inspector, active: false, at: 112)
    chrome.setLock(.inspector, active: false, at: 113)
    #expect(chrome.nextHideDeadline == 114.5)
    chrome.setPinned(true, at: 120)
    #expect(chrome.visibility == .pinned)
    #expect(chrome.nextHideDeadline == nil)
    chrome.advance(to: 999)
    #expect(chrome.visibility == .pinned)
    chrome.setLock(.menu, active: true, at: 999)
    #expect(chrome.visibility == .locked([.menu]))
    chrome.setLock(.menu, active: false, at: 1000)
    #expect(chrome.visibility == .pinned)
    chrome.setPinned(false, at: 1001)
    #expect(chrome.nextHideDeadline == 1003.5)
    chrome.setPinned(false, at: 1002)
    #expect(chrome.nextHideDeadline == 1003.5)
    chrome.advance(to: 1003.5)
    #expect(chrome.visibility == .hidden)
    var custom = ViewerChromeState(now: 4, hideDelay: 1)
    custom.advance(to: 5)
    #expect(custom.visibility == .hidden)
    #expect(MonotonicViewerClock().now > 0)
}
