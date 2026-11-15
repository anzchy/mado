import AppKit
import ImageIO
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class RecogniseMenuMotion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private actor RecogniseMenuLeases: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease {
        switch request {
        case .fileGrant(let url), .root(_, let url): AccessLease(url: url, rootID: nil)
        }
    }
    func release(_ lease: AccessLease) {}
}

private actor RecogniseMenuPipeline: ImagePipeline {
    let image: CGImage
    let preview: CGImage?
    let item = ItemID.ephemeral(UUID())
    let revision = FileRevision(byteCount: 1, modificationDate: nil)
    let failFullDecode: Bool
    private var fullFailuresLeft = 0
    init(image: CGImage, preview: CGImage? = nil, failFullDecode: Bool = false) {
        self.image = image; self.preview = preview; self.failFullDecode = failFullDecode
    }
    func failNextFullDecode() { fullFailuresLeft = 1 }
    func request(for fileURL: URL, maximumPixelSize: Int) -> ImageDecodeRequest {
        ImageDecodeRequest(fileURL: fileURL, maximumPixelSize: maximumPixelSize,
            renderKey: RenderKey(itemID: item, revision: revision, maximumPixelSize: maximumPixelSize))
    }
    func image(for request: ImageDecodeRequest) throws -> DecodedImage {
        if request.maximumPixelSize >= image.width && (failFullDecode || fullFailuresLeft > 0) {
            if fullFailuresLeft > 0 { fullFailuresLeft -= 1 }
            throw ImageLoadError(.resourceLimit)
        }
        let selected = request.maximumPixelSize >= image.width ? image : (preview ?? image)
        return DecodedImage(image: selected, sourcePixelSize: CGSize(width: image.width, height: image.height),
                     revision: revision, itemID: item)
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextDetailLimitedUsesDeliveredPixels() async throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    let context = try #require(CGContext(data: nil, width: 200, height: 2, bitsPerComponent: 8,
        bytesPerRow: 800, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let previewContext = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let pipeline = RecogniseMenuPipeline(image: try #require(context.makeImage()),
        preview: try #require(previewContext.makeImage()), failFullDecode: true)
    let leases = RecogniseMenuLeases(), url = URL(fileURLWithPath: "/tmp/detail-limited.png")
    controller.session.openImage(url, maximumPixelSize: 3) {
        try await AccessImageSource.open(.fileGrant(url), access: leases, pipeline: pipeline)
    }
    for _ in 0..<200 where controller.session.imageLoader.phase != .settled {
        try await Task.sleep(for: .milliseconds(10))
    }
    controller.session.requireImageResolution(200)
    for _ in 0..<200 where controller.session.imageLoader.phase != .detailLimited {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.session.imageLoader.phase == .detailLimited)
    let board = NSPasteboard(name: .init("mado.issue687.limited.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    controller.recogniseTextAdapter.pasteboard = board
    let probe = RecogniseIntentProbe()
    controller.recogniseTextAdapter.recognise = { data, intent in
        await probe.record(data, intent: intent)
        return TextRecognitionResult(text: "delivered", characterCount: 9, engine: .onDevice, isEmpty: false)
    }
    controller.recogniseText()
    for _ in 0..<200 where controller.recogniseTextAdapter.model?.isRunning == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.pixelSize == CGSize(width: 2, height: 2))
    #expect(board.string(forType: .string) == "delivered")
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextReducedPreviewUsesHeldFullResolutionSource() async throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    func pixels(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    let pipeline = RecogniseMenuPipeline(image: try pixels(2000, 11), preview: try pixels(2, 2))
    let leases = RecogniseMenuLeases(), url = URL(fileURLWithPath: "/tmp/reduced.png")
    controller.session.openImage(url, maximumPixelSize: 3) {
        try await AccessImageSource.open(.fileGrant(url), access: leases, pipeline: pipeline)
    }
    for _ in 0..<200 {
        if controller.session.imageLoader.phase == .settled { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.canvas.backdropFrame.image?.width == 2)
    let board = NSPasteboard(name: .init("mado.issue687.full-source.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    controller.recogniseTextAdapter.pasteboard = board
    let probe = RecogniseIntentProbe()
    controller.recogniseTextAdapter.recognise = { data, intent in
        await probe.record(data, intent: intent)
        return TextRecognitionResult(text: "full source", characterCount: 11, engine: .onDevice, isEmpty: false)
    }
    controller.recogniseText()
    for _ in 0..<200 {
        if controller.recogniseTextAdapter.model?.isRunning == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.explicit)
    #expect(await probe.pixelSize == CGSize(width: 2000, height: 11))
    #expect(board.string(forType: .string) == "full source")
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextMenuHasNoShortcutAndRequiresShownPixels() async throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close(); NSApp.mainMenu = previousMenu }
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: {}, windowController: { controller })
    defer { withExtendedLifetime(menu) {} }
    let view = try #require(NSApp.mainMenu?.items.first { $0.title == String(localized: "View") }?.submenu)
    let item = try #require(view.items.first { $0.accessibilityIdentifier() == "viewer.recognise-text.menu" })
    #expect(item.title == String(localized: "Recognise Text"))
    #expect(item.keyEquivalent.isEmpty)
    #expect(!menu.validateMenuItem(item))
    let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
        bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: 3, height: 2))
    controller.installImage(image, fileURL: URL(fileURLWithPath: "/tmp/recognise.png"))
    #expect(menu.validateMenuItem(item))
    controller.imageLoadFailed(TextRecognitionError.invalidImage)
    #expect(!menu.validateMenuItem(item))
    let url = URL(fileURLWithPath: "/tmp/recognise.png")
    let pipeline = RecogniseMenuPipeline(image: image.image), leases = RecogniseMenuLeases()
    controller.session.openImage(url, maximumPixelSize: 3) {
        try await AccessImageSource.open(.fileGrant(url), access: leases, pipeline: pipeline)
    }
    for _ in 0..<200 {
        if controller.session.imageLoader.phase == .settled { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(controller.session.imageLoader.phase == .settled)
    #expect(menu.validateMenuItem(item))
    controller.enterAnnotateMode()
    #expect(controller.session.isAnnotating)
    #expect(!menu.validateMenuItem(item))
}

private actor RecogniseIntentProbe {
    private(set) var explicit = false
    private(set) var pixelSize = CGSize.zero
    func record(_ data: Data, intent: TextRecognitionIntent) {
        explicit = intent == .explicit
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            pixelSize = CGSize(width: properties[kCGImagePropertyPixelWidth] as? Int ?? 0,
                               height: properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
        }
    }
}

private actor RecogniseRunCounter {
    private var count = 0
    func next() -> Int { count += 1; return count }
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextDecodeErrorFallsBackAndNextActionDecodesAgain() async throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    func pixels(_ width: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: 2,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try #require(context.makeImage())
    }
    let pipeline = RecogniseMenuPipeline(image: try pixels(200), preview: try pixels(2))
    let leases = RecogniseMenuLeases(), url = URL(fileURLWithPath: "/tmp/transient-ocr.png")
    controller.session.openImage(url, maximumPixelSize: 3) {
        try await AccessImageSource.open(.fileGrant(url), access: leases, pipeline: pipeline)
    }
    for _ in 0..<200 where controller.session.imageLoader.phase != .settled {
        try await Task.sleep(for: .milliseconds(10))
    }
    let key = try #require(controller.session.imageLoader.presented?.key)
    controller.installImage(DecodedImage(image: try pixels(2), sourcePixelSize: CGSize(width: 200, height: 2),
        revision: key.revision, itemID: key.itemID), fileURL: url)
    await pipeline.failNextFullDecode()
    let board = NSPasteboard(name: .init("mado.issue687.retry-ocr.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    controller.recogniseTextAdapter.pasteboard = board
    let counter = RecogniseRunCounter()
    controller.recogniseTextAdapter.recognise = { _, _ in
        let count = await counter.next()
        return TextRecognitionResult(text: "run \(count)", characterCount: 5, engine: .onDevice, isEmpty: false)
    }
    controller.recogniseText()
    for _ in 0..<200 where controller.recogniseTextAdapter.model?.isRunning == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(board.string(forType: .string) == "run 1")
    controller.recogniseText()
    for _ in 0..<200 where controller.recogniseTextAdapter.model?.isRunning == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(board.string(forType: .string) == "run 2")
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextMenuRunsExplicitServiceOnDecodedPixels() async throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    let board = NSPasteboard(name: .init("mado.issue687.menu.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    controller.recogniseTextAdapter.pasteboard = board
    let probe = RecogniseIntentProbe()
    controller.recogniseTextAdapter.recognise = { data, intent in
        await probe.record(data, intent: intent)
        return TextRecognitionResult(text: "from pixels", characterCount: 11, engine: .onDevice, isEmpty: false)
    }
    let context = try #require(CGContext(data: nil, width: 17, height: 11, bitsPerComponent: 8,
        bytesPerRow: 68, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    controller.installImage(DecodedImage(image: try #require(context.makeImage()),
        sourcePixelSize: CGSize(width: 17, height: 11)), fileURL: URL(fileURLWithPath: "/tmp/recognise-17.png"))
    controller.recogniseText()
    #expect(controller.recogniseTextAdapter.model?.isRunning == true)
    for _ in 0..<200 where controller.recogniseTextAdapter.model?.isRunning == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.explicit)
    #expect(await probe.pixelSize == CGSize(width: 17, height: 11))
    #expect(board.string(forType: .string) == "from pixels")
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextDoesNotReadDifferentFileWhenShownPixelsAreReduced() async throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    let probe = RecogniseIntentProbe()
    controller.recogniseTextAdapter.pasteboard = NSPasteboard(name: .init("mado.issue687.reduced.\(UUID().uuidString)"))
    defer { controller.recogniseTextAdapter.pasteboard.releaseGlobally() }
    controller.recogniseTextAdapter.recognise = { data, intent in
        await probe.record(data, intent: intent)
        return TextRecognitionResult(text: "shown pixels", characterCount: 12, engine: .onDevice, isEmpty: false)
    }
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let unrelated = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/TextRecognition/mixed.png")
    controller.installImage(DecodedImage(image: try #require(context.makeImage()),
        sourcePixelSize: CGSize(width: 900, height: 900)), fileURL: unrelated)
    controller.recogniseText()
    for _ in 0..<200 {
        if controller.recogniseTextAdapter.model?.isRunning == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.pixelSize == CGSize(width: 2, height: 2))
    #expect(controller.recogniseTextAdapter.pasteboard.string(forType: .string) == "shown pixels")
}

private actor ViewerRecognitionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextBusyStaleImageAndCloseNeverCopyOldText() async throws {
    _ = NSApplication.shared
    let previousMenu = NSApp.mainMenu
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close(); NSApp.mainMenu = previousMenu }
    let board = NSPasteboard(name: .init("mado.issue687.race.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("sentinel", forType: .string)
    let changeCount = board.changeCount
    controller.recogniseTextAdapter.pasteboard = board
    let menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(),
        openWithoutWindow: {}, openSettings: {}, openDiagnostics: {}, windowController: { controller })
    defer { withExtendedLifetime(menu) {} }
    let view = try #require(NSApp.mainMenu?.items.first { $0.title == String(localized: "View") }?.submenu)
    let item = try #require(view.items.first { $0.accessibilityIdentifier() == "viewer.recognise-text.menu" })
    func image(_ width: Int) throws -> DecodedImage {
        let context = try #require(CGContext(data: nil, width: width, height: 2, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return DecodedImage(image: try #require(context.makeImage()), sourcePixelSize: CGSize(width: width, height: 2))
    }
    controller.installImage(try image(3), fileURL: URL(fileURLWithPath: "/tmp/a.png"))
    let firstGate = ViewerRecognitionGate()
    controller.recogniseTextAdapter.recognise = { _, _ in
        await firstGate.wait()
        return TextRecognitionResult(text: "A", characterCount: 1, engine: .onDevice, isEmpty: false)
    }
    #expect(menu.validateMenuItem(item))
    controller.recogniseText()
    #expect(!menu.validateMenuItem(item))
    for _ in 0..<200 {
        if await firstGate.entered { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    controller.installImage(try image(4), fileURL: URL(fileURLWithPath: "/tmp/b.png"))
    await firstGate.release()
    for _ in 0..<200 {
        if controller.recogniseTextAdapter.model?.isRunning == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(board.changeCount == changeCount)
    #expect(board.string(forType: .string) == "sentinel")
    #expect(controller.recogniseTextAdapter.model?.notice == nil)
    #expect(menu.validateMenuItem(item))

    let closeGate = ViewerRecognitionGate()
    controller.recogniseTextAdapter.recognise = { _, _ in
        await closeGate.wait()
        return TextRecognitionResult(text: "B after close", characterCount: 13, engine: .onDevice, isEmpty: false)
    }
    controller.recogniseText()
    for _ in 0..<200 {
        if await closeGate.entered { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    window.close()
    #expect(!controller.recogniseTextAdapter.canStart, "closing the window invalidates the action synchronously")
    try await Task.sleep(for: .milliseconds(20))
    await closeGate.release()
    try await Task.sleep(for: .milliseconds(20))
    #expect(board.changeCount == changeCount)
    #expect(controller.recogniseTextAdapter.model?.notice == nil)
    #expect(!controller.recogniseTextAdapter.canStart)
}

@MainActor @Test(.timeLimit(.minutes(3))) func viewerRecogniseTextNoticeOpensEditablePanelCopyAndEscape() async throws {
    _ = NSApplication.shared
    let unavailable = Task<AccessServices, Error> { throw CancellationError() }
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: unavailable,
        motionPolicy: MotionPolicy(source: RecogniseMenuMotion()))
    let window = try #require(controller.window)
    defer { window.close() }
    let board = NSPasteboard(name: .init("mado.issue687.panel.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    controller.recogniseTextAdapter.pasteboard = board
    controller.recogniseTextAdapter.recognise = { _, _ in
        TextRecognitionResult(text: "original", characterCount: 8, engine: .onDevice, isEmpty: false)
    }
    let context = try #require(CGContext(data: nil, width: 3, height: 2, bitsPerComponent: 8,
        bytesPerRow: 12, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    controller.installImage(DecodedImage(image: try #require(context.makeImage()),
        sourcePixelSize: CGSize(width: 3, height: 2)), fileURL: URL(fileURLWithPath: "/tmp/panel.png"))
    window.setContentSize(NSSize(width: 238, height: 168))
    controller.session.setInspectorVisible(true)
    controller.recogniseText()
    for _ in 0..<200 {
        if controller.recogniseTextAdapter.model?.isRunning == false { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let overlay = try #require(window.contentView?.subviews.compactMap { $0 as? RecogniseTextOverlay }.first)
    let notice = try #require(overlay.noticeView)
    let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    notice.mouseDown(with: click)
    #expect(overlay.noticeView == nil)
    let panel = try #require(overlay.panelView)
    #expect(window.firstResponder === panel.textView)
    #expect((window.contentView?.bounds.height ?? 0) >= 282)
    #expect(panel.frame.width == (window.contentView?.bounds.width ?? 0) - 40)
    let zoomBefore = controller.session.zoomMode
    for (code, characters) in [(UInt16(49), " "), (123, "←"), (29, "0"), (18, "1")] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }
    #expect(controller.session.zoomMode == zoomBefore)
    #expect(window.firstResponder === panel.textView)
    panel.textView.string = "edited result"
    panel.textDidChange(Notification(name: NSText.didChangeNotification, object: panel.textView))
    panel.copyButton.performClick(nil)
    #expect(board.string(forType: .string) == "edited result")
    #expect(overlay.panelView === panel)
    #expect(window.firstResponder === panel.textView)
    #expect(panel.footerLabel.stringValue == String(localized: "Copied"))
    window.setContentSize(NSSize(width: 300, height: 282))
    let fullScreen = window.styleMask.contains(.fullScreen)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    window.sendEvent(escape)
    #expect(overlay.panelView == nil)
    #expect(window.firstResponder === controller.canvas)
    #expect(window.contentMinSize.height <= 168)
    #expect((window.contentView?.bounds.width ?? 0) == 300)
    #expect(controller.inspectorVisible)
    #expect(window.styleMask.contains(.fullScreen) == fullScreen)
}
