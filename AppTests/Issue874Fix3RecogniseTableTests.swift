import AppKit
import Testing
import MadoApplication

// #874 fix round 3 WI-1 (audit i874-confirm2 gpt F1): the working sheet says "The image was sent to …" only once the
// transport has passed its last cancellation check and starts the load. A Cancel that lands while the transport is
// still reporting the start never shows the line, in either language, and nothing is loaded.

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix3CancelWhileTheTransportReportsTheStartNeverShowsTheSentLine() async throws {
    let transport = Transport874F(holdInStart: true)
    let rig = try Rig874F(transport: transport)
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.waitUntil("the transport is reporting the start") { await transport.holdingInStart }
    // Give any change the start report queued on the main actor time to reach the sheet.
    try await Task.sleep(for: .milliseconds(100))
    let working = try #require(rig.workingAlerts.first)
    let line = try #require(ViewerRecogniseTableAdapter.sentLine(of: working)).stringValue
    let key = "The image was sent to %@. This usually takes a few seconds to over ten seconds."
    for language in ["en", "zh-Hans"] {
        let sentence = String(format: try catalogue874F(key, language), "api.deepseek.com")
        #expect(line != sentence, "\(language): the sheet says sent before the load started")
    }
    #expect(line.isEmpty, "nothing loaded yet, nothing said: \(line)")
    rig.adapter.flow?.cancel()
    await transport.openStart()
    try await rig.settle()
    #expect(rig.adapter.flow?.state == .cancelled)
    #expect(await transport.count == 0, "the transport loaded nothing")
    #expect(rig.sentLineWhenDismissed == [""], "the sheet never said the image was sent")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix3TheSentLineShowsOnceTheLoadStarts() async throws {
    let transport = Transport874F(gated: true)
    let rig = try Rig874F(transport: transport)
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.waitUntil("the load started") { await transport.waiting }
    let working = try #require(rig.workingAlerts.first)
    let sent = try #require(ViewerRecogniseTableAdapter.sentLine(of: working))
    try await rig.waitUntil("the sheet says sent") { !sent.stringValue.isEmpty }
    #expect(sent.stringValue == String(format: String(localized:
        "The image was sent to %@. This usually takes a few seconds to over ten seconds."), "api.deepseek.com"))
    await transport.open()
    try await rig.settle()
    #expect(rig.adapter.panel != nil)
}
