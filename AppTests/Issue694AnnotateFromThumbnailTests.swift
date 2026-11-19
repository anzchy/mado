import AppKit
import Testing
import MadoApplication

// #694 P7-11 CAP-02: 标注 on the Capture Thumbnail. Design pinned at 8848fb3e: capture-thumbnail.html:19-20 order
// (拷贝 · 标注 · 在 Mado 中打开 · 移到废纸篓; 存储 · 拷贝 · 标注 · 在 Mado 中打开), :125 the 标注 button, :81-83
// .overlay grid repeat(3, 1fr), gap 4px 0, padding 6px, align-content center; buttons ui-sm white labels.

private actor Files694App: CaptureFilePort {
    private(set) var written: [String] = []
    func writeNewPNG(_ data: Data, named: String) throws -> URL {
        written.append(named)
        return URL(fileURLWithPath: "/tmp/issue694").appendingPathComponent(named)
    }
}

private struct Screen694App: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data() }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data() }
}

private actor Clipboard694App: CaptureClipboardPort {
    func writePNG(_ png: Data) -> Bool { true }
}

private actor Trash694App: CaptureTrashPort {
    func moveToTrash(_ url: URL) throws {}
}

/// The App Group record store; nothing reaches the real App Group defaults from these tests.
final class Handoff694App: CaptureAnnotateHandoffPort, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CaptureAnnotateHandoffRecord?
    private var log: [String] = []
    var record: CaptureAnnotateHandoffRecord? { lock.withLock { stored } }
    var calls: [String] { lock.withLock { log } }
    func write(_ record: CaptureAnnotateHandoffRecord) { lock.withLock { stored = record; log.append("write") } }
    func clear() { lock.withLock { stored = nil; log.append("clear") } }
    func take() -> CaptureAnnotateHandoffRecord? { lock.withLock { defer { stored = nil }; log.append("take"); return stored } }
}

/// Opens at once (or fails), unless `holding`: then the first open waits until the test finishes it.
private actor Opener694App: CaptureOpenPort {
    private(set) var opened: [URL] = []
    private(set) var recordAtOpen: [CaptureAnnotateHandoffRecord?] = []
    private var release: CheckedContinuation<Void, Never>?
    let handoff: Handoff694App
    let failing: Bool
    let holding: Bool
    init(handoff: Handoff694App, failing: Bool = false, holding: Bool = false) {
        self.handoff = handoff; self.failing = failing; self.holding = holding
    }
    func openInMado(_ url: URL) async throws {
        recordAtOpen.append(handoff.record)
        if holding, opened.isEmpty { await withCheckedContinuation { release = $0 } }
        if failing { throw CocoaError(.fileReadNoPermission) }
        opened.append(url)
    }
    var isOpening: Bool { release != nil }
    func finish() {
        release?.resume()
        release = nil
    }
}

private final class Clock694: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 20_000)
}

private func png694() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 234, pixelsHigh: 150, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

private let saved694 = URL(fileURLWithPath: "/tmp/issue694/mado-20261119093012.png")

@MainActor private func thumbnail694(saved: Bool, files: Files694App = Files694App(), handoff: Handoff694App = Handoff694App(),
                                     opener: Opener694App? = nil, clock: Clock694 = Clock694(),
                                     localize: @escaping (String) -> String = { $0 })
    -> (CaptureThumbnailController, CaptureThumbnailModel) {
    let state = CaptureThumbnailState(png: png694(), savedURL: saved ? saved694 : nil, clipboard: .copied,
                                      folderDisplay: "~/Downloads")
    let session = CaptureSession(screen: Screen694App(), files: files)
    let model = CaptureThumbnailModel(state: state, session: session, clipboard: Clipboard694App(), trash: Trash694App())
    let controller = CaptureThumbnailController(model: model, visibleFrame: NSRect(x: 0, y: 0, width: 1280, height: 800),
                                                now: { clock.now }, localize: localize, startsTimer: false,
                                                opener: opener ?? Opener694App(handoff: handoff), handoff: handoff)
    return (controller, model)
}

@MainActor private func views694(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views694($0) } }

@MainActor private func button694(_ action: String, in root: NSView) throws -> NSButton {
    try #require(views694(root).first { $0.accessibilityIdentifier() == "capture.thumbnail.action.\(action)" } as? NSButton)
}

@MainActor private func visibleActions694(_ root: NSView) -> [String] {
    views694(root).filter { $0.accessibilityIdentifier().hasPrefix("capture.thumbnail.action.") && !$0.isHiddenOrHasHiddenAncestor }
        .sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY > $1.frame.minY }
        .map { String($0.accessibilityIdentifier().dropFirst("capture.thumbnail.action.".count)) }
}

