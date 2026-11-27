import Foundation
import Testing
import MadoCore
@testable import MadoApplication

// #874 WI-1: the Recognise Table flow model (spec #866 testing decisions: setup needed, consent, working, result,
// cancelled). The real TableRecognitionService runs underneath with the #869 fakes, so "sends nothing" is counted
// at the transport. The clipboard is a recorder: nothing may be written except by Copy Table.

@MainActor private final class Clipboard874: TableClipboardWriting {
    private(set) var writes: [(html: String, tabSeparated: String)] = []
    var accepts = true
    func writeTable(html: String, tabSeparated: String) -> Bool {
        guard accepts else { return false }
        writes.append((html, tabSeparated))
        return true
    }
}

/// Consent answers the flow records, per host, applied to the settings the service reads next.
private actor ConsentLog874 {
    private(set) var hosts: [String] = []
    func record(_ host: String) { hosts.append(host) }
}

@MainActor private struct Rig874 {
    let settings: FakeTableSettings869
    let keys: FakeTableKeys869
    let transport: RecordingTransport869
    let clipboard = Clipboard874()
    let consents = ConsentLog874()
    let flow: RecogniseTableFlow

    init(options: TableRecognitionOptions = .default869, keys: FakeTableKeys869 = FakeTableKeys869(),
         transport: RecordingTransport869 = RecordingTransport869()) {
        let settings = FakeTableSettings869(options)
        let consents = self.consents
        self.settings = settings
        self.keys = keys
        self.transport = transport
        flow = RecogniseTableFlow(settings: settings, credentials: keys, transport: transport, clipboard: clipboard,
            recordConsent: { host in
                await consents.record(host)
                let current = await settings.options()
                await settings.set(TableRecognitionOptions(cloudEnabled: current.cloudEnabled, endpoint: current.endpoint,
                    consent: TableRecognitionConsentRecord(host: host, granted: true)))
            }, report: { _ in })
    }
}

private let image874: @Sendable () async throws -> Data = { makePNG869(4, 3) }

private func waitUntil874(_ condition: @MainActor () async -> Bool) async {
    for _ in 0..<500 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowWithoutKeyNeedsSetupAndSendsNothing() async {
    let rig = Rig874(keys: FakeTableKeys869([:]))
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .setupNeeded)
    #expect(await rig.transport.callCount == 0)
    #expect(rig.clipboard.writes.isEmpty)
    #expect(await rig.consents.hosts.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowWithUnusableCustomAddressNeedsSetup() async {
    let endpoint = TableRecognitionEndpoint.custom869("", model: "vision-x")
    let rig = Rig874(options: .options869(endpoint: endpoint, consentHost: nil),
                     keys: FakeTableKeys869([endpoint: "sk-1"]))
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .setupNeeded)
    #expect(await rig.transport.callCount == 0)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowWithSwitchOffSendsNothingEvenWithKeyAndConsent() async {
    let rig = Rig874(options: .options869(enabled: false))
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .cloudOff)
    #expect(await rig.transport.callCount == 0)
    #expect(rig.clipboard.writes.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)), arguments: ["notAsked", "declined", "otherHost"])
