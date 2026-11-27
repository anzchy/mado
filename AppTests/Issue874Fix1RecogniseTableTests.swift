import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #874 fix round 1 (audit i874-r1) on the viewer: WI-1 a run belongs to the image it started on; WI-2 the working
// sheet says "was sent" only once the request is with the service; WI-3 the title-bar close is Close; WI-4 the panel's
// words fit at its minimum size in both languages and its colours follow a light/dark switch; WI-5 an accepted file
// goes as its own bytes; WI-7 the viewer window closing during consent or the request.

@MainActor private final class Motion874F: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private actor Settings874F: TableRecognitionSettings {
    var current: TableRecognitionOptions
    init(_ options: TableRecognitionOptions) { current = options }
    func set(_ options: TableRecognitionOptions) { current = options }
    func options() async -> TableRecognitionOptions { current }
}

/// The key; from the second read on (the service's own check) it can be held until the test opens it, or be gone.
private actor Keys874F: TableRecognitionCredentialStore {
    private var reads = 0
    private let holdSecondRead: Bool
    private let goneOnSecondRead: Bool
    private var gate: CheckedContinuation<Void, Never>?
    init(holdSecondRead: Bool = false, goneOnSecondRead: Bool = false) {
        self.holdSecondRead = holdSecondRead; self.goneOnSecondRead = goneOnSecondRead
    }
    var holding: Bool { gate != nil }
    func open() { gate?.resume(); gate = nil }
    func accessKey(for endpoint: TableRecognitionEndpoint) async -> String? {
        reads += 1
        guard reads > 1 else { return "sk-test-0001" }
        if holdSecondRead { await withCheckedContinuation { gate = $0 } }
        return goneOnSecondRead ? nil : "sk-test-0001"
    }
}

private actor Transport874F: HTTPTransport {
    private(set) var count = 0
    private(set) var requests: [URLRequest] = []
    private var gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private let reply: HTTPResponse
    init(gated: Bool = false) {
        self.gated = gated
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [[
            "index": 0, "message": ["role": "assistant", "content": "| A | B |\n|---|---|\n| 1 | 2 |"],
            "finish_reason": "stop"]]])
        reply = HTTPResponse(statusCode: 200, body: body)
    }
    var waiting: Bool { gate != nil }
    func open() { gated = false; gate?.resume(); gate = nil }
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        count += 1
        requests.append(request)
        if gated { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        return reply
    }
    /// The data URL's media type and its bytes.
    func lastImage() -> (String, Data)? {
        guard let body = requests.last?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = object["messages"] as? [[String: Any]],
              let parts = messages.first?["content"] as? [[String: Any]],
              let part = parts.first(where: { $0["type"] as? String == "image_url" }),
              let url = (part["image_url"] as? [String: Any])?["url"] as? String,
              let semicolon = url.firstIndex(of: ";"), let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return (String(url[url.index(url.startIndex, offsetBy: 5)..<semicolon]), data)
    }
}

private actor Leases874F: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease {
        switch request { case .fileGrant(let url), .root(_, let url): AccessLease(url: url, rootID: nil) }
    }
    func release(_ lease: AccessLease) {}
}

/// One item per file, so opening another file is another image.
private actor Pipeline874F: ImagePipeline {
    let item = ItemID.ephemeral(UUID())
    let image: CGImage
    init(image: CGImage) { self.image = image }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize, renderKey: RenderKey(itemID: item,
            revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) -> DecodedImage {
        DecodedImage(image: image, sourcePixelSize: CGSize(width: image.width, height: image.height),
                     revision: FileRevision(byteCount: 1, modificationDate: nil), itemID: item)
    }
}

private func picture874F(_ width: Int = 6, _ height: Int = 4) throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try #require(context.makeImage())
}

private func options874F(consent: Bool) -> TableRecognitionOptions {
    TableRecognitionOptions(cloudEnabled: true, endpoint: .deepSeek,
                            consent: consent ? TableRecognitionConsentRecord(host: "api.deepseek.com", granted: true) : nil)
}

