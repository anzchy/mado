import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #874 fix round 3 WI-1 (audit i874-confirm2 gpt F1): the run says the image was sent (`working`) only from the
// transport's load report, which comes after its last cancellation check. A cancel landing while the transport
// reports the start leaves the run `preparing` (nothing said, nothing loaded); a reply that overtakes the load report
// is not overwritten by it.

@MainActor private final class Clipboard874H: TableClipboardWriting {
    func writeTable(html: String, tabSeparated: String) -> Bool { true }
}

@MainActor private final class StateLog874H {
    weak var flow: RecogniseTableFlow?
    private(set) var states: [RecogniseTableState] = []
    func record() { if let flow { states.append(flow.state) } }
    var everSaidSent: Bool { states.contains { if case .working = $0 { true } else { false } } }
}

/// Like the real transport: the start report, then (optionally) a hold inside it, the last cancellation check, the
/// load report and the load. `loadReportLate` keeps the load report until the test fires it, after the reply.
private actor LoadTransport874H: HTTPTransport {
    private let holdInStart: Bool
    private let loadReportLate: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var pendingLoad: (@Sendable () -> Void)?
    private(set) var started = 0
    private(set) var events: [String] = []
    init(holdInStart: Bool = false, loadReportLate: Bool = false) {
        self.holdInStart = holdInStart; self.loadReportLate = loadReportLate
    }
    var holding: Bool { gate != nil }
    func open() { gate?.resume(); gate = nil }
    func note(_ event: String) { events.append(event) }
    func fireLoad() { pendingLoad?(); pendingLoad = nil }

    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        try await send(request, to: destination, onStart: {}, onLoad: {})
    }

    func send(_ request: URLRequest, to destination: HTTPDestination,
              onStart: @escaping @Sendable () async -> Void) async throws -> HTTPResponse {
        try await send(request, to: destination, onStart: onStart, onLoad: {})
    }

    func send(_ request: URLRequest, to destination: HTTPDestination, onStart: @escaping @Sendable () async -> Void,
              onLoad: @escaping @Sendable () -> Void) async throws -> HTTPResponse {
        events.append("entered")
        try Task.checkCancellation()
        await onStart()
        if holdInStart { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if loadReportLate {
            pendingLoad = onLoad
        } else {
            onLoad()
        }
        started += 1
        events.append("started")
        return goodReply869()
    }
}

@MainActor private func flow874H(_ transport: LoadTransport874H, log: StateLog874H) -> RecogniseTableFlow {
    let flow = RecogniseTableFlow(settings: FakeTableSettings869(.default869), credentials: FakeTableKeys869(),
        transport: transport, clipboard: Clipboard874H(), recordConsent: { _ in }, report: { _ in },
        onChange: { log.record() })
    log.flow = flow
    return flow
}

private func waitUntil874H(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix3NothingSaysSentWhileTheTransportReportsTheStart() async {
    let transport = LoadTransport874H(holdInStart: true)
    let log = StateLog874H()
    let flow = flow874H(transport, log: log)
    let run = flow.start(image: { makePNG869(4, 3) })
    await waitUntil874H { await transport.holding }
    try? await Task.sleep(for: .milliseconds(50))
    #expect(flow.state == .preparing(host: "api.deepseek.com"), "the transport has not started the load yet")
    #expect(!log.everSaidSent)
    await transport.open()
    await run.value
    guard case .result = flow.state else { Issue.record("expected a result, got \(flow.state)"); return }
    #expect(log.states.filter { $0 == .working(host: "api.deepseek.com") }.count == 1, "working once, at the load")
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix3CancelWhileTheTransportReportsTheStartSendsNothingAndNeverSaysSent() async {
    let transport = LoadTransport874H(holdInStart: true)
    let log = StateLog874H()
    let flow = flow874H(transport, log: log)
    let run = flow.start(image: { makePNG869(4, 3) })
    await waitUntil874H { await transport.holding }
    try? await Task.sleep(for: .milliseconds(50))
    flow.cancel()
    await transport.open()
    await run.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(flow.state == .cancelled)
    #expect(await transport.started == 0, "the transport loaded nothing")
    #expect(!log.everSaidSent, "the run never said the image was sent")
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix3ALoadReportAfterTheReplyLeavesTheResult() async {
    let transport = LoadTransport874H(loadReportLate: true)
    let log = StateLog874H()
    let flow = flow874H(transport, log: log)
    await flow.start(image: { makePNG869(4, 3) }).value
    guard case .result = flow.state else { Issue.record("expected a result, got \(flow.state)"); return }
    await transport.fireLoad()
    try? await Task.sleep(for: .milliseconds(300))
    guard case .result = flow.state else { Issue.record("the late load report replaced the result: \(flow.state)"); return }
    #expect(!log.everSaidSent, "the run went from preparing to its result")
}

@Test(.timeLimit(.minutes(2)))
func issue874Fix3TheServiceReportsTheLoadAfterTheStart() async {
    let transport = LoadTransport874H()
    let service = TableRecognitionService(settings: FakeTableSettings869(.default869), credentials: FakeTableKeys869(),
                                          transport: transport)
    _ = await service.recognise(makePNG869(4, 3), willSend: { await transport.note("willSend") },
                                loading: { Task { await transport.note("loading") } })
    await waitUntil874H { await transport.events.contains("loading") }
    let events = await transport.events
    #expect(Array(events.prefix(2)) == ["entered", "willSend"], "the start is reported before the load: \(events)")
    #expect(events.filter { $0 == "loading" }.count == 1 && events.filter { $0 == "started" }.count == 1, "\(events)")
}
