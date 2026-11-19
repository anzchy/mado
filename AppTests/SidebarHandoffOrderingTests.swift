import AppKit
import Testing

// #751 O1: the scan's first complete snapshot starts the canonical sidebar load while the reconcile load holds the
// replacement registration, and the canonical load cancels it. Each handoff delivery must still reach every stage
// and refresh D from one external change. A gate that can no longer hold fails its stage at once, by name.

@Test(.timeLimit(.minutes(3))) @MainActor func issue751CanonicalLoadCancellingTheHeldRegistrationStillDeliversDuringCapturedRead() async throws {
    try await expectSidebarHandoffDelivery(.beforeRegistrationRelease, ordering: .canonicalLoadCancelsHeldRegistration)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue751CanonicalLoadCancellingTheHeldRegistrationStillDeliversAfterOldSubscriptionRetires() async throws {
    try await expectSidebarHandoffDelivery(.afterOldSubscriptionRetires, ordering: .canonicalLoadCancelsHeldRegistration)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue751CanonicalLoadCancellingTheHeldRegistrationStillRefreshesDuringOwnedRead() async throws {
    try await expectSidebarHandoffDelivery(.duringOwnedRead, ordering: .canonicalLoadCancelsHeldRegistration)
}

@MainActor private final class Issue495Looks {
    var afterCancel = 0
}

/// #495: the t232 sidebar wait ends with a ConditionWaitError when its task is cancelled. The condition gives the
/// old yield loop a way out after three cancelled looks, so a wait that ignores cancellation fails here, not at 180 s.
@Test(.timeLimit(.minutes(1))) @MainActor func issue495T232SidebarWaitThrowsWhenItsTaskIsCancelled() async {
    let looks = Issue495Looks()
    let wait = Task { @MainActor in
        try await t232SidebarWait {
            if Task.isCancelled { looks.afterCancel += 1 }
            return looks.afterCancel >= 3
        }
    }
    wait.cancel()
    let result = await wait.result
    #expect(throws: ConditionWaitError.self) { try result.get() }
}
