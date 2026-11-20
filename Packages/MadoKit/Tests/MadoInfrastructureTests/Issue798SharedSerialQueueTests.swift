import Dispatch
import Foundation
import Testing

private func currentQueueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

private actor LabelProbe {
    func label() -> String { currentQueueLabel() }
}

/// #798: the Baidu upload tests re-encode large noise images inside the provider actor, synchronously. On the 3-core CI
/// runner three of them held all three cooperative threads while the unrelated suites waited (CI run 44724946406).
/// Their bodies, and the actors they call, run on one serial queue instead, still inside the test.
@Test(.timeLimit(.minutes(2))) func issue798SharedSerialQueueRunsTheBodyAndItsActorsOffThePool() async {
    guard #available(macOS 15.0, *) else { return }
    #expect(currentQueueLabel().contains("cooperative"))
    let probe = LabelProbe()
    let inside = await onSharedSerialQueue { (body: currentQueueLabel(), actor: await probe.label(), test: Test.current?.name) }
    #expect(inside.body == sharedSerialQueueLabel)
    #expect(inside.actor == sharedSerialQueueLabel)
    #expect(inside.test == Test.current?.name)
    #expect(inside.test != nil)
    #expect(currentQueueLabel().contains("cooperative"))
}

/// One queue for every caller: at most one body runs at a time, so the re-encodes take at most one core. A body that
/// throws passes its error through.
@Test(.timeLimit(.minutes(2))) func issue798SharedSerialQueueRunsOneBodyAtATime() async {
    guard #available(macOS 15.0, *) else { return }
    final class Peak: @unchecked Sendable {
        let lock = NSLock()
        var running = 0, peak = 0
        func enter() { lock.lock(); running += 1; peak = max(peak, running); lock.unlock() }
        func leave() { lock.lock(); running -= 1; lock.unlock() }
    }
    let peak = Peak(), count = 4
    let results = await withTaskGroup(of: Int.self) { group in
        for index in 0..<count {
            group.addTask { await onSharedSerialQueue { peak.enter(); usleep(100_000); peak.leave(); return index } }
        }
        return await group.reduce(into: []) { $0.append($1) }
    }
    #expect(results.sorted() == Array(0..<count))
    #expect(peak.peak == 1, "peak \(peak.peak) bodies at once")
    struct Failed: Error, Equatable {}
    await #expect(throws: Failed()) { try await onSharedSerialQueue { () async throws(Failed) -> Int in throw Failed() } }
}
