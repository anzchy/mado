import Dispatch
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
