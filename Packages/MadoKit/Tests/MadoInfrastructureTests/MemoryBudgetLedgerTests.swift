import Foundation
import Testing
@testable import MadoInfrastructure

/// The ledger alone decides staging and evictable room, so two actors can never both take the same bytes.
@Suite struct MemoryBudgetLedgerTests {
    @Test func ledgerReservationAndEvictableRoomAreTakenAtomically() {
        let budget = MemoryBudget(limit: 64)
        #expect(budget.resident(pinned: 16, evictable: 32) == 32)
        #expect(budget.reserve(16, idleCurrent: false))
        #expect(!budget.reserve(16, idleCurrent: false))
        // Staging taken first leaves only the rest for evictable pixels, whatever the cache last read.
        #expect(budget.resident(pinned: 16, evictable: 48) == 32)
        #expect(budget.usage == MemoryBudget.Usage(pinned: 16, evictable: 32, reserved: 16))
        #expect(budget.peak == 64)
        budget.unreserve(16)
        #expect(budget.usage.reserved == 0)
        #expect(budget.resident(pinned: 16, evictable: 48) == 48)
        #expect(budget.peak == 64)
    }

    @Test func ledgerLetsOnlyAnIdleCurrentDecodePastPins() {
        let budget = MemoryBudget(limit: 64)
        _ = budget.resident(pinned: 64, evictable: 0)
        #expect(!budget.reserve(16, idleCurrent: false))
        #expect(budget.reserve(16, idleCurrent: true))
        #expect(budget.peak == 80)
        budget.unreserve(16)
        _ = budget.resident(pinned: 48, evictable: 16)
        #expect(!budget.reserve(16, idleCurrent: true))
        #expect(budget.resident(pinned: 80, evictable: 16) == 0)
        #expect(budget.usage == MemoryBudget.Usage(pinned: 80, evictable: 0, reserved: 0))
    }

    @Test(.timeLimit(.minutes(2))) func ledgerNeverRecordsMoreThanItsLimitUnderContention() async {
        let budget = MemoryBudget(limit: 4096)
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for step in 0..<2000 {
                        if worker % 2 == 0 {
                            if budget.reserve(64, idleCurrent: false) { budget.unreserve(64) }
                        } else {
                            _ = budget.resident(pinned: 1024, evictable: (step % 64) * 64)
                        }
                    }
                }
            }
        }
        #expect(budget.peak <= 4096)
    }
}
