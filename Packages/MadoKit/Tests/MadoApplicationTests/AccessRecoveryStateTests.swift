import Foundation
import Testing
import MadoCore
import MadoApplication

private enum T229RecoveryAdmissionError: Error, Equatable { case obsoleteGrant }

@MainActor @Test func t229RecoveryStateCommitsInsideFenceAndAnnouncesOutside() throws {
    let state = AccessState(), id = AccessRootID(), lock = NSLock()
    state.register(id, volumeUUID: "111")
    let old = try #require(state.permit(for: id))
    state.diskUnmounted(volumeUUID: "111")
    let attempt = try #require(state.diskMounted(volumeUUID: "111").first)
    var inside = false, callbackOutside = false, callbackCouldLock = false
    var events: [AccessStateChange] = []
    _ = state.observe { event in
        callbackOutside = !inside
        callbackCouldLock = lock.try()
        if callbackCouldLock { lock.unlock() }
        events.append(event)
    }
    let recovered = state.completeRecovery(attempt, verified: true, admitting: { update in
        lock.lock(); inside = true
        update()
        #expect(state.snapshot(for: id)?.availability == .readable)
        #expect(state.snapshot(for: id)?.counter == 1)
        inside = false; lock.unlock()
    })
    #expect(recovered && callbackOutside && callbackCouldLock)
    #expect(events == [.recovered(id, counter: 1)])
    #expect(!old.isCurrent)
    #expect(state.permit(for: id)?.isCurrent == true)
    #expect(!state.completeRecovery(attempt, verified: true))
    #expect(events.count == 1)
}

@MainActor @Test func t229RecoveryStateRejectedFenceAndSecondEjectNeverBecomeReadable() throws {
    let state = AccessState(), id = AccessRootID()
    state.register(id, volumeUUID: "111")
    state.diskUnmounted(volumeUUID: "111")
    let attempt = try #require(state.diskMounted(volumeUUID: "111").first)
    let before = state.snapshot(for: id)
    var events: [AccessStateChange] = []
    _ = state.observe { events.append($0) }
    #expect(throws: T229RecoveryAdmissionError.obsoleteGrant) {
        try state.completeRecovery(attempt, verified: true, admitting: { _ in throw T229RecoveryAdmissionError.obsoleteGrant })
    }
    #expect(state.snapshot(for: id) == before && events.isEmpty)
    #expect(state.permit(for: id) == nil)
    state.diskUnmounted(volumeUUID: "111")
    let afterSecondEject = state.snapshot(for: id)
    let staleCompletion = state.completeRecovery(attempt, verified: true, admitting: { $0() })
    #expect(!staleCompletion)
    #expect(state.snapshot(for: id) == afterSecondEject)
    #expect(events == [.lost(id, counter: 2)])
    #expect(state.permit(for: id) == nil)
}

@MainActor @Test func t229RecoveryFailureRefinesCauseWithoutAnotherEpisodeOrPermit() throws {
    let state = AccessState(), a = AccessRootID(), b = AccessRootID()
    state.register(a, volumeUUID: "111"); state.register(b, volumeUUID: "111")
    let oldStamp = state.stamp(for: a)
    state.diskUnmounted(volumeUUID: "111")
    let attempt = try #require(state.diskMounted(volumeUUID: "111").first { $0.rootID == a })
    let unaffected = state.snapshot(for: b)
    var events: [AccessStateChange] = []
    _ = state.observe { events.append($0) }
    #expect(state.refineRecoveryFailure(attempt, cause: .unknown))
    #expect(state.snapshot(for: a)?.availability == .lost(.unknown))
    #expect(state.snapshot(for: a)?.counter == 1)
    #expect(state.snapshot(for: b) == unaffected)
    #expect(!state.mayDeliver(oldStamp))
    #expect(!state.mayDeliver(state.stamp(for: a)))
    #expect(state.permit(for: a) == nil)
    #expect(state.recoveryAttempt(for: a) == attempt)
    #expect(!state.refineRecoveryFailure(attempt, cause: .unknown))
    #expect(!state.completeRecovery(attempt, verified: false))
    #expect(events == [.lost(a, counter: 1)])
    let completed = state.completeRecovery(attempt, verified: true, admitting: { $0() })
    #expect(completed)
    #expect(events == [.lost(a, counter: 1), .recovered(a, counter: 1)])
}

