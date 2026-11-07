import Foundation

/// Serializes root revocation with short synchronous cache publication sections.
/// Never hold this lock while awaiting I/O or invoking an external callback.
public final class AccessWorkAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var counter: UInt64 = 0
    private var readable = true
    public init() {}
    public func update(counter: UInt64, readable: Bool) {
        lock.withLock {
            guard counter >= self.counter else { return }
            self.counter = counter
            self.readable = readable
        }
    }
    public func permit(counter: UInt64) -> AccessWorkPermit { AccessWorkPermit(authority: self, counter: counter) }
    fileprivate func admitting<T>(counter: UInt64, _ operation: () throws -> T) throws -> T {
        try lock.withLock {
            guard self.counter == counter, readable else { throw CancellationError() }
            return try operation()
        }
    }
    fileprivate func isCurrent(counter: UInt64) -> Bool {
        lock.withLock { self.counter == counter && readable }
    }
}

/// A result belongs to the captured access counter for its entire lifetime.
public final class AccessWorkPermit: Sendable {
    private let authority: AccessWorkAuthority
    private let counter: UInt64
    fileprivate init(authority: AccessWorkAuthority, counter: UInt64) {
        self.authority = authority; self.counter = counter
    }
    public func canCoalesce(with other: AccessWorkPermit?) -> Bool {
        guard let other else { return false }
        return authority === other.authority && counter == other.counter
    }
    public var isCurrent: Bool { authority.isCurrent(counter: counter) }
    public func check() throws { try authority.admitting(counter: counter) {} }
    public static func admitting<T>(_ permit: AccessWorkPermit?, _ operation: () throws -> T) throws -> T {
        if let permit { return try permit.authority.admitting(counter: permit.counter, operation) }
        return try operation()
    }
}
