import Foundation
import Testing
import MadoCore
import MadoApplication

private enum T229AdmissionError: Error, Equatable { case rejected }

@MainActor @Test func t229StateReauthorizationMutatesUnderFenceAndPublishesOutsideIt() throws {
    let state = AccessState(), id = AccessRootID(), lock = NSLock()
    state.register(id, volumeUUID: "111")
    state.diskUnmounted(volumeUUID: "111")
    var inAdmission = false
    var callbackOutsideAdmission = false
    var callbackCouldAcquireFence = false
    var events: [AccessStateChange] = []
    _ = state.observe { change in
        callbackOutsideAdmission = !inAdmission
        callbackCouldAcquireFence = lock.try()
        if callbackCouldAcquireFence { lock.unlock() }
        events.append(change)
    }
    state.reauthorize(id, volumeUUID: "222", admitting: { update in
        lock.lock()
        inAdmission = true
        update()
        #expect(state.snapshot(for: id)?.availability == .readable)
        #expect(state.snapshot(for: id)?.volumeUUID == "222")
        #expect(state.snapshot(for: id)?.counter == 2)
        inAdmission = false
        lock.unlock()
    })
    #expect(callbackOutsideAdmission)
    #expect(callbackCouldAcquireFence)
    #expect(events == [.recovered(id, counter: 2)])
    #expect(state.permit(for: id)?.isCurrent == true)
}

@MainActor @Test func t229RejectedGrantFenceCannotChangeStateOrPublishRecovery() {
    let state = AccessState(), id = AccessRootID()
    state.register(id, volumeUUID: "111")
    state.diskUnmounted(volumeUUID: "111")
    let before = state.snapshot(for: id)
    var events: [AccessStateChange] = []
    _ = state.observe { events.append($0) }
    #expect(throws: T229AdmissionError.rejected) {
        try state.reauthorize(id, volumeUUID: "222", admitting: { _ in throw T229AdmissionError.rejected })
    }
    #expect(state.snapshot(for: id) == before)
    #expect(events.isEmpty)
    #expect(state.permit(for: id) == nil)
}