@MainActor private func statusText694(_ root: NSView) -> String? {
    (views694(root).first { $0.accessibilityIdentifier() == "capture.thumbnail.status.text" } as? NSTextField)?.stringValue
}

@MainActor private func waitClosed694(_ controller: CaptureThumbnailController) async {
    for _ in 0..<500 where controller.isOpen { await Task.yield() }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694ThumbnailShowsAnnotateInDesignOrder() throws {
    let zh = try captureCatalog("zh-Hans")
    let expected = [true: ["copy", "annotate", "openInMado", "moveToTrash"], false: ["save", "copy", "annotate", "openInMado"]]
    for saved in [true, false] {
        let (controller, _) = thumbnail694(saved: saved, localize: { zh[$0] ?? "<missing \($0)>" })
        defer { controller.close() }
        controller.show()
        #expect(visibleActions694(controller.view).isEmpty, "at rest the overlay stays hidden")
        controller.pointerEntered()
        #expect(visibleActions694(controller.view) == expected[saved])
        let annotate = try button694("annotate", in: controller.view)
        #expect(annotate.title == "标注")
        #expect(annotate.accessibilityIdentifier() == "capture.thumbnail.action.annotate")
        #expect(CaptureThumbnailText.symbol(.annotate) == "pencil")
        #expect(annotate.image != nil)
    }
}

/// .overlay: repeat(3, 1fr) inside 6 pt padding (column pitch (240 − 12) / 3 = 76), row gap 4, the rows centred
/// vertically; four buttons make two rows, the fourth in row 2 column 1.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694OverlayGridMatchesDesign() throws {
    for saved in [true, false] {
        let (controller, _) = thumbnail694(saved: saved)
        defer { controller.close() }
        controller.show()
        controller.pointerEntered()
        let order = saved ? ["copy", "annotate", "openInMado", "moveToTrash"] : ["save", "copy", "annotate", "openInMado"]
        let frames = try order.map { try button694($0, in: controller.view).frame }
        let thumb = try #require(views694(controller.view).first { $0.accessibilityIdentifier() == "capture.thumbnail.thumb" })
        for (column, frame) in frames.prefix(3).enumerated() {
            #expect(abs(frame.minX - (6 + CGFloat(column) * 76)) < 0.5, "column \(column) at \(frame.minX)")
            #expect(abs(frame.width - 76) < 0.5)
            #expect(frame.minY == frames[0].minY, "row 1")
        }
        #expect(abs(frames[3].minX - 6) < 0.5, "the fourth button in row 2 column 1")
        #expect(abs(frames[0].minY - frames[3].maxY - 4) < 0.5, "row gap 4")
        #expect(frames[3].height == frames[0].height)
        #expect(abs((frames[0].maxY + frames[3].minY) / 2 - thumb.bounds.midY) < 0.5, "the rows are centred")
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateButtonMatchesSiblings() throws {
    for saved in [true, false] {
        let (controller, _) = thumbnail694(saved: saved)
        defer { controller.close() }
        controller.show()
        controller.pointerEntered()
        let annotate = try button694("annotate", in: controller.view)
        for sibling in ["copy", "openInMado"] {
            let other = try button694(sibling, in: controller.view)
            #expect(annotate.font == other.font)
            #expect(annotate.frame.size == other.frame.size)
            #expect(annotate.layer?.cornerRadius == other.layer?.cornerRadius)
            #expect(annotate.contentTintColor == other.contentTintColor)
            #expect(annotate.image?.symbolConfiguration == other.image?.symbolConfiguration)
            #expect(annotate.imagePosition == other.imagePosition)
        }
        #expect(annotate.contentTintColor == .white)
        #expect(annotate.layer?.backgroundColor == nil, "only 存储 has the primary fill")
        let title = annotate.attributedTitle
        #expect(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .white)
        #expect(annotate.attributedTitle.size().width <= annotate.frame.width, "Annotate fits its column on one line")
    }
}

/// Dark appearance: the scrim stays black 55 % and 标注 stays white like its siblings.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694OverlayColorsInDark() throws {
    let (controller, _) = thumbnail694(saved: true)
    defer { controller.close() }
    controller.view.appearance = NSAppearance(named: .darkAqua)
    controller.show()
    controller.pointerEntered()
    let overlay = try #require(views694(controller.view).first { $0.accessibilityIdentifier() == "capture.thumbnail.overlay" })
    let scrim = try #require(overlay.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
    #expect(scrim.redComponent == 0 && scrim.greenComponent == 0 && scrim.blueComponent == 0)
    #expect(abs(scrim.alphaComponent - 0.55) < 0.01)
    let annotate = try button694("annotate", in: controller.view)
    #expect(annotate.contentTintColor == (try button694("copy", in: controller.view)).contentTintColor)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694ThumbnailAnnotateOpensAndCloses() async throws {
    let handoff = Handoff694App()
    let opener = Opener694App(handoff: handoff)
    let (controller, model) = thumbnail694(saved: true, handoff: handoff, opener: opener)
    controller.show()
    controller.pointerEntered()
    try button694("annotate", in: controller.view).performClick(nil)
    await waitClosed694(controller)
    #expect(await opener.opened == [saved694])
    #expect(await opener.recordAtOpen.map { $0?.path } == [CaptureAnnotateHandoff.resolvedPath(saved694)])
    #expect(handoff.calls == ["write"])
    #expect(model.isClosed)
    #expect(!controller.isOpen)
    #expect(!controller.panel.isVisible)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694ThumbnailSaveOffAnnotateWritesThenOpens() async throws {
    let files = Files694App()
    let handoff = Handoff694App()
    let opener = Opener694App(handoff: handoff)
    let (controller, _) = thumbnail694(saved: false, files: files, handoff: handoff, opener: opener)
    controller.show()
    controller.pointerEntered()
    try button694("annotate", in: controller.view).performClick(nil)
    await waitClosed694(controller)
    let written = await files.written
    #expect(written.count == 1)
    #expect(written.first?.hasPrefix("mado-") == true && written.first?.hasSuffix(".png") == true)
    #expect(await opener.opened.map(\.lastPathComponent) == written)
    #expect(!controller.isOpen)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateOpenFailureKeepsThumbnail() async throws {
    let zh = try captureCatalog("zh-Hans")
    let handoff = Handoff694App()
    let opener = Opener694App(handoff: handoff, failing: true)
    let (controller, model) = thumbnail694(saved: true, handoff: handoff, opener: opener, localize: { zh[$0] ?? $0 })
    defer { controller.close() }
    controller.show()
    controller.pointerEntered()
    try button694("annotate", in: controller.view).performClick(nil)
    for _ in 0..<500 where statusText694(controller.view) != "无法在 Mado 中打开" { await Task.yield() }
    #expect(statusText694(controller.view) == "无法在 Mado 中打开")
    #expect(handoff.calls == ["write", "clear"])
    #expect(controller.isOpen)
    #expect(!model.isClosed)
    #expect(visibleActions694(controller.view).contains("annotate"), "标注 stays clickable")
}

/// AC-4 / OQ-4: a pending open is not cancelled by the ~5 s timer, for 标注 and 在 Mado 中打开 alike; the thumbnail
/// closes once the open returns.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694TimeoutDuringPendingAnnotateStillOpens() async throws {
    for action in ["annotate", "openInMado"] {
        let clock = Clock694()
        let handoff = Handoff694App()
        let opener = Opener694App(handoff: handoff, holding: true)
        let (controller, model) = thumbnail694(saved: true, handoff: handoff, opener: opener, clock: clock)
        controller.show()
        controller.pointerEntered()
        try button694(action, in: controller.view).performClick(nil)
        for _ in 0..<5_000 where !(await opener.isOpening) { await Task.yield() }
        guard await opener.isOpening else { Issue.record("\(action): the open never started"); controller.close(); continue }
        controller.pointerExited()
        clock.now += 60
        controller.tick()
        #expect(controller.isOpen, "\(action): the timer waits for the pending open")
        #expect(!model.isClosed)
        await opener.finish()
        await waitClosed694(controller)
        #expect(await opener.opened == [saved694])
        #expect(!controller.isOpen)
    }
    // Without a pending open the timer still closes the thumbnail.
    let clock = Clock694()
    let (idle, _) = thumbnail694(saved: true, clock: clock)
    idle.show()
    clock.now += 5
    idle.tick()
    #expect(!idle.isOpen)
}

@Test(.timeLimit(.minutes(2))) func issue694AnnotateStringsAreLocalized() throws {
    let zh = try captureCatalog("zh-Hans")
    let en = try captureCatalog("en")
    #expect(en[CaptureThumbnailText.title(.annotate)] == "Annotate")
    #expect(zh[CaptureThumbnailText.title(.annotate)] == "标注")
}