@MainActor @Test func t229RecoveryFailureRejectsDisconnectedStaleWrongAndReadableAttempts() throws {
    let state = AccessState(), id = AccessRootID()
    state.register(id, volumeUUID: "111")
    state.diskUnmounted(volumeUUID: "111")
    let disconnected = AccessRecoveryAttempt(rootID: id, counter: 1, volumeUUID: "111")
    #expect(!state.refineRecoveryFailure(disconnected, cause: .unknown))
    let attempt = try #require(state.diskMounted(volumeUUID: "111").first)
    #expect(!state.refineRecoveryFailure(.init(rootID: id, counter: 1, volumeUUID: "other"), cause: .unknown))
    state.diskUnmounted(volumeUUID: "111")
    #expect(!state.refineRecoveryFailure(attempt, cause: .unknown))
    let latest = try #require(state.diskMounted(volumeUUID: "111").first)
    #expect(state.completeRecovery(latest, verified: true))
    #expect(!state.refineRecoveryFailure(latest, cause: .unknown))
    #expect(state.snapshot(for: id)?.availability == .readable)
    state.forget(id)
    #expect(!state.refineRecoveryFailure(latest, cause: .unknown))
}

@MainActor @Test func t229RecoveryRefinementSequencesPreserveCounterAndRevokedWork() throws {
    for mask in 0..<16 {
        let state = AccessState(), id = AccessRootID(), unaffected = AccessRootID()
        state.register(id, volumeUUID: "111"); state.register(unaffected, volumeUUID: "222")
        let oldPermit = try #require(state.permit(for: id))
        state.diskUnmounted(volumeUUID: "111")
        var events: [AccessStateChange] = []
        _ = state.observe { events.append($0) }
        for bit in 0..<4 {
            _ = state.diskMounted(volumeUUID: "111")
            let attempt = try #require(state.recoveryAttempt(for: id))
            let cause: AccessLossCause = mask & (1 << bit) == 0 ? .unknown : .diskNotConnected
            let before = state.snapshot(for: id)
            let changed = state.refineRecoveryFailure(attempt, cause: cause)
            #expect(changed == (before?.availability != .lost(cause)))
            #expect(state.snapshot(for: id)?.counter == 1)
            #expect(state.snapshot(for: id)?.availability == .lost(cause))
            #expect(state.permit(for: id) == nil && !oldPermit.isCurrent)
            #expect(state.snapshot(for: unaffected)?.availability == .readable)
            #expect(state.snapshot(for: unaffected)?.counter == 0)
            #expect(!state.refineRecoveryFailure(attempt, cause: cause))
            if cause == .diskNotConnected { #expect(state.recoveryAttempt(for: id) == nil) }
        }
        #expect(events.allSatisfy { if case .lost(_, let counter) = $0 { counter == 1 } else { false } })
    }
}

@MainActor @Test func issue358MixedVolumesRejectUnrelatedUnmountAndRemount() {
    let state = AccessState()
    let first = AccessRootID(), second = AccessRootID(), other = AccessRootID()
    state.register(first, volumeUUID: "111")
    state.register(second, volumeUUID: "111")
    state.register(other, volumeUUID: "222")
    var events: [AccessStateChange] = []
    _ = state.observe { events.append($0) }

    state.diskUnmounted(volumeUUID: "111")
    #expect(state.snapshot(for: first)?.availability == .lost(.diskNotConnected))
    #expect(state.snapshot(for: second)?.availability == .lost(.diskNotConnected))
    #expect(state.snapshot(for: other)?.availability == .readable)
    #expect(state.snapshot(for: other)?.counter == 0)
    #expect(events.count == 2)
    state.diskUnmounted(volumeUUID: "111")
    #expect(events.count == 2, "already-unmounted entries must be rejected")

    let attempts = state.diskMounted(volumeUUID: "111")
    #expect(Set(attempts.map(\.rootID)) == [first, second])
    #expect(state.snapshot(for: other)?.availability == .readable)
    #expect(state.diskMounted(volumeUUID: "111").isEmpty, "already-mounted entries must be rejected")
    #expect(state.diskMounted(volumeUUID: "222").isEmpty, "the other volume is mounted already")
}