func issue874FlowAsksConsentNamingTheRealHostBeforeSending(record: String) async {
    let options: TableRecognitionOptions = switch record {
    case "notAsked": .options869(consentHost: nil)
    case "declined": .options869(granted: false)
    default: .options869(consentHost: "aip.baidubce.com")
    }
    let rig = Rig874(options: options)
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .consent(host: "api.deepseek.com"))
    #expect(rig.flow.isBusy)
    #expect(await rig.transport.callCount == 0)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowDecliningConsentSendsAndRecordsNothing() async {
    let rig = Rig874(options: .options869(consentHost: nil))
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .consent(host: "api.deepseek.com"))
    await rig.flow.answerConsent(false)?.value
    #expect(rig.flow.state == .idle)
    #expect(!rig.flow.isBusy)
    #expect(await rig.transport.callCount == 0)
    #expect(await rig.consents.hosts.isEmpty)
    #expect(rig.clipboard.writes.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowAgreeingRecordsConsentForThatHostThenShowsTheResultWithoutCopying() async {
    let rig = Rig874(options: .options869(consentHost: nil))
    await rig.flow.start(image: image874).value
    await rig.flow.answerConsent(true)?.value
    #expect(await rig.consents.hosts == ["api.deepseek.com"])
    #expect(await rig.transport.callCount == 1)
    let expected = RecognisedTableResult(table: RecognisedTable(rows: [["A", "B"], ["1", "2"]]), serviceName: "DeepSeek")
    #expect(rig.flow.state == .result(expected))
    #expect(!rig.flow.isBusy)
    // No auto-copy (story 43).
    #expect(rig.clipboard.writes.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowWithConsentGoesStraightToWorkingThenResult() async {
    let transport = RecordingTransport869(gated: true)
    let rig = Rig874(transport: transport)
    let run = rig.flow.start(image: image874)
    await waitUntil874 { await transport.didEnter }
    #expect(rig.flow.state == .working(host: "api.deepseek.com"))
    #expect(rig.flow.isBusy)
    await transport.open()
    await run.value
    guard case .result(let result) = rig.flow.state else {
        Issue.record("expected a result, got \(rig.flow.state)"); return
    }
    #expect(result.table.rowCount == 2 && result.table.columnCount == 2)
    #expect(result.serviceName == "DeepSeek")
    #expect(!result.copied)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowNamesACustomServiceByItsHost() async {
    let endpoint = TableRecognitionEndpoint.custom869("https://gw.example.com/v1", model: "vision-x")
    let rig = Rig874(options: .options869(endpoint: endpoint, consentHost: "gw.example.com"),
                     keys: FakeTableKeys869([endpoint: "sk-1"]))
    await rig.flow.start(image: image874).value
    guard case .result(let result) = rig.flow.state else {
        Issue.record("expected a result, got \(rig.flow.state)"); return
    }
    #expect(result.serviceName == "gw.example.com")
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowCancelStopsTheRequestNeverRetriesAndLeavesTheClipboard() async {
    let transport = RecordingTransport869(gated: true)
    let rig = Rig874(transport: transport)
    let run = rig.flow.start(image: image874)
    await waitUntil874 { await transport.didEnter }
    rig.flow.cancel()
    #expect(rig.flow.state == .cancelled)
    #expect(!rig.flow.isBusy)
    await transport.open()
    await run.value
    // The reply came back after Cancel: still cancelled, and the cancellation reached the transport call.
    #expect(rig.flow.state == .cancelled)
    #expect(await transport.sawCancellation)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(await transport.callCount == 1)
    #expect(rig.clipboard.writes.isEmpty)
    #expect(!rig.flow.copyTable())
    #expect(rig.clipboard.writes.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowCancelAtConsentSendsNothing() async {
    let rig = Rig874(options: .options869(consentHost: nil))
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .consent(host: "api.deepseek.com"))
    rig.flow.cancel()
    #expect(rig.flow.state == .idle)
    #expect(await rig.transport.callCount == 0)
    #expect(await rig.consents.hosts.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowCopyTableWritesHTMLAndTabSeparatedTextInOneWrite() async throws {
    let reply = "| 公司 | 产品 |\n|---|---|\n| Sensoror | <b>MEMS</b> |"
    let transport = RecordingTransport869(fallback: .response(HTTPResponse(statusCode: 200,
                                                                         body: chatReply869(content: reply))))
    let rig = Rig874(transport: transport)
    await rig.flow.start(image: image874).value
    guard case .result(let result) = rig.flow.state else {
        Issue.record("expected a result, got \(rig.flow.state)"); return
    }
    let payload = try TableClipboardPayload.build(from: result.table)
    #expect(rig.flow.copyTable())
    #expect(rig.clipboard.writes.count == 1)
    #expect(rig.clipboard.writes.first?.html == payload.html)
    #expect(rig.clipboard.writes.first?.tabSeparated == "公司\t产品\nSensoror\t<b>MEMS</b>")
    #expect(rig.flow.state == .result(RecognisedTableResult(table: result.table, serviceName: "DeepSeek", copied: true)))
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowFailedCopyIsNotReportedAsCopied() async {
    let rig = Rig874()
    await rig.flow.start(image: image874).value
    rig.clipboard.accepts = false
    #expect(!rig.flow.copyTable())
    guard case .result(let result) = rig.flow.state else {
        Issue.record("expected a result, got \(rig.flow.state)"); return
    }
    #expect(!result.copied)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowKeepsTheModelOpenForFailuresAndRefusals() async {
    let failing = Rig874(transport: RecordingTransport869(fallback: .response(HTTPResponse(statusCode: 401, body: Data()))))
    await failing.flow.start(image: image874).value
    #expect(failing.flow.state == .failed(.keyRejected))
    #expect(failing.clipboard.writes.isEmpty)

    let tooLarge = Rig874()
    await tooLarge.flow.start(image: { makePNG869(8193, 1) }).value
    #expect(tooLarge.flow.state == .notSent(.imageTooLarge))
    #expect(await tooLarge.transport.callCount == 0)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowStartWhileBusyIsIgnoredAndCloseEndsTheRun() async {
    let transport = RecordingTransport869(gated: true)
    let rig = Rig874(transport: transport)
    let run = rig.flow.start(image: image874)
    await waitUntil874 { await transport.didEnter }
    await rig.flow.start(image: image874).value
    #expect(rig.flow.state == .working(host: "api.deepseek.com"))
    rig.flow.close()
    #expect(rig.flow.state == .idle)
    await transport.open()
    await run.value
    #expect(rig.flow.state == .idle)
    #expect(await transport.callCount == 1)
}

// Coverage for paths already implemented in WI-1 (the gate's 100 % lines and functions): an image that cannot be
// read is not sent, a read cancelled under the flow is a cancel, and the default diagnostic sink is usable.

private struct Unreadable874: Error {}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowImageThatCannotBeReadIsNotSent() async {
    let rig = Rig874()
    await rig.flow.start(image: { throw Unreadable874() }).value
    #expect(rig.flow.state == .notSent(.unsupportedImage))
    #expect(await rig.transport.callCount == 0)
    #expect(rig.clipboard.writes.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowImageReadCancelledIsACancelThatSendsNothing() async {
    let rig = Rig874()
    await rig.flow.start(image: { throw CancellationError() }).value
    #expect(rig.flow.state == .cancelled)
    #expect(await rig.transport.callCount == 0)
}

@MainActor @Test(.timeLimit(.minutes(2)))
func issue874FlowWithTheDefaultDiagnosticSinkStillRuns() async {
    let settings = FakeTableSettings869(.default869)
    let transport = RecordingTransport869()
    let flow = RecogniseTableFlow(settings: settings, credentials: FakeTableKeys869(), transport: transport,
                                  clipboard: Clipboard874(), recordConsent: { _ in })
    await flow.start(image: image874).value
    guard case .result(let result) = flow.state else {
        Issue.record("expected a result, got \(flow.state)"); return
    }
    #expect(result.table.rowCount == 2)
    #expect(await transport.callCount == 1)
}
