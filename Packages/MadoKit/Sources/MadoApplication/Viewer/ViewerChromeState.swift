import Foundation

@MainActor public protocol ViewerClock: AnyObject {
    var now: TimeInterval { get }
}

@MainActor public final class MonotonicViewerClock: ViewerClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

public enum ChromeLockReason: CaseIterable, Hashable, Sendable {
    case menu, inspector, filmstrip, keyboardFocus, pointerHover, pointerPress
}

public enum ChromeVisibility: Equatable, Sendable {
    case hidden, visible, pinned, locked(Set<ChromeLockReason>)
}

/// No scheduler. The host schedules from nextHideDeadline and reports elapsed time.
public struct ViewerChromeState: Sendable {
    /// Adjustable prototype parameter, pending P1-08 device verification.
    public let hideDelay: TimeInterval
    public private(set) var locks: Set<ChromeLockReason> = []
    public private(set) var isPinned = false
    public private(set) var isHidden = false
    private var lastActivity: TimeInterval
    public init(now: TimeInterval, hideDelay: TimeInterval = 2.5) {
        lastActivity = now
        self.hideDelay = hideDelay
    }
    public var visibility: ChromeVisibility {
        if !locks.isEmpty { return .locked(locks) }
        if isPinned { return .pinned }
        return isHidden ? .hidden : .visible
    }
    public var nextHideDeadline: TimeInterval? {
        locks.isEmpty && !isPinned && !isHidden ? lastActivity + hideDelay : nil
    }
    public mutating func activity(at now: TimeInterval) {
        lastActivity = now
        isHidden = false
    }
    public mutating func setLock(_ reason: ChromeLockReason, active: Bool, at now: TimeInterval) {
        if active {
            locks.insert(reason)
            activity(at: now)
        } else if locks.remove(reason) != nil, locks.isEmpty {
            activity(at: now)
        }
    }
    public mutating func setPinned(_ pinned: Bool, at now: TimeInterval) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        activity(at: now)
    }
    public mutating func advance(to now: TimeInterval) {
        if let deadline = nextHideDeadline, now >= deadline { isHidden = true }
    }
}
