import Dispatch
import Foundation
import Testing

private func currentQueueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

/// #774: CPU-bound property walks run on their own queue, not on a cooperative thread, and still inside the test.
@Test(.timeLimit(.minutes(2))) func issue774OffCooperativePoolRunsTheBodyOnItsOwnQueueInsideTheTest() async {
    guard #available(macOS 15.0, *) else { return }
    #expect(currentQueueLabel().contains("cooperative"))
    let inside = await offCooperativePool { (label: currentQueueLabel(), test: Test.current?.name) }
    #expect(inside.label == offCooperativePoolLabel)
    #expect(inside.test == Test.current?.name)
    #expect(inside.test != nil)
    #expect(currentQueueLabel().contains("cooperative"))
}

/// #787: at most `offCooperativePoolWidth` walk bodies run at once (all cores but two, at least one), so on a 3-core runner
/// the property walks take one core and leave two to the rest of the run (CI run 44671441840: eight walks at once
/// stretched unrelated tests to 29 s). Every body still runs and returns its value.
@Test(.timeLimit(.minutes(2))) func issue787OffCooperativePoolRunsAtMostItsWidthOfBodiesAtOnce() async {
    guard #available(macOS 15.0, *) else { return }
    #expect(offCooperativePoolWidth == max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
    final class Peak: @unchecked Sendable {
        let lock = NSLock()
        var running = 0, peak = 0
        func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
        func leave() { lock.lock(); running -= 1; lock.unlock() }
    }
    let peak = Peak(), count = offCooperativePoolWidth + 2
    let results = await withTaskGroup(of: Int.self) { group in
        for index in 0..<count {
            group.addTask { await offCooperativePool { peak.enter(); Thread.sleep(forTimeInterval: 0.2); peak.leave(); return index } }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(results.sorted() == Array(0..<count))
    // Walks of other suites share the limit, so this test can see fewer than `width` of its own bodies at once.
    #expect((1...offCooperativePoolWidth).contains(peak.peak), "peak \(peak.peak) bodies at once, width \(offCooperativePoolWidth)")
}
