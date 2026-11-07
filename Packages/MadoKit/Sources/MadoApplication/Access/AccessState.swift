import Foundation
import MadoCore

public enum AccessLossCause: Equatable, Sendable {
    case diskNotConnected, notFound, accessExpired, unknown
}

public enum AccessAvailability: Equatable, Sendable {
    case readable
    case lost(AccessLossCause)
}

public struct AccessRootSnapshot: Equatable, Sendable {
    public let volumeUUID: String?
    public let counter: UInt64
    public let availability: AccessAvailability
    public init(volumeUUID: String?, counter: UInt64, availability: AccessAvailability) {
        self.volumeUUID = volumeUUID
        self.counter = counter
        self.availability = availability
    }
}

public struct AccessWorkStamp: Hashable, Sendable {
    public let rootID: AccessRootID
    public let counter: UInt64
    public init(rootID: AccessRootID, counter: UInt64) {
        self.rootID = rootID
        self.counter = counter
    }
}

public struct AccessRecoveryAttempt: Equatable, Sendable {
    public let rootID: AccessRootID
    public let counter: UInt64
    public let volumeUUID: String?
    public init(rootID: AccessRootID, counter: UInt64, volumeUUID: String?) {
        self.rootID = rootID
        self.counter = counter
        self.volumeUUID = volumeUUID
    }
}

public enum AccessStateChange: Equatable, Sendable {
    case lost(AccessRootID, counter: UInt64)
    case recovered(AccessRootID, counter: UInt64)
}

/// Shared across windows; OS events and access readers feed this owner.
@MainActor public final class AccessState {
    private struct Entry {
        var volumeUUID: String?
        var counter: UInt64
        var availability: AccessAvailability
        var mounted: Bool
        let authority: AccessWorkAuthority
        init(volumeUUID: String?) {
            self.volumeUUID = volumeUUID
            counter = 0
            availability = .readable
            mounted = true
            authority = AccessWorkAuthority()
        }
    }

    private var entries: [AccessRootID: Entry] = [:]
    private var retiredCounters: [AccessRootID: UInt64] = [:]
    private var observers: [UUID: @MainActor (AccessStateChange) -> Void] = [:]

