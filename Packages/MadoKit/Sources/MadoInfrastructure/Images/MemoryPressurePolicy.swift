import Foundation
import MadoCore

public enum MemoryPressureLevel: String, Sendable { case normal, warning, critical }

/// State advances only at pressure delivery or a request; a waiter asks `prefetchDelay()` how long to sleep.
struct MemoryPressurePolicy: Sendable {
    private(set) var level: MemoryPressureLevel = .normal
    let recoveryDelay: TimeInterval
    let clock: @Sendable () -> TimeInterval
    private var suspended = false
    private var normalSince: TimeInterval?
    init(recoveryDelay: TimeInterval, clock: @escaping @Sendable () -> TimeInterval) {
        precondition(recoveryDelay.isFinite && recoveryDelay >= 0)
        self.recoveryDelay = recoveryDelay; self.clock = clock
    }
    mutating func update(_ level: MemoryPressureLevel) {
        guard self.level != level else { return }
        self.level = level
        if level == .normal { normalSince = clock() }
        else { suspended = true; normalSince = nil }
    }
    mutating func permits(_ priority: DecodePriority) -> Bool {
        if suspended, level == .normal, let normalSince, clock() - normalSince >= recoveryDelay {
            suspended = false; self.normalSince = nil
        }
        return priority != .prefetch || !suspended
    }
    /// Seconds until prefetch is permitted again, or nil when it is. While pressure lasts its end is unknown,
    /// so the caller looks again after one recovery delay (at least a second).
    mutating func prefetchDelay() -> TimeInterval? {
        guard !permits(.prefetch) else { return nil }
        guard level == .normal, let normalSince else { return max(recoveryDelay, 1) }
        return recoveryDelay - (clock() - normalSince)
    }
}