@MainActor private final class Rig874F {
    let controller: CanvasWindowController
    let window: NSWindow
    let board = NSPasteboard(name: .init("mado.issue874fix1.\(UUID().uuidString)"))
    let transport: Transport874F
    var consentAlerts: [NSAlert] = []
    /// The consent sheet's answer, held until the test gives it.
    var answerConsent: (@MainActor (Bool) -> Void)?
    var dismissedConsent: [NSAlert] = []
    var workingAlerts: [NSAlert] = []
    var dismissedWorking: [NSAlert] = []
    /// The sent line's text each time a working sheet ended.
    var sentLineWhenDismissed: [String] = []
    var notices: [NSAlert] = []
    var adapter: ViewerRecogniseTableAdapter { controller.recogniseTableAdapter }

    init(options: TableRecognitionOptions = options874F(consent: true), keys: Keys874F = Keys874F(),
         transport: Transport874F = Transport874F()) throws {
        _ = NSApplication.shared
        let unavailable = Task<AccessServices, Error> { throw CancellationError() }
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
            motionPolicy: MotionPolicy(source: Motion874F()))
        window = try #require(controller.window)
        self.transport = transport
        let settings = Settings874F(options)
        board.clearContents()
        board.setString("before", forType: .string)
        let adapter = controller.recogniseTableAdapter
        adapter.pasteboard = board
        adapter.makeFlow = { clipboard, onChange in
            RecogniseTableFlow(settings: settings, credentials: keys, transport: transport, clipboard: clipboard,
                recordConsent: { host in
                    let current = await settings.options()
                    await settings.set(TableRecognitionOptions(cloudEnabled: current.cloudEnabled,
                        endpoint: current.endpoint, consent: TableRecognitionConsentRecord(host: host, granted: true)))
                }, report: { _ in }, onChange: onChange)
        }
        adapter.presentConsent = { [unowned self] _, alert, answer in
            consentAlerts.append(alert)
            answerConsent = answer
        }
        adapter.dismissConsent = { [unowned self] _, alert in dismissedConsent.append(alert) }
        adapter.presentWorking = { [unowned self] _, alert, _ in workingAlerts.append(alert) }
        adapter.dismissWorking = { [unowned self] _, alert in
            dismissedWorking.append(alert)
            sentLineWhenDismissed.append(ViewerRecogniseTableAdapter.sentLine(of: alert)?.stringValue ?? "<none>")
        }
        adapter.presentNotice = { [unowned self] _, alert in notices.append(alert) }
    }

    func installPicture() throws {
        controller.installImage(DecodedImage(image: try picture874F(), sourcePixelSize: CGSize(width: 6, height: 4)),
                                fileURL: URL(fileURLWithPath: "/tmp/表格.png"))
    }

    /// Opens `url` through the viewer's loader, as navigation does, and waits until it is shown.
    func open(_ url: URL, pipeline: any ImagePipeline, item: ItemID) async throws {
        controller.session.openImage(url, maximumPixelSize: 64) {
            try await AccessImageSource.open(.fileGrant(url), access: Leases874F(), pipeline: pipeline)
        }
        try await waitUntil("\(url.lastPathComponent) is shown") {
            controller.session.imageLoader.phase == .settled
                && controller.session.imageLoader.presented?.key.itemID == item
                && controller.canvas.backdropFrame.image != nil
        }
    }

    func close() {
        adapter.panel?.close()
        window.close()
        board.releaseGlobally()
    }

    func waitUntil(_ what: String, _ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<600 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out waiting for \(what)")
    }

    func settle() async throws {
        var seen: Task<Void, Never>?
        while let task = adapter.runTask, task != seen {
            seen = task
            await task.value
        }
        try await Task.sleep(for: .milliseconds(100))
    }
}

