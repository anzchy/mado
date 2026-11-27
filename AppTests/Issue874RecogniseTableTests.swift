import AppKit
import CryptoKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

// #874 WI-2/WI-3: View › 识别表格… on the viewer's image (state 41 `consent`, `working`, `result`, `copied`;
// `design/prototypes/picsee-browser/states/table-flow.html`, manifest sha256 pinned below). The consent sheet names
// the real host; Cancel in the working sheet stops the request and never retries; the result panel shows the
// original image beside the table and copies only on Copy Table, as HTML and tab-separated text on one item.

@MainActor private final class Motion874: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private actor Settings874: TableRecognitionSettings {
    var current: TableRecognitionOptions
    init(_ options: TableRecognitionOptions) { current = options }
    func set(_ options: TableRecognitionOptions) { current = options }
    func options() async -> TableRecognitionOptions { current }
}

private actor Keys874: TableRecognitionCredentialStore {
    let key: String?
    init(_ key: String?) { self.key = key }
    func accessKey(for endpoint: TableRecognitionEndpoint) async -> String? { key }
}

private actor Transport874: HTTPTransport {
    private(set) var count = 0
    private var gated: Bool
    private var gate: CheckedContinuation<Void, Never>?
    let reply: HTTPResponse
    init(gated: Bool = false, content: String = "| 公司名称 | 主要产品 |\n|---|---|\n| Sensoror | MEMS <陀螺仪> |") {
        self.gated = gated
        let body = try! JSONSerialization.data(withJSONObject: ["choices": [[
            "index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]])
        reply = HTTPResponse(statusCode: 200, body: body)
    }
    var waiting: Bool { gate != nil }
    func open() { gated = false; gate?.resume(); gate = nil }
    func send(_ request: URLRequest, to destination: HTTPDestination) async throws -> HTTPResponse {
        count += 1
        if gated { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        return reply
    }
}

private let deepSeek874 = TableRecognitionEndpoint.deepSeek

private func options874(enabled: Bool = true, consent: Bool = false) -> TableRecognitionOptions {
    TableRecognitionOptions(cloudEnabled: enabled, endpoint: deepSeek874,
                            consent: consent ? TableRecognitionConsentRecord(host: "api.deepseek.com", granted: true) : nil)
}

/// A viewer window with a shown image, its adapter wired to fakes, and every sheet recorded instead of shown.
@MainActor private final class Rig874App {
    let controller: CanvasWindowController
    let window: NSWindow
    let board = NSPasteboard(name: .init("mado.issue874.\(UUID().uuidString)"))
    let settings: Settings874
    let transport: Transport874
    var consentAlerts: [NSAlert] = []
    var consentAnswer = true
    var workingAlerts: [NSAlert] = []
    var dismissedWorking: [NSAlert] = []
    var cancelWorking: (@MainActor () -> Void)?
    var notices: [NSAlert] = []
    var adapter: ViewerRecogniseTableAdapter { controller.recogniseTableAdapter }

    init(options: TableRecognitionOptions = options874(), key: String? = "sk-test-0001",
         transport: Transport874 = Transport874()) throws {
        _ = NSApplication.shared
        let unavailable = Task<AccessServices, Error> { throw CancellationError() }
        controller = CanvasWindowController(pipeline: ImageIOPipeline(),
            preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
            motionPolicy: MotionPolicy(source: Motion874()))
        window = try #require(controller.window)
        let settings = Settings874(options)
        self.settings = settings
        self.transport = transport
        board.clearContents()
        board.setString("before", forType: .string)
        let adapter = controller.recogniseTableAdapter
        adapter.pasteboard = board
        adapter.makeFlow = { clipboard, onChange in
            RecogniseTableFlow(settings: settings, credentials: Keys874(key), transport: transport,
                clipboard: clipboard, recordConsent: { host in
                    let current = await settings.options()
                    await settings.set(TableRecognitionOptions(cloudEnabled: current.cloudEnabled,
                        endpoint: current.endpoint, consent: TableRecognitionConsentRecord(host: host, granted: true)))
                }, report: { _ in }, onChange: onChange)
        }
        adapter.presentConsent = { [unowned self] _, alert, answer in
            consentAlerts.append(alert)
            answer(consentAnswer)
        }
        adapter.presentWorking = { [unowned self] _, alert, onCancel in
            workingAlerts.append(alert)
            cancelWorking = onCancel
        }
        adapter.dismissWorking = { [unowned self] _, alert in dismissedWorking.append(alert) }
        adapter.presentNotice = { [unowned self] _, alert in notices.append(alert) }
        let context = try #require(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 24,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 6, height: 4))
        let image = DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 6, height: 4))
        controller.installImage(image, fileURL: URL(fileURLWithPath: "/tmp/表格截图.png"))
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

    /// Starts from the menu action and awaits every task the run hands on (the checks, then the request after
    /// the consent answer).
    func runToEnd() async throws {
        adapter.start()
        var seen: Task<Void, Never>?
        while let task = adapter.runTask, task != seen {
            seen = task
            await task.value
        }
    }
}

private func catalogue874(_ key: String, _ language: String) throws -> String {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let strings = try #require(root["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any], "missing catalogue key \(key)")
    let localizations = try #require(entry["localizations"] as? [String: Any])
    let localized = try #require(localizations[language] as? [String: Any], "\(key) has no \(language)")
    let unit = try #require(localized["stringUnit"] as? [String: Any])
    return try #require(unit["value"] as? String)
}

private func stateFile874() throws -> String {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("design/prototypes/picsee-browser/states/table-flow.html")
    let data = try Data(contentsOf: file)
    // manifest.json `table-flow` sha256: the parity rows below are read against this exact page.
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(digest == "897cf6c2a7c89977c8418b7c7f5b054550b0691e9366acb3dfe0cfbb1c8b99b3")
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Menu

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874ViewMenuOffersRecogniseTableAfterRecogniseTextWithEllipsisAndNoShortcut() throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: Motion874()))
    let window = try #require(controller.window)
    defer { window.close(); NSApp.mainMenu = previousMenu }
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: {}, windowController: { controller })
    defer { withExtendedLifetime(menu) {} }
    let view = try #require(NSApp.mainMenu?.items.first { $0.title == String(localized: "View") }?.submenu)
    let text = try #require(view.items.firstIndex { $0.accessibilityIdentifier() == "viewer.recognise-text.menu" })
    let index = try #require(view.items.firstIndex { $0.accessibilityIdentifier() == "viewer.recognise-table.menu" })
    #expect(index == text + 1, "识别表格 sits next to 识别文字 (spec #866 story 32)")
    let item = view.items[index]
    #expect(item.title == String(localized: "Recognise Table…"))
    #expect(item.title.hasSuffix("…"))
    #expect(item.keyEquivalent.isEmpty, "no shortcut until T9")
    #expect(!menu.validateMenuItem(item), "no image shown: unavailable")
    let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8, bytesPerRow: 12,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    controller.installImage(DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 3, height: 2)),
                            fileURL: URL(fileURLWithPath: "/tmp/table.png"))
    #expect(menu.validateMenuItem(item))
}

