import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #874 fix round 1 (audit i874-r1). WI-2: the flow says the image is with the service (`working`) only once the
// service calls the transport; before that it is `preparing`, which claims nothing was sent. Every refusal before the
// transport (a stalled or failed image read, a format or size refusal, the switch, key, consent or address changed)
// ends with no transport call and never passes through `working`. WI-7: cancel while consent is being recorded, and
// the address changing between consent and send.

@MainActor private final class Clipboard874F: TableClipboardWriting {
    private(set) var writes = 0
    func writeTable(html: String, tabSeparated: String) -> Bool { writes += 1; return true }
}

/// Every state the flow passes through, in order.
@MainActor private final class StateLog874F {
    weak var flow: RecogniseTableFlow?
    private(set) var states: [RecogniseTableState] = []
    func record() { if let flow { states.append(flow.state) } }
    var everSaidSent: Bool { states.contains { if case .working = $0 { true } else { false } } }
}

/// Holds `recordConsent` until the test opens it, then writes the consent like the App does.
private actor ConsentGate874F {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private(set) var hosts: [String] = []
    private let held: Bool
    init(held: Bool) { self.held = held }
    func record(_ host: String) async {
        hosts.append(host)
        entered = true
        if held { await withCheckedContinuation { gate = $0 } }
    }
    func open() { gate?.resume(); gate = nil }
}

/// An image read the test holds, then answers or fails.
private actor ImageGate874F {
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func read() async { entered = true; await withCheckedContinuation { gate = $0 } }
    func open() { gate?.resume(); gate = nil }
}

@MainActor private struct Rig874F {
    let settings: FakeTableSettings869
    let keys: FakeTableKeys869
    let transport: RecordingTransport869
    let consent: ConsentGate874F
    let log = StateLog874F()
    let flow: RecogniseTableFlow

    init(options: TableRecognitionOptions = .default869, keys: FakeTableKeys869 = FakeTableKeys869(),
         transport: RecordingTransport869 = RecordingTransport869(), holdConsent: Bool = false) {
        let settings = FakeTableSettings869(options)
        let consent = ConsentGate874F(held: holdConsent)
        self.settings = settings
        self.keys = keys
        self.transport = transport
        self.consent = consent
        let log = self.log
        flow = RecogniseTableFlow(settings: settings, credentials: keys, transport: transport,
            clipboard: Clipboard874F(), recordConsent: { host in
                await consent.record(host)
                let current = await settings.options()
                await settings.set(TableRecognitionOptions(cloudEnabled: current.cloudEnabled, endpoint: current.endpoint,
                    consent: TableRecognitionConsentRecord(host: host, granted: true)))
            }, report: { _ in }, onChange: { log.record() })
        log.flow = flow
    }
}

private let png874F: @Sendable () async throws -> Data = { makePNG869(4, 3) }
private struct Unreadable874F: Error {}