// MARK: - WI-1: a run belongs to the image it started on

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1NavigatingAwayMidRequestShowsNoPanelAndCopiesNothing() async throws {
    let transport = Transport874F(gated: true)
    let rig = try Rig874F(transport: transport)
    defer { rig.close() }
    let a = Pipeline874F(image: try picture874F()), b = Pipeline874F(image: try picture874F(8, 5))
    try await rig.open(URL(fileURLWithPath: "/tmp/874-A.png"), pipeline: a, item: a.item)
    rig.adapter.start()
    try await rig.waitUntil("the request for A is with the service") { await transport.waiting }
    try await rig.open(URL(fileURLWithPath: "/tmp/874-B.png"), pipeline: b, item: b.item)
    await transport.open()
    try await rig.settle()
    #expect(rig.adapter.panel == nil, "no result panel for A over B")
    #expect(rig.board.string(forType: .string) == "before")
    #expect(rig.adapter.flow?.state == .idle)
    #expect(rig.dismissedWorking.count == 1, "the working sheet for A ends")
    #expect(rig.notices.isEmpty)
    #expect(rig.adapter.canStart, "B can be recognised")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1NavigatingAwayAtConsentEndsTheRunAndALateAgreeSendsNothing() async throws {
    let rig = try Rig874F(options: options874F(consent: false))
    defer { rig.close() }
    let a = Pipeline874F(image: try picture874F()), b = Pipeline874F(image: try picture874F(8, 5))
    try await rig.open(URL(fileURLWithPath: "/tmp/874-A.png"), pipeline: a, item: a.item)
    rig.adapter.start()
    try await rig.waitUntil("the consent sheet for A") { rig.answerConsent != nil }
    let lateAnswer = try #require(rig.answerConsent)
    try await rig.open(URL(fileURLWithPath: "/tmp/874-B.png"), pipeline: b, item: b.item)
    try await rig.waitUntil("the consent sheet for A ends") { !rig.dismissedConsent.isEmpty }
    #expect(rig.adapter.flow?.state == .idle)
    lateAnswer(true)
    try await rig.settle()
    #expect(await rig.transport.count == 0, "agreeing for A after moving to B sends nothing")
    #expect(rig.adapter.panel == nil && rig.workingAlerts.isEmpty)
    // B asks again.
    rig.answerConsent = nil
    rig.adapter.start()
    try await rig.waitUntil("the consent sheet for B") { rig.answerConsent != nil }
    #expect(rig.consentAlerts.count == 2)
}

// MARK: - WI-2: "The image was sent to …" only once the request is with the service

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1TheWorkingSheetSaysSentOnlyOnceTheRequestIsWithTheService() async throws {
    let keys = Keys874F(holdSecondRead: true)
    let transport = Transport874F(gated: true)
    let rig = try Rig874F(keys: keys, transport: transport)
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.waitUntil("the service checks the key") { await keys.holding }
    let working = try #require(rig.workingAlerts.first)
    #expect(working.messageText == String(localized: "Recognising table…"))
    let sent = try #require(ViewerRecogniseTableAdapter.sentLine(of: working))
    #expect(sent.stringValue.isEmpty, "nothing has been sent yet")
    #expect(working.informativeText.isEmpty)
    #expect(working.buttons.map(\.title) == [String(localized: "Cancel")])
    await keys.open()
    try await rig.waitUntil("the request is with the service") { await transport.waiting }
    try await rig.waitUntil("the sheet says sent") { !sent.stringValue.isEmpty }
    #expect(sent.stringValue == String(format: String(localized:
        "The image was sent to %@. This usually takes a few seconds to over ten seconds."), "api.deepseek.com"))
    #expect(rig.workingAlerts.count == 1, "the same sheet, now saying sent")
    await transport.open()
    try await rig.settle()
    #expect(rig.adapter.panel != nil)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1ARefusalBeforeSendingNeverShowsTheSentLine() async throws {
    let rig = try Rig874F(keys: Keys874F(goneOnSecondRead: true))
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.settle()
    #expect(await rig.transport.count == 0)
    #expect(rig.adapter.flow?.state == .setupNeeded)
    #expect(rig.workingAlerts.count == 1 && rig.dismissedWorking.count == 1)
    #expect(rig.sentLineWhenDismissed == [""], "the sheet never said the image was sent")
    #expect(rig.notices.count == 1)
}

// MARK: - WI-3: the title-bar close button is Close

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1TheTitleBarCloseRunsTheSamePathAsCloseAndEsc() async throws {
    for way in ["title bar", "Esc"] {
        let rig = try Rig874F()
        defer { rig.close() }
        try rig.installPicture()
        rig.adapter.start()
        try await rig.settle()
        let panel = try #require(rig.adapter.panel, "\(way)")
        if way == "title bar" { panel.performClose(nil) } else { panel.cancelOperation(nil) }
        #expect(!panel.isVisible, "\(way)")
        #expect(rig.adapter.panel == nil, "\(way)")
        #expect(rig.adapter.flow?.state == .idle, "\(way)")
        #expect(rig.window.firstResponder === rig.controller.canvas, "\(way): focus goes back to the image")
        #expect(rig.adapter.canStart, "\(way)")
        #expect(rig.board.string(forType: .string) == "before")
    }
}

