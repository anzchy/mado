import Foundation
import Testing
import MadoCore
import MadoApplication

@MainActor @Test(.timeLimit(.minutes(2))) func t229AccessStateMatchesUnmountByUUIDAndNotifiesEveryObserverOnce() {
    let access = AccessState()
    let a = AccessRootID(), b = AccessRootID()
    access.register(a, volumeUUID: "111")
    access.register(b, volumeUUID: "222")
    var left: [AccessStateChange] = []
    var right: [AccessStateChange] = []
    let leftID = access.observe { left.append($0) }
    let rightID = access.observe { right.append($0) }
    let aBefore = access.stamp(for: a)
    let bBefore = access.stamp(for: b)

    access.diskUnmounted(volumeUUID: "111")
    #expect(access.snapshot(for: a) == AccessRootSnapshot(volumeUUID: "111", counter: 1, availability: .lost(.diskNotConnected)))
    #expect(access.snapshot(for: b) == AccessRootSnapshot(volumeUUID: "222", counter: 0, availability: .readable))
    #expect(left == [.lost(a, counter: 1)])
    #expect(right == left)
    #expect(!access.mayDeliver(aBefore))
    #expect(access.mayDeliver(bBefore))

    access.diskUnmounted(volumeUUID: "111")
    #expect(left.count == 1)
    #expect(access.diskMounted(volumeUUID: "333").isEmpty)
    #expect(left.count == 1)
    access.removeObserver(leftID)
    access.removeObserver(rightID)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229AccessStateGeneratedTracesPreserveCountersAndRejectOldStamps() {
    // All 5^4 traces, with an oracle independent of AccessState's storage.
    enum Event: Int, CaseIterable { case unmountA, mountA, verifyA, failA, unmountB }
    let alphabet = Event.allCases
    for code in 0..<(alphabet.count * alphabet.count * alphabet.count * alphabet.count) {
        var digits = code
        let trace = (0..<4).map { _ -> Event in
            defer { digits /= alphabet.count }
            return alphabet[digits % alphabet.count]
        }
        let access = AccessState()
        let a = AccessRootID(), b = AccessRootID()
        access.register(a, volumeUUID: "111")
        access.register(b, volumeUUID: "222")
        let oldA = access.stamp(for: a), oldB = access.stamp(for: b)
        var aMounted = true, bMounted = true
        var aLost = false, bLost = false
        var aCause: AccessLossCause = .diskNotConnected
        var aCounter: UInt64 = 0, bCounter: UInt64 = 0
        var pending: AccessRecoveryAttempt?
        var transitions = 0
        var expectedTransitions = 0
        let observer = access.observe { _ in transitions += 1 }
        for event in trace {
            switch event {
            case .unmountA:
                if aMounted {
                    aMounted = false; aLost = true; aCause = .diskNotConnected
                    aCounter += 1; expectedTransitions += 1
                }
                access.diskUnmounted(volumeUUID: "111")
            case .mountA:
                let wasMounted = aMounted
                aMounted = true
                let candidates = access.diskMounted(volumeUUID: "111")
                if !wasMounted { pending = candidates.first }
            case .verifyA:
                if let pending {
                    let accepted = access.completeRecovery(pending, verified: true)
                    let expected = aLost && aMounted && pending.counter == aCounter
                    #expect(accepted == expected)
                    if expected { aLost = false; expectedTransitions += 1 }
                }
                pending = nil
            case .failA:
                let stamp = access.stamp(for: a)
                access.reportRootFailure(a, cause: .unknown, from: stamp)
                if !aLost { aLost = true; aCause = .unknown; aCounter += 1; expectedTransitions += 1 }
            case .unmountB:
                if bMounted { bMounted = false; bLost = true; bCounter += 1; expectedTransitions += 1 }
                access.diskUnmounted(volumeUUID: "222")
            }
            #expect(access.snapshot(for: a)?.counter == aCounter)
            #expect(access.snapshot(for: b)?.counter == bCounter)
            #expect(access.snapshot(for: a)?.availability == (aLost ? .lost(aCause) : .readable))
            #expect(access.snapshot(for: b)?.availability == (bLost ? .lost(.diskNotConnected) : .readable))
            #expect(access.mayDeliver(oldA) == (!aLost && aCounter == 0))
            #expect(access.mayDeliver(oldB) == (!bLost && bCounter == 0))
        }
        #expect(transitions == expectedTransitions)
        access.removeObserver(observer)
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229AccessStateRejectsStaleDecodeThumbnailMetadataAndScanDelivery() {
    enum Work: CaseIterable { case decode, thumbnail, metadata, scan }
    let access = AccessState()
    let root = AccessRootID(), other = AccessRootID()
    access.register(root, volumeUUID: "111")
    access.register(other, volumeUUID: "222")
    let old = access.stamp(for: root), otherStamp = access.stamp(for: other)
    var delivered: [Work] = []
    access.diskUnmounted(volumeUUID: "111")
    for work in Work.allCases where access.mayDeliver(old) { delivered.append(work) }
    #expect(delivered.isEmpty)
    #expect(!access.mayDeliver(access.stamp(for: root)))
    #expect(access.mayDeliver(otherStamp))
    let attempt = access.diskMounted(volumeUUID: "111").first
    #expect(attempt != nil)
    if let attempt { #expect(access.completeRecovery(attempt, verified: true)) }
    #expect(!access.mayDeliver(old))
    let fresh = access.stamp(for: root)
    for work in Work.allCases where access.mayDeliver(fresh) { delivered.append(work) }
    #expect(delivered.count == Work.allCases.count)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229AccessStateDelayedVerificationCannotResurrectSecondEject() {
    let access = AccessState()
    let root = AccessRootID()
    access.register(root, volumeUUID: "111")
    var changes: [AccessStateChange] = []
    let observer = access.observe { changes.append($0) }
    access.diskUnmounted(volumeUUID: "111")
    let attempt = access.diskMounted(volumeUUID: "111").first
    #expect(attempt != nil)
    access.diskUnmounted(volumeUUID: "111")
    if let attempt { #expect(!access.completeRecovery(attempt, verified: true)) }
    #expect(access.snapshot(for: root)?.availability == .lost(.diskNotConnected))
    #expect(access.snapshot(for: root)?.counter == 2)
    #expect(changes == [.lost(root, counter: 1), .lost(root, counter: 2)])
    access.removeObserver(observer)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229AccessStateRootFailureDoesNotLoseReadableOtherRootOrSelfHeal() {
    let access = AccessState()
    let a = AccessRootID(), b = AccessRootID()
    access.register(a, volumeUUID: "111")
    access.register(b, volumeUUID: "222")
    let staleA = access.stamp(for: a), bStamp = access.stamp(for: b)
    access.reportRootFailure(a, cause: .unknown, from: staleA)
    #expect(access.snapshot(for: a) == AccessRootSnapshot(volumeUUID: "111", counter: 1, availability: .lost(.unknown)))
    #expect(access.snapshot(for: b)?.availability == .readable)
    #expect(access.mayDeliver(bStamp))
    access.reportRootFailure(a, cause: .unknown, from: staleA)
    #expect(access.snapshot(for: a)?.counter == 1)
    #expect(access.diskMounted(volumeUUID: "222").isEmpty)
    #expect(access.snapshot(for: a)?.availability == .lost(.unknown))
    #expect(access.snapshot(for: b)?.availability == .readable)
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229AccessStateUnknownAndRetiredRootStampsNeverBecomeAdmissible() {
    let access = AccessState()
    let root = AccessRootID()
    let unknown = access.stamp(for: root)
    #expect(!access.mayDeliver(unknown))
    access.register(root, volumeUUID: "111")
    #expect(!access.mayDeliver(unknown))
    let fresh = access.stamp(for: root)
    #expect(access.mayDeliver(fresh))
    access.forget(root)
    #expect(!access.mayDeliver(fresh))
    access.register(root, volumeUUID: "111")
    #expect(!access.mayDeliver(fresh))
    #expect(access.mayDeliver(access.stamp(for: root)))
}


@MainActor @Test(.timeLimit(.minutes(2))) func t229RootFailureRejectsAnotherRootsCurrentStamp() {
    let state = AccessState(), a = AccessRootID(), b = AccessRootID()
    state.register(a, volumeUUID: "111")
    state.register(b, volumeUUID: "222")
    let aStamp = state.stamp(for: a)
    var events: [AccessStateChange] = []
    state.observe { events.append($0) }
    #expect(!state.reportRootFailure(b, cause: .unknown, from: aStamp))
    #expect(state.snapshot(for: a)?.availability == .readable)
    #expect(state.snapshot(for: b)?.availability == .readable)
    #expect(state.snapshot(for: b)?.counter == 0)
    #expect(events.isEmpty)
    state.diskUnmounted(volumeUUID: "111")
    #expect(!state.reportRootFailure(b, cause: .unknown, from: aStamp))
    #expect(state.snapshot(for: b)?.availability == .readable)
    #expect(state.reportRootFailure(b, cause: .unknown, from: state.stamp(for: b)))
    #expect(state.snapshot(for: a)?.availability == .lost(.diskNotConnected))
    #expect(state.snapshot(for: b)?.availability == .lost(.unknown))
    #expect(state.snapshot(for: b)?.counter == 1)
    #expect(events == [.lost(a, counter: 1), .lost(b, counter: 1)])
}

@MainActor @Test(.timeLimit(.minutes(2))) func t229ReplacementRegistrationRevokesPriorAuthorityAndWakeRetriesOnlyLostMountedRoots() throws {
    let state = AccessState(), root = AccessRootID()
    #expect(state.recoveryAttempt(for: root) == nil)
    state.register(root, volumeUUID: "old")
    let first = try #require(state.permit(for: root))
    state.register(root, volumeUUID: "old")
    #expect(first.isCurrent)
    state.register(root, volumeUUID: "new")
    #expect(!first.isCurrent)
    #expect(state.snapshot(for: root)?.counter == 1)
    #expect(state.snapshot(for: root)?.volumeUUID == "new")
    #expect(state.recoveryAttempt(for: root) == nil)
    #expect(state.reportRootFailure(root, cause: .unknown, from: state.stamp(for: root)))
    let attempt = try #require(state.recoveryAttempt(for: root))
    #expect(attempt == AccessRecoveryAttempt(rootID: root, counter: 2, volumeUUID: "new"))
    state.diskUnmounted(volumeUUID: "new")
    #expect(state.recoveryAttempt(for: root) == nil)
    #expect(!state.completeRecovery(attempt, verified: true))
    #expect(state.diskMounted(volumeUUID: "new").count == 1)
    #expect(state.recoveryAttempt(for: root)?.counter == 3)
}
