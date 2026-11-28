import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #874 fix round 2 WI-1 (audit i874-confirm1 gpt F1): the run says the image is with the service (`working`) only
// once the transport has admitted the request, from inside the transport's own entry. A run cancelled or refused at
// that entry has sent nothing and never passes through `working`.

@MainActor private final class Clipboard874G: TableClipboardWriting {
    func writeTable(html: String, tabSeparated: String) -> Bool { true }
}

@MainActor private final class StateLog874G {
    weak var flow: RecogniseTableFlow?
    private(set) var states: [RecogniseTableState] = []
    func record() { if let flow { states.append(flow.state) } }
    var everSaidSent: Bool { states.contains { if case .working = $0 { true } else { false } } }
}

private struct Refused874G: Error {}

/// Like the real transport: at its entry it checks the request (here it can hold there first, or refuse), and only
/// then reports the start and sends.
private actor EntryTransport874G: HTTPTransport {
    private let refuse: Bool
    private let holdAtEntry: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var entered = 0
    private(set) var started = 0
    /// What happened, in order: "entered", "started".
    private(set) var events: [String] = []
    init(refuse: Bool = false, holdAtEntry: Bool = false) { self.refuse = refuse; self.holdAtEntry = holdAtEntry }
    var holding: Bool { gate != nil }
    func open() { gate?.resume(); gate = nil }
    func note(_ event: String) { events.append(event) }

    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        try await send(request, to: destination, onStart: {})
    }

    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse {
        entered += 1
        events.append("entered")
        if holdAtEntry { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if refuse { throw Refused874G() }
        await onStart()
        started += 1
        events.append("started")
        return goodReply869()
    }
}

@MainActor private func flow874G(_ transport: EntryTransport874G, log: StateLog874G) -> RecogniseTableFlow {
    let flow = RecogniseTableFlow(settings: FakeTableSettings869(.default869), credentials: FakeTableKeys869(),
        transport: transport, clipboard: Clipboard874G(), recordConsent: { _ in }, report: { _ in },
        onChange: { log.record() })
    log.flow = flow
    return flow
}

private func waitUntil874G(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix2NothingSaysSentWhileTheTransportHoldsTheRequestAtItsEntry() async {
    let transport = EntryTransport874G(holdAtEntry: true)
    let log = StateLog874G()
    let flow = flow874G(transport, log: log)
    let run = flow.start(image: { makePNG869(4, 3) })
    await waitUntil874G { await transport.holding }
    #expect(flow.state == .preparing(host: "api.deepseek.com"), "the transport has not admitted the request yet")
    #expect(!log.everSaidSent)
    await transport.open()
    await run.value
    guard case .result = flow.state else { Issue.record("expected a result, got \(flow.state)"); return }
    #expect(log.states.filter { $0 == .working(host: "api.deepseek.com") }.count == 1, "working once, at the start")
    #expect(await transport.started == 1)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix2CancelAtTheTransportEntrySendsNothingAndNeverSaysSent() async {
    let transport = EntryTransport874G(holdAtEntry: true)
    let log = StateLog874G()
    let flow = flow874G(transport, log: log)
    let run = flow.start(image: { makePNG869(4, 3) })
    await waitUntil874G { await transport.holding }
    flow.cancel()
    await transport.open()
    await run.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(flow.state == .cancelled)
    #expect(await transport.entered == 1)
    #expect(await transport.started == 0, "the transport sent nothing")
    #expect(!log.everSaidSent, "the run never said the image was sent")
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix2ATransportRefusalAtItsEntryNeverSaysSent() async {
    let transport = EntryTransport874G(refuse: true)
    let log = StateLog874G()
    let flow = flow874G(transport, log: log)
    await flow.start(image: { makePNG869(4, 3) }).value
    guard case .failed = flow.state else { Issue.record("expected a failure, got \(flow.state)"); return }
    #expect(await transport.entered == 1)
    #expect(await transport.started == 0)
    #expect(!log.everSaidSent, "a refused request was never said to be sent")
}

@Test(.timeLimit(.minutes(2)))
func issue874Fix2TheServiceReportsTheSendFromInsideTheTransportAfterItsEntry() async {
    let admitted = EntryTransport874G()
    let service = TableRecognitionService(settings: FakeTableSettings869(.default869), credentials: FakeTableKeys869(),
                                          transport: admitted)
    _ = await service.recognise(makePNG869(4, 3), willSend: { await admitted.note("willSend") })
    #expect(await admitted.events == ["entered", "willSend", "started"])
    let refused = EntryTransport874G(refuse: true)
    _ = await TableRecognitionService(settings: FakeTableSettings869(.default869), credentials: FakeTableKeys869(),
                                      transport: refused)
        .recognise(makePNG869(4, 3), willSend: { await refused.note("willSend") })
    #expect(await refused.events == ["entered"], "a refused request reports no send")
}