// MARK: - Clipboard

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874TablePasteboardWritesHTMLAndTabSeparatedTextOnOneItem() throws {
    let board = NSPasteboard(name: .init("mado.issue874.board.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("before", forType: .string)
    let table = RecognisedTable(rows: [["公司名称", "主要产品"], ["Sensonor", "MEMS <陀螺仪>"]])
    let payload = try TableClipboardPayload.build(from: table)
    #expect(NativeTablePasteboard(board).writeTable(html: payload.html, tabSeparated: payload.tabSeparated))
    #expect(board.pasteboardItems?.count == 1)
    let item = try #require(board.pasteboardItems?.first)
    #expect(item.types.contains(.html) && item.types.contains(.string))
    #expect(item.string(forType: .html) == payload.html)
    #expect(item.string(forType: .string) == "公司名称\t主要产品\nSensonor\tMEMS <陀螺仪>")
    #expect(payload.html.contains("<table border=\"1\">"))
}

// MARK: - Flow through the menu action

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874ConsentNamesTheHostThenTheResultPanelOpensWithoutCopying() async throws {
    let rig = try Rig874App()
    defer { rig.close() }
    #expect(rig.adapter.canStart)
    try await rig.runToEnd()
    let consent = try #require(rig.consentAlerts.first)
    #expect(rig.consentAlerts.count == 1)
    #expect(consent.messageText == String(format: String(localized: "Send this image to %@ to recognise the table?"),
                                          "api.deepseek.com"))
    #expect(consent.messageText.contains("api.deepseek.com"))
    #expect(consent.buttons.map(\.title) == [String(localized: "Agree and Recognise"), String(localized: "Cancel")])
    #expect(rig.workingAlerts.count == 1)
    #expect(rig.dismissedWorking.count == 1, "the working sheet ends when the result is in")
    let panel = try #require(rig.adapter.panel)
    #expect(panel.isVisible)
    #expect(panel.statusLabel.stringValue
        == "Table recognised · 2 rows, 2 columns (including header) · DeepSeek")
    #expect(panel.tableText.string.contains("Sensoror"))
    #expect(panel.tableText.string.contains("MEMS <陀螺仪>"), "cell text is shown as text, never as markup")
    #expect(panel.sourceImageView.image != nil, "the original image is beside the table")
    #expect(rig.board.string(forType: .string) == "before", "no auto-copy")
    #expect(panel.copiedLabel.isHidden, "「表格已拷贝」 only after Copy Table")
    #expect(await rig.transport.count == 1)
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874DecliningConsentSendsNothingAndOpensNothing() async throws {
    let rig = try Rig874App()
    defer { rig.close() }
    rig.consentAnswer = false
    try await rig.runToEnd()
    #expect(rig.consentAlerts.count == 1)
    #expect(await rig.transport.count == 0)
    #expect(await rig.settings.options().consent == nil, "declining records nothing")
    #expect(rig.workingAlerts.isEmpty && rig.notices.isEmpty)
    #expect(rig.adapter.panel == nil)
    #expect(rig.board.string(forType: .string) == "before")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874SwitchOffOrNoKeySendsNothingAndSaysSo() async throws {
    let off = try Rig874App(options: options874(enabled: false, consent: true))
    defer { off.close() }
    try await off.runToEnd()
    #expect(await off.transport.count == 0)
    #expect(off.consentAlerts.isEmpty && off.workingAlerts.isEmpty && off.adapter.panel == nil)
    #expect(off.notices.count == 1)
    #expect(off.notices.first?.messageText == String(localized: "Cloud Recognition is off"))

    let unset = try Rig874App(options: options874(consent: true), key: nil)
    defer { unset.close() }
    try await unset.runToEnd()
    #expect(await unset.transport.count == 0)
    #expect(unset.notices.first?.messageText == String(localized: "Connect a recognition service first"))
    #expect(unset.board.string(forType: .string) == "before")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874CancelInTheWorkingSheetStopsTheRequestWithoutRetryOrClipboardChange() async throws {
    let transport = Transport874(gated: true)
    let rig = try Rig874App(options: options874(consent: true), transport: transport)
    defer { rig.close() }
    rig.adapter.start()
    try await rig.waitUntil("the request is with the service") { await transport.waiting }
    let working = try #require(rig.workingAlerts.first)
    #expect(working.messageText == String(localized: "Recognising table…"))
    // #874 fix1 WI-2: the "was sent" line is the sheet's own label, filled in once the request is with the service.
    #expect(ViewerRecogniseTableAdapter.sentLine(of: working)?.stringValue.contains("api.deepseek.com") == true)
    #expect(working.buttons.map(\.title) == [String(localized: "Cancel")])
    let cancel = try #require(rig.cancelWorking)
    cancel()
    #expect(rig.adapter.flow?.state == .cancelled)
    #expect(rig.dismissedWorking.count == 1)
    await transport.open()
    await rig.adapter.runTask?.value
    try await Task.sleep(for: .milliseconds(100))
    #expect(await transport.count == 1, "never retried")
    #expect(rig.adapter.panel == nil)
    #expect(rig.notices.isEmpty, "a cancel is not a failure")
    #expect(rig.board.string(forType: .string) == "before")
    #expect(rig.adapter.canStart, "a new run can start after Cancel")
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874CopyTableWritesOnceAndOnlyThenSaysTableCopiedAndThePanelStays() async throws {
    let rig = try Rig874App(options: options874(consent: true))
    defer { rig.close() }
    try await rig.runToEnd()
    let panel = try #require(rig.adapter.panel)
    #expect(panel.copyButton.title == String(localized: "Copy Table"))
    #expect(panel.copyButton.keyEquivalent == "\r", "Copy Table is the main button")
    panel.copyButton.performClick(nil)
    let item = try #require(rig.board.pasteboardItems?.first)
    #expect(rig.board.pasteboardItems?.count == 1)
    #expect(item.string(forType: .string) == "公司名称\t主要产品\nSensoror\tMEMS <陀螺仪>")
    let html = try #require(item.string(forType: .html))
    #expect(html.contains("<table border=\"1\">") && html.contains("MEMS &lt;陀螺仪&gt;"))
    #expect(!panel.copiedLabel.isHidden)
    #expect(panel.copiedLabel.stringValue == String(localized: "Table copied"))
    try await Task.sleep(for: .milliseconds(300))
    #expect(panel.isVisible && !panel.copiedLabel.isHidden, "no auto-dismiss")
}

// MARK: - Panel: resizable, keyboard, layout from state 41

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874PanelIsResizableAndKeepsTheState41LayoutAtAnySize() async throws {
    let rig = try Rig874App(options: options874(consent: true))
    defer { rig.close() }
    try await rig.runToEnd()
    let panel = try #require(rig.adapter.panel)
    #expect(panel.styleMask.contains(.resizable) && panel.styleMask.contains(.titled))
    #expect(panel.contentMinSize == RecognisedTablePanel.minimumContentSize)
    #expect(panel.title == String(localized: "Recognise Table"))
    let sizes = [RecognisedTablePanel.defaultContentSize, RecognisedTablePanel.minimumContentSize,
                 NSSize(width: 1400, height: 900)]
    for size in sizes {
        panel.setContentSize(size)
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        // Alignment rects: a push button's frame includes its bezel shadow; layout places the alignment rect.
        func frame(_ view: NSView) -> NSRect {
            let superview = view.superview ?? content
            return superview.convert(view.alignmentRect(forFrame: view.frame), to: content)
        }
        #expect(content.bounds.size == size)
        // `.panel .body { grid-template-columns: 230px 1fr }`; the table takes the rest.
        #expect(abs(frame(panel.sourceColumn).width - RecognisedTablePanel.sourceColumnWidth) < 0.5)
        #expect(frame(panel.tableScroll).minX >= frame(panel.sourceColumn).maxX - 0.5)
        #expect(frame(panel.tableScroll).width > 200)
        // Footer: padding 10 × 16, Copy Table then Close at the trailing edge, nothing cut off.
        let close = frame(panel.closeButton), copy = frame(panel.copyButton)
        #expect(abs(content.bounds.maxX - close.maxX - 16) < 0.5)
        #expect(copy.maxX <= close.minX - 8 + 0.5)
        #expect(close.minY >= 10 - 0.5 && copy.minY >= 10 - 0.5)
        #expect(frame(panel.footerNote).maxX <= copy.minX + 0.5)
        #expect(frame(panel.tableScroll).minY >= close.maxY, "the table never runs under the footer")
        // Header: the status line under the title bar, 16 pt in.
        #expect(abs(frame(panel.statusLabel).minX - 16) < 0.5)
        #expect(frame(panel.statusLabel).maxY <= content.bounds.maxY + 0.5)
        #expect(frame(panel.hintLabel).maxY <= frame(panel.statusLabel).minY + 0.5)
        #expect(frame(panel.tableScroll).maxY <= frame(panel.hintLabel).minY + 0.5)
    }
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874PanelIsKeyboardOperableAndReturnsFocusOnClose() async throws {
    let rig = try Rig874App(options: options874(consent: true))
    defer { rig.close() }
    try await rig.runToEnd()
    let panel = try #require(rig.adapter.panel)
    #expect(panel.initialFirstResponder === panel.copyButton)
    #expect(panel.copyButton.nextKeyView === panel.closeButton)
    #expect(panel.closeButton.nextKeyView === panel.tableText)
    #expect(panel.tableText.nextKeyView === panel.copyButton)
    #expect(panel.tableText.isSelectable && !panel.tableText.isEditable, "read-only until T6 adds cell editing")
    #expect(panel.closeButton.title == String(localized: "Close"))
    #expect(panel.closeButton.keyEquivalent == "\u{1b}", "Esc closes the panel")
    panel.closeButton.performClick(nil)
    #expect(!panel.isVisible)
    #expect(rig.adapter.panel == nil)
    #expect(rig.adapter.flow?.state == .idle)
    #expect(rig.window.firstResponder === rig.controller.canvas, "focus goes back to the image")
    #expect(rig.board.string(forType: .string) == "before")
}

// MARK: - Words: English and Simplified Chinese, as state 41 writes them

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874EveryStringIsLocalisedAndTheChineseMatchesState41() throws {
    let page = try stateFile874()
    // (key, Chinese, how state 41 writes it, or nil when the page has no such text)
    let rows: [(String, String, String?)] = [
        ("Recognise Table…", "识别表格…", nil),
        ("Recognise Table", "识别表格", "aria-label=\"识别表格\""),
        ("Send this image to %@ to recognise the table?", "将这张图片发送到 %@ 识别表格？", "将这张图片发送到 ' + SERV + ' 识别表格？"),
        ("The image leaves your Mac, is processed by that service, and its privacy policy applies. You can turn off Cloud Recognition in Settings at any time.",
         "图片会离开你的 Mac，由该服务处理，并适用其隐私政策。你可以随时在设置中关闭云识别。",
         "图片会离开你的 Mac，由该服务处理，并适用其隐私政策。你可以随时在设置中关闭云识别。"),
        ("Consent covers only this server; a different address asks again.",
         "同意只对这个服务器有效；换了地址会再问一次。", "同意只对这个服务器有效；换了地址会再问一次。"),
        ("Agree and Recognise", "同意并识别", "同意并识别"),
        ("Recognising table…", "正在识别表格…", "正在识别表格…"),
        ("The image was sent to %@. This usually takes a few seconds to over ten seconds.",
         "图片已发送到 %@。通常几秒到十几秒。", "图片已发送到 ' + SERV + '。通常几秒到十几秒。"),
        ("Cancelling doesn't retry automatically; a request already sent may have been charged.",
         "取消后不会自动重试；已发送的请求可能已产生费用。", "取消后不会自动重试；已发送的请求可能已产生费用。"),
        ("Table recognised · %@, %@ (including header) · %@", "表格已识别 · 共 %@、%@（含表头） · %@", nil),
        ("Table recognised · %@, %@ · %@", "表格已识别 · 共 %@、%@ · %@", nil),
        ("%lld rows", "%lld 行", nil),
        ("%lld columns", "%lld 列", nil),
        ("Check the text and the rows and columns.", "请核对文字与行列。", "请核对文字与行列"),
        ("Original", "原图", "<small>原图</small>"),
        ("Pasted into Word it is a complete table; pasted as plain text it is tab-separated text.",
         "粘贴到 Word 是完整的表格；粘贴到纯文本是用制表符分隔的文字", "粘贴到 Word 是完整的表格；粘贴到纯文本是用制表符分隔的文字"),
        ("Copy Table", "拷贝表格", "拷贝表格"),
        ("Table copied", "表格已拷贝", "表格已拷贝"),
        ("Cloud Recognition is off", "云识别已关闭", "云识别已关闭"),
        ("Connect a recognition service first", "首次使用需要连接识别服务", "首次使用需要连接识别服务"),
        ("Couldn't recognise the table", "无法识别表格", nil),
        ("This image is too large", "这张图片太大", "这张图片太大"),
    ]
    for (key, chinese, onPage) in rows {
        #expect(try catalogue874(key, "en").isEmpty == false, "\(key) has English")
        #expect(try catalogue874(key, "zh-Hans") == chinese, "\(key)")
        if let onPage { #expect(page.contains(onPage), "state 41 writes \(onPage)") }
    }
    // The header count follows state 41's 「共 7 行、4 列（含表头）」.
    #expect(page.contains("共 7 行、4 列${HDR ? '（含表头）' : ''}"))
    #expect(try catalogue874("Close", "zh-Hans") == "关闭" && page.contains("B('关闭')"))
    #expect(try catalogue874("Cancel", "zh-Hans") == "取消" && page.contains("B('取消')"))
}

@MainActor @Test(.timeLimit(.minutes(3)))
func issue874StatusLineCountsRowsAndColumnsAndNamesTheService() {
    let table = RecognisedTable(rows: Array(repeating: ["a", "b", "c", "d"], count: 7))
    #expect(RecognisedTablePanel.status(for: RecognisedTableResult(table: table, serviceName: "DeepSeek"))
        == "Table recognised · 7 rows, 4 columns (including header) · DeepSeek")
    let one = RecognisedTable(rows: [["only"]], firstRowIsHeader: false)
    #expect(RecognisedTablePanel.status(for: RecognisedTableResult(table: one, serviceName: "gw.example.com"))
        == "Table recognised · 1 row, 1 column · gw.example.com")
}