    nonisolated public init() {}
    public func permit(for rootID: AccessRootID) -> AccessWorkPermit? {
        guard let entry = entries[rootID], entry.availability == .readable else { return nil }
        return entry.authority.permit(counter: entry.counter)
    }
    public func reauthorize(_ rootID: AccessRootID, volumeUUID: String?,
                            admitting admission: (_ update: () -> Void) throws -> Void) rethrows {
        var change: AccessStateChange?
        try admission { change = reauthorizeEntry(rootID, volumeUUID: volumeUUID) }
        // Observation may invalidate the saved-grant proof or start another read.
        // Publish only after the caller's synchronous version fence has released.
        if let change { publish(change) }
    }
    /// An explicit selection replaces authority even on the same volume.
    public func reauthorize(_ rootID: AccessRootID, volumeUUID: String?) {
        if let change = reauthorizeEntry(rootID, volumeUUID: volumeUUID) { publish(change) }
    }
    private func reauthorizeEntry(_ rootID: AccessRootID, volumeUUID: String?) -> AccessStateChange? {
        guard var entry = entries[rootID] else { register(rootID, volumeUUID: volumeUUID); return nil }
        let wasLost = entry.availability != .readable
        entry.counter += 1
        entry.volumeUUID = volumeUUID
        entry.availability = .readable
        entry.mounted = true
        entry.authority.update(counter: entry.counter, readable: true)
        entries[rootID] = entry
        return wasLost ? .recovered(rootID, counter: entry.counter) : nil
    }
    public func register(_ rootID: AccessRootID, volumeUUID: String?) {
        if var existing = entries[rootID] {
            // Explicitly replacing a grant revokes every old work stamp too.
            if existing.volumeUUID != volumeUUID {
                existing.counter += 1
                existing.volumeUUID = volumeUUID
                existing.availability = .readable
                existing.mounted = true
                existing.authority.update(counter: existing.counter, readable: true)
                entries[rootID] = existing
            }
        } else {
            var entry = Entry(volumeUUID: volumeUUID)
            if let retired = retiredCounters[rootID] { entry.counter = retired + 1 }
            entry.authority.update(counter: entry.counter, readable: true)
            entries[rootID] = entry
        }
    }
    public func forget(_ rootID: AccessRootID) {
        if let entry = entries.removeValue(forKey: rootID) {
            entry.authority.update(counter: entry.counter, readable: false)
            retiredCounters[rootID] = entry.counter
        }
    }
    public func snapshot(for rootID: AccessRootID) -> AccessRootSnapshot? {
        guard let entry = entries[rootID] else { return nil }
        return AccessRootSnapshot(volumeUUID: entry.volumeUUID, counter: entry.counter,
                                  availability: entry.availability)
    }
    public func stamp(for rootID: AccessRootID) -> AccessWorkStamp {
        AccessWorkStamp(rootID: rootID, counter: entries[rootID]?.counter ?? UInt64.max)
    }
    public func mayDeliver(_ stamp: AccessWorkStamp) -> Bool {
        guard stamp.counter != UInt64.max, let entry = entries[stamp.rootID] else { return false }
        return entry.counter == stamp.counter && entry.availability == .readable
    }
    @discardableResult public func observe(_ observer: @escaping @MainActor (AccessStateChange) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    private func publish(_ change: AccessStateChange) {
        for observer in Array(observers.values) { observer(change) }
    }
    public func diskUnmounted(volumeUUID: String) {
        for (id, var entry) in entries where entry.volumeUUID == volumeUUID && entry.mounted {
            entry.mounted = false
            entry.counter += 1
            entry.availability = .lost(.diskNotConnected)
            entry.authority.update(counter: entry.counter, readable: false)
            entries[id] = entry
            publish(.lost(id, counter: entry.counter))
        }
    }
    public func diskMounted(volumeUUID: String) -> [AccessRecoveryAttempt] {
        var attempts: [AccessRecoveryAttempt] = []
        for (id, var entry) in entries where entry.volumeUUID == volumeUUID && !entry.mounted {
            entry.mounted = true
            entries[id] = entry
            if case .lost = entry.availability {
                attempts.append(AccessRecoveryAttempt(rootID: id, counter: entry.counter, volumeUUID: volumeUUID))
            }
        }
        return attempts
    }
    /// Foreground/wake and access failures may request another real verification.
    public func recoveryAttempt(for rootID: AccessRootID) -> AccessRecoveryAttempt? {
        guard let entry = entries[rootID], entry.mounted,
              case .lost = entry.availability else { return nil }
        return AccessRecoveryAttempt(rootID: rootID, counter: entry.counter, volumeUUID: entry.volumeUUID)
    }
    @discardableResult public func reportRootFailure(_ rootID: AccessRootID, cause: AccessLossCause,
                                                       from stamp: AccessWorkStamp) -> Bool {
        guard stamp.rootID == rootID, mayDeliver(stamp), var entry = entries[rootID] else { return false }
        entry.counter += 1
        entry.availability = .lost(cause)
        if cause == .diskNotConnected { entry.mounted = false }
        entry.authority.update(counter: entry.counter, readable: false)
        entries[rootID] = entry
        publish(.lost(rootID, counter: entry.counter))
        return true
    }
    @discardableResult public func completeRecovery(_ attempt: AccessRecoveryAttempt, verified: Bool,
        admitting admission: (_ update: () -> Void) throws -> Void) rethrows -> Bool {
        var change: AccessStateChange?
        try admission { change = completeRecoveryEntry(attempt, verified: verified) }
        if let change { publish(change) }
        return change != nil
    }
    /// Cause refinement belongs to the same waiting episode and cannot confer
    /// readability. A matching mount may be retried after a transient failure.
    @discardableResult public func refineRecoveryFailure(_ attempt: AccessRecoveryAttempt,
                                                         cause: AccessLossCause) -> Bool {
        guard var entry = entries[attempt.rootID], entry.mounted,
              entry.counter == attempt.counter, entry.volumeUUID == attempt.volumeUUID,
              case .lost = entry.availability else { return false }
        let changed = entry.availability != .lost(cause)
        entry.availability = .lost(cause)
        if cause == .diskNotConnected { entry.mounted = false }
        entry.authority.update(counter: entry.counter, readable: false)
        entries[attempt.rootID] = entry
        if changed { publish(.lost(attempt.rootID, counter: entry.counter)) }
        return changed
    }
    @discardableResult public func completeRecovery(_ attempt: AccessRecoveryAttempt, verified: Bool) -> Bool {
        guard let change = completeRecoveryEntry(attempt, verified: verified) else { return false }
        publish(change)
        return true
    }
    private func completeRecoveryEntry(_ attempt: AccessRecoveryAttempt, verified: Bool) -> AccessStateChange? {
        guard verified, var entry = entries[attempt.rootID], entry.mounted,
              entry.counter == attempt.counter, entry.volumeUUID == attempt.volumeUUID,
              case .lost = entry.availability else { return nil }
        entry.availability = .readable
        entry.authority.update(counter: entry.counter, readable: true)
        entries[attempt.rootID] = entry
        return .recovered(attempt.rootID, counter: entry.counter)
    }

}