// MARK: - WI-4: fit at the minimum size in both languages; colours follow the appearance

private func catalogue874F(_ key: String, _ language: String) throws -> String {
    guard language != "en" else { return key }
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let entry = try #require((root["strings"] as? [String: Any])?[key] as? [String: Any], "missing \(key)")
    let unit = ((entry["localizations"] as? [String: Any])?[language] as? [String: Any])?["stringUnit"] as? [String: Any]
    return try #require(unit?["value"] as? String, "\(key) has no \(language)")
}

@MainActor @Test(.timeLimit(.minutes(3)), arguments: ["en", "zh-Hans"])
func issue874Fix1PanelWordsFitAtTheMinimumSizeInBothLanguages(_ locale: String) throws {
    _ = NSApplication.shared
    let result = RecognisedTableResult(table: RecognisedTable(rows: [["A", "B"], ["1", "2"]]), serviceName: "DeepSeek")
    let panel = RecognisedTablePanel(result: result, sourceImage: try picture874F())
    defer { panel.close() }
    let test = "issue874Fix1PanelWordsFitAtTheMinimumSizeInBothLanguages-\(locale)"
    panel.footerNote.stringValue = try catalogue874F(
        "Pasted into Word it is a complete table; pasted as plain text it is tab-separated text.", locale)
    panel.copiedLabel.stringValue = try catalogue874F("Table copied", locale)
    panel.hintLabel.stringValue = try catalogue874F("Check the text and the rows and columns.", locale)
    panel.copyButton.title = try catalogue874F("Copy Table", locale)
    panel.closeButton.title = try catalogue874F("Close", locale)
    panel.copiedLabel.isHidden = false
    panel.setContentSize(RecognisedTablePanel.minimumContentSize)
    let content = try #require(panel.contentView)
    content.layoutSubtreeIfNeeded()
    #expect(content.bounds.size == RecognisedTablePanel.minimumContentSize)
    // The note and the hint hug their text, so each is measured against the room it has: the note up to the copied
    // label (8 pt gap), the hint across the band (16 pt each side).
    let noteRoom = NSSize(width: panel.copiedLabel.frame.minX - 8 - panel.footerNote.frame.minX,
                          height: panel.footerNote.frame.height)
    let hintRoom = NSSize(width: content.bounds.width - 32, height: panel.hintLabel.frame.height)
    for (label, room) in [(panel.footerNote, noteRoom), (panel.hintLabel, hintRoom)] {
        expectLayoutFits(layoutLabelMeasure(label.stringValue, font: try #require(label.font), frame: room),
                         view: label, shown: label.stringValue, locale: locale, test: test)
    }
    // Single-line controls that keep their own width: the copied label and both buttons.
    let copiedFont = try #require(panel.copiedLabel.font)
    let copiedWidth = (panel.copiedLabel.stringValue as NSString).size(withAttributes: [.font: copiedFont]).width
    expectLayoutFits(layoutButtonMeasure(intrinsicWidth: panel.copiedLabel.intrinsicContentSize.width,
                                         textWidth: copiedWidth, frame: panel.copiedLabel.frame.size),
                     view: panel.copiedLabel, shown: panel.copiedLabel.stringValue, locale: locale, test: test)
    for button in [panel.copyButton, panel.closeButton] {
        let font = try #require(button.font)
        let textWidth = (button.title as NSString).size(withAttributes: [.font: font]).width
        expectLayoutFits(layoutButtonMeasure(intrinsicWidth: button.intrinsicContentSize.width, textWidth: textWidth,
                                             frame: button.frame.size),
                         view: button, shown: button.title, locale: locale, test: test)
    }
    #expect(panel.footerNote.frame.maxX <= panel.copiedLabel.frame.minX - 8 + 0.5, "the note never runs under the label")
}

@MainActor private func resolved874F(_ color: DesignColor, _ name: NSAppearance.Name) throws -> CGColor {
    var cgColor: CGColor?
    try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance { cgColor = color.nsColor.cgColor }
    return try #require(cgColor)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1PanelColoursFollowALightDarkSwitchWhileOpen() async throws {
    let rig = try Rig874F()
    defer { rig.close() }
    try rig.installPicture()
    rig.adapter.start()
    try await rig.settle()
    let panel = try #require(rig.adapter.panel)
    let content = try #require(panel.contentView)
    #expect(try resolved874F(.popoverBackground, .aqua) != resolved874F(.popoverBackground, .darkAqua))
    for name in [NSAppearance.Name.aqua, .darkAqua, .aqua] {
        panel.appearance = NSAppearance(named: name)
        content.display()
        #expect(content.layer?.backgroundColor == (try resolved874F(.popoverBackground, name)), "\(name.rawValue)")
        #expect(panel.sourceColumn.layer?.backgroundColor == (try resolved874F(.sidebarBackground, name)),
                "\(name.rawValue)")
    }
}