private func waitUntil874F(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<600 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

// MARK: - WI-2: "was sent" only after the transport is called

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1WorkingIsReachedOnlyWhenTheTransportIsCalled() async {
    let transport = RecordingTransport869(gated: true)
    let rig = Rig874F(transport: transport)
    let run = rig.flow.start(image: png874F)
    await waitUntil874F { await transport.didEnter }
    #expect(rig.flow.state == .working(host: "api.deepseek.com"))
    // The run said `preparing` (nothing sent) first, and `working` exactly once, at the transport call.
    #expect(rig.log.states.first == .preparing(host: "api.deepseek.com"))
    #expect(rig.log.states.filter { $0 == .working(host: "api.deepseek.com") }.count == 1)
    #expect(rig.flow.isBusy)
    await transport.open()
    await run.value
    guard case .result = rig.flow.state else { Issue.record("expected a result, got \(rig.flow.state)"); return }
    #expect(await transport.callCount == 1)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1AStalledImageReadIsPreparingAndCancelSendsNothing() async {
    let gate = ImageGate874F()
    let rig = Rig874F()
    let run = rig.flow.start(image: { await gate.read(); return makePNG869(4, 3) })
    await waitUntil874F { await gate.entered }
    #expect(rig.flow.state == .preparing(host: "api.deepseek.com"), "nothing has been sent while the image is read")
    #expect(rig.flow.isBusy)
    rig.flow.cancel()
    #expect(rig.flow.state == .cancelled)
    await gate.open()
    await run.value
    #expect(rig.flow.state == .cancelled)
    #expect(await rig.transport.callCount == 0)
    #expect(!rig.log.everSaidSent)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1AFailedReadAFormatOrSizeRefusalNeverSaysSent() async {
    let cases: [(@Sendable () async throws -> Data, RecogniseTableState)] = [
        ({ throw Unreadable874F() }, .notSent(.unsupportedImage)),
        ({ Data("not an image".utf8) }, .notSent(.unsupportedImage)),
        ({ makePNG869(8193, 1) }, .notSent(.imageTooLarge)),
    ]
    for (image, expected) in cases {
        let rig = Rig874F()
        await rig.flow.start(image: image).value
        #expect(rig.flow.state == expected)
        #expect(await rig.transport.callCount == 0)
        #expect(!rig.log.everSaidSent, "\(expected) never showed the was-sent line")
        #expect(rig.log.states.contains(.preparing(host: "api.deepseek.com")))
    }
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1SwitchKeyOrConsentChangedBeforeSendingNeverSaysSent() async {
    // Each change lands while the consent dialog is up; the service re-reads everything before it sends.
    let changes: [(String, @Sendable (FakeTableSettings869, FakeTableKeys869) async -> Void, RecogniseTableState)] = [
        ("switch off", { settings, _ in await settings.set(.options869(enabled: false, consentHost: nil)) }, .cloudOff),
        ("key removed", { _, keys in await keys.set(nil, for: .deepSeekDefault869) }, .setupNeeded),
    ]
    for (name, change, expected) in changes {
        let rig = Rig874F(options: .options869(consentHost: nil))
        await rig.flow.start(image: png874F).value
        #expect(rig.flow.state == .consent(host: "api.deepseek.com"), "\(name)")
        await change(rig.settings, rig.keys)
        await rig.flow.answerConsent(true)?.value
        #expect(rig.flow.state == expected, "\(name)")
        #expect(await rig.transport.callCount == 0, "\(name)")
        #expect(!rig.log.everSaidSent, "\(name)")
    }
    // Consent withdrawn for the host after the checks (a declined record lands before the service reads it).
    let withdrawn = Rig874F(options: .options869(consentHost: "api.deepseek.com"))
    let gate = ImageGate874F()
    let run = withdrawn.flow.start(image: { await gate.read(); return makePNG869(4, 3) })
    await waitUntil874F { await gate.entered }
    await withdrawn.settings.set(.options869(consentHost: "api.deepseek.com", granted: false))
    await gate.open()
    await run.value
    #expect(withdrawn.flow.state == .notSent(.consentDeclined))
    #expect(await withdrawn.transport.callCount == 0)
    #expect(!withdrawn.log.everSaidSent)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1ServiceReportsTheTransportStartOnlyWhenItCallsTheTransport() async {
    let sent = TransportStarts874F()
    let service = makeService869()
    #expect(await service.recognise(makePNG869(4, 3), willSend: { await sent.mark() }) != .notSent(.unsupportedImage))
    #expect(await sent.count == 1)
    let refused = makeService869(settings: FakeTableSettings869(.options869(enabled: false)))
    #expect(await refused.recognise(makePNG869(4, 3), willSend: { await sent.mark() }) == .notSent(.cloudOff))
    #expect(await refused.recognise(Data("nope".utf8), willSend: { await sent.mark() }) == .notSent(.cloudOff))
    let unsupported = makeService869()
    #expect(await unsupported.recognise(Data("nope".utf8), willSend: { await sent.mark() }) == .notSent(.unsupportedImage))
    #expect(await sent.count == 1, "no refusal reports a transport start")
}

private actor TransportStarts874F {
    private(set) var count = 0
    func mark() { count += 1 }
}

// MARK: - WI-7: cancel while consent is recorded; the address changes between consent and send

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1CancelWhileConsentIsBeingRecordedSendsNothing() async {
    let rig = Rig874F(options: .options869(consentHost: nil), holdConsent: true)
    await rig.flow.start(image: png874F).value
    #expect(rig.flow.state == .consent(host: "api.deepseek.com"))
    let answer = rig.flow.answerConsent(true)
    await waitUntil874F { await rig.consent.entered }
    #expect(rig.flow.state == .preparing(host: "api.deepseek.com"), "recording consent has sent nothing")
    rig.flow.cancel()
    #expect(rig.flow.state == .cancelled)
    #expect(!rig.flow.isBusy)
    await rig.consent.open()
    await answer?.value
    try? await Task.sleep(for: .milliseconds(50))
    #expect(rig.flow.state == .cancelled)
    #expect(await rig.transport.callCount == 0)
    #expect(!rig.log.everSaidSent)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874Fix1AddressChangedBetweenConsentAndSendSendsNothing() async {
    let rig = Rig874F(options: .options869(consentHost: nil),
                      keys: FakeTableKeys869([.deepSeekDefault869: "sk-test-ds-0001", .custom869(): "sk-test-gw-0001"]),
                      holdConsent: true)
    await rig.flow.start(image: png874F).value
    #expect(rig.flow.state == .consent(host: "api.deepseek.com"))
    let answer = rig.flow.answerConsent(true)
    await waitUntil874F { await rig.consent.entered }
    // The address moves to another host while the consent for api.deepseek.com is written.
    await rig.settings.set(.options869(endpoint: .custom869(), consentHost: nil))
    await rig.consent.open()
    await answer?.value
    #expect(await rig.consent.hosts == ["api.deepseek.com"])
    #expect(rig.flow.state == .notSent(.consentHostChanged), "consent for one host never sends to another")
    #expect(await rig.transport.callCount == 0)
    #expect(!rig.log.everSaidSent)
}
