import Foundation

/// The one process-wide image memory ledger (ADR-005): cache-resident pixels, pinned or evictable, plus admitted
/// decode staging, against one limit that every window shares. The peak is the largest total after any recorded change.
final class MemoryBudget: @unchecked Sendable {
    struct Usage: Equatable, Sendable {
        var pinned = 0
        var evictable = 0
        var reserved = 0
        var total: Int { pinned + evictable + reserved }
    }
    let limit: Int
    private let lock = NSLock()
    private var current = Usage()
    private var highest = 0
    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }
    var usage: Usage { lock.withLock { current } }
    var peak: Int { lock.withLock { highest } }
    /// Records resident pixels and returns how many evictable bytes may stay.
    /// Pins are never refused; evictable bytes are recorded only up to the room pins and staging leave,
    /// and the cache trims down to the returned value.
    @discardableResult func resident(pinned: Int, evictable: Int) -> Int {
        lock.withLock {
            current.pinned = pinned
            current.evictable = min(evictable, max(0, limit - pinned - current.reserved))
            highest = max(highest, current.total)
            return current.evictable
        }
    }
    #if DEBUG
    /// Test seam: sets staging directly, without admission.
    func reserved(_ bytes: Int) {
        lock.withLock { current.reserved = bytes; highest = max(highest, current.total) }
    }
    #endif
    /// Takes `cost` of staging if it fits beside everything resident, or for an idle current decode
    /// when nothing evictable is left. Check and take happen under one lock.
    func reserve(_ cost: Int, idleCurrent: Bool) -> Bool {
        lock.withLock {
            guard cost <= limit - current.total || (idleCurrent && current.evictable == 0) else { return false }
            current.reserved += cost
            highest = max(highest, current.total)
            return true
        }
    }
    func unreserve(_ cost: Int) { lock.withLock { current.reserved -= cost } }
}