// MARK: - WI-5: an accepted file goes as its own bytes; anything else as the PNG

private func file874F(_ type: UTType, name: String) throws -> (URL, Data) {
    let buffer = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try picture874F(40, 30), nil)
    #expect(CGImageDestinationFinalize(destination))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mado-874f-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent(name)
    try (buffer as Data).write(to: url)
    return (url, buffer as Data)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1AnAcceptedFileGoesAsItsOwnBytesAndOtherFormatsAsPNG() async throws {
    for (type, name, sentAsIs) in [(UTType.jpeg, "table.jpg", true), (UTType.tiff, "table.tiff", false)] {
        let transport = Transport874F()
        let rig = try Rig874F(transport: transport)
        defer { rig.close() }
        let (url, bytes) = try file874F(type, name: name)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let pipeline = ImageIOPipeline()
        rig.controller.session.openImage(url, maximumPixelSize: 64) {
            try await AccessImageSource.open(.fileGrant(url), access: Leases874F(), pipeline: pipeline)
        }
        try await rig.waitUntil("\(name) is shown") {
            rig.controller.session.imageLoader.phase == .settled && rig.controller.canvas.backdropFrame.image != nil
        }
        rig.adapter.start()
        try await rig.settle()
        let image = try #require(await transport.lastImage(), "\(name)")
        if sentAsIs {
            #expect(image.0 == "image/jpeg")
            #expect(image.1 == bytes, "the file's own bytes")
        } else {
            #expect(image.0 == "image/png", "a TIFF goes as the PNG re-encode")
            #expect(TableImageSize874F.of(image.1).map { $0.0 == 40 && $0.1 == 30 } == true)
        }
        #expect(rig.adapter.panel != nil, "\(name)")
    }
}

private enum TableImageSize874F {
    static func of(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}

// MARK: - WI-7: the viewer window closes during consent, and during the request

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1ClosingTheViewerAtConsentSendsNothingEvenIfAgreedLate() async throws {
    let rig = try Rig874F(options: options874F(consent: false))
    try rig.installPicture()
    rig.adapter.start()
    try await rig.waitUntil("the consent sheet") { rig.answerConsent != nil }
    let lateAnswer = try #require(rig.answerConsent)
    rig.window.close()
    lateAnswer(true)
    try await rig.settle()
    #expect(await rig.transport.count == 0)
    #expect(rig.adapter.flow == nil && rig.adapter.panel == nil)
    #expect(rig.workingAlerts.isEmpty && rig.notices.isEmpty)
    #expect(rig.board.string(forType: .string) == "before")
    rig.board.releaseGlobally()
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874Fix1ClosingTheViewerDuringTheRequestCancelsItAndOpensNothing() async throws {
    let transport = Transport874F(gated: true)
    let rig = try Rig874F(transport: transport)
    try rig.installPicture()
    rig.adapter.start()
    try await rig.waitUntil("the request is with the service") { await transport.waiting }
    let run = rig.adapter.runTask
    rig.window.close()
    #expect(rig.dismissedWorking.count == 1)
    await transport.open()
    await run?.value
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.count == 1, "never retried")
    #expect(rig.adapter.flow == nil && rig.adapter.panel == nil)
    #expect(rig.notices.isEmpty)
    #expect(rig.board.string(forType: .string) == "before")
    rig.board.releaseGlobally()
}
