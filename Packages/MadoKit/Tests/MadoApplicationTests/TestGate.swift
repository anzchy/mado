import Foundation

/// A gate a test double blocks a worker thread on (#392). `signal()` lets one waiter through, like a semaphore;
/// `open()` lets every current and later waiter through. A test opens its gate in `defer`, so a test that ends early
/// (a failed `#require`, a thrown wait, a time-limit cancellation) never leaves a worker blocked for the rest of the run.
final class TestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var permits = 0
    private var isOpen = false
    func wait() {
        condition.lock(); defer { condition.unlock() }
        while !isOpen && permits == 0 { condition.wait() }
        if !isOpen { permits -= 1 }
    }
    func signal() { condition.lock(); permits += 1; condition.signal(); condition.unlock() }
    func open() { condition.lock(); isOpen = true; condition.broadcast(); condition.unlock() }
}
