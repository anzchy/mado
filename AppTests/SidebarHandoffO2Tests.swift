import Foundation
import Testing

// #751 O2: the scan's own watch subscription registers after the sidebar gates are armed. It must not take the sidebar
// registration gate: the run must still reach the canonical load and refresh D, or fail at once by stage and reason.

@Test(.timeLimit(.minutes(3))) @MainActor func issue751ScanSubscriptionAfterArmingStillDeliversDuringOwnedRead() async throws {
    try await expectSidebarHandoffDelivery(.duringOwnedRead, ordering: .scanSubscribesAfterArming)
}

/// #751 audit M2: a caller already cancelled when it reaches an armed gate leaves the arm for the next caller, so a
/// cancel can never find an arm claimed by a holder that has not registered its cancellation handler yet.
@Test(.timeLimit(.minutes(1))) func issue751GateLeavesItsArmToTheNextCallerWhenTheCallerIsAlreadyCancelled() async throws {
    let gate = SidebarHandoffGate()
    gate.arm()
    let cancelled = Task {
        while !Task.isCancelled { await Task.yield() }
        await gate.holdIfArmed()
    }
    cancelled.cancel()
    await cancelled.value
    #expect(gate.isArmed)
    #expect(gate.abandonedHolds == 0)
    try #require(gate.isArmed)
    let next = Task { await gate.holdIfArmed() }
    try await waitUntil("next caller holds the gate") { gate.isHolding }
    gate.release()
    await next.value
    #expect(!gate.isHolding)
}
