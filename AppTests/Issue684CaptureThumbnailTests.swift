import AppKit
import Testing
import MadoApplication

// #684 P7-10 CAP-02 Capture Thumbnail. Design: design/prototypes/picsee-browser/states/capture-thumbnail.html
// (.corner right/bottom 20px and gap 6px, line 85; .thumb width 240px, border 3px var(--color-panel), radius 8px, line 86;
// .thumb img height 150px, line 87; .overlay black 55%, line 88; .status ui-sm pill, line 96).

private actor ThumbClipboard: CaptureClipboardPort {
    private(set) var writes: [Data] = []
    func writePNG(_ png: Data) -> Bool { writes.append(png); return true }
}

private actor ThumbTrash: CaptureTrashPort {
    private(set) var trashed: [URL] = []
    func moveToTrash(_ url: URL) throws { trashed.append(url) }
}

private actor ThumbFiles: CaptureFilePort {
    func writeNewPNG(_ data: Data, named: String) throws -> URL {
        URL(fileURLWithPath: "/tmp/issue684").appendingPathComponent(named)
    }
}

private struct ThumbScreen: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data() }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data() }
}

/// A 234×150 PNG: the pinned design image area.
private func pinnedPNG(width: Int = 234, height: Int = 150) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

private final class FakeClock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 10_000)
}

@MainActor private func thumbnail(saved: Bool, png: Data = pinnedPNG(), clock: FakeClock = FakeClock(),
                                  visibleFrame: NSRect = NSRect(x: 0, y: 0, width: 1280, height: 800),
                                  localize: @escaping (String) -> String = { $0 },
                                  trash: ThumbTrash = ThumbTrash())
    -> (CaptureThumbnailController, CaptureThumbnailModel) {
    let url = saved ? URL(fileURLWithPath: "/tmp/issue684/mado-20261114153012.png") : nil
    let state = CaptureThumbnailState(png: png, savedURL: url, clipboard: .copied, folderDisplay: "~/Downloads")
    let session = CaptureSession(screen: ThumbScreen(), files: ThumbFiles())
    let model = CaptureThumbnailModel(state: state, session: session, clipboard: ThumbClipboard(), trash: trash)
    let controller = CaptureThumbnailController(model: model, visibleFrame: visibleFrame,
                                                now: { clock.now }, localize: localize, startsTimer: false)
    return (controller, model)
}

@MainActor private func views(_ root: NSView) -> [NSView] {
    [root] + root.subviews.flatMap { views($0) }
}

@MainActor private func view(_ id: String, in root: NSView) -> NSView? {
    views(root).first { $0.accessibilityIdentifier() == id }
}

@MainActor private func visibleActionIDs(_ root: NSView) -> [String] {
    views(root).filter { $0.accessibilityIdentifier().hasPrefix("capture.thumbnail.action.") && !$0.isHiddenOrHasHiddenAncestor }
        .sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY > $1.frame.minY }
        .map { $0.accessibilityIdentifier() }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailCornerAndSize() throws {
    let (controller, _) = thumbnail(saved: true)
    defer { controller.close() }
    controller.show()
    let visible = NSRect(x: 0, y: 0, width: 1280, height: 800)
    let corner = controller.cornerFrame
    #expect(abs(corner.maxX - (visible.maxX - 20)) < 0.5)
    #expect(abs(corner.minY - (visible.minY + 20)) < 0.5)
    let thumb = try #require(view("capture.thumbnail.thumb", in: controller.view))
    #expect(thumb.frame.size == NSSize(width: 240, height: 156))
    #expect(thumb.layer?.borderWidth == 3)
    #expect(thumb.layer?.cornerRadius == 8)
    #expect(thumb.layer?.masksToBounds == true)
    let status = try #require(view("capture.thumbnail.status", in: controller.view))
    #expect(abs(thumb.frame.minY - status.frame.maxY - 6) < 0.5)
    #expect(abs(thumb.frame.maxX - status.frame.maxX) < 0.5)
    #expect(CaptureThumbnailLayout.imageHeight(forPixelWidth: 1600, pixelHeight: 1000) == 146)
    #expect(CaptureThumbnailLayout.imageHeight(forPixelWidth: 400, pixelHeight: 2000) == 234)
    #expect(CaptureThumbnailLayout.imageHeight(forPixelWidth: 2000, pixelHeight: 10) == 24)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684CornerUsesCapturedDisplayVisibleFrame() {
    let secondary = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
    let (controller, _) = thumbnail(saved: true, visibleFrame: secondary)
    defer { controller.close() }
    controller.show()
    #expect(abs(controller.cornerFrame.maxX - (secondary.maxX - 20)) < 0.5)
    #expect(abs(controller.cornerFrame.minY - (secondary.minY + 20)) < 0.5)
    #expect(controller.panel.frame.contains(controller.cornerFrame))
    let main = NSRect(x: 0, y: 0, width: 1440, height: 875)
    let screens: [CaptureThumbnailPlacement.Screen] = [
        (id: 1, frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visible: main),
        (id: 7, frame: NSRect(x: 1440, y: -200, width: 1920, height: 1080), visible: secondary)]
    let region = CaptureRequest.Target.region(rect: .zero, displayID: 7, displayFrame: secondary, scale: 2)
    #expect(CaptureThumbnailPlacement.displayID(for: region, selectedDisplay: nil) == 7)
    #expect(CaptureThumbnailPlacement.displayID(for: .fullScreen(displayID: 7), selectedDisplay: nil) == 7)
    #expect(CaptureThumbnailPlacement.displayID(for: .window(windowID: 99), selectedDisplay: 7) == 7)
    #expect(CaptureThumbnailPlacement.displayID(containing: NSPoint(x: 10, y: 10), screens: screens) == 1)
    #expect(CaptureThumbnailPlacement.visibleFrame(displayID: 7, screens: screens) == secondary)
    #expect(CaptureThumbnailPlacement.visibleFrame(displayID: 1, screens: screens) == main)
    // Unknown display (unplugged since the Capture started): the main display.
    #expect(CaptureThumbnailPlacement.visibleFrame(displayID: 42, screens: screens) == main)
    #expect(CaptureThumbnailPlacement.visibleFrame(displayID: nil, screens: screens) == main)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailHoverActions() async throws {
    let (saved, _) = thumbnail(saved: true)
    defer { saved.close() }
    saved.show()
    #expect(visibleActionIDs(saved.view).isEmpty)
    #expect(view("capture.thumbnail.close", in: saved.view)?.isHiddenOrHasHiddenAncestor == true)
    saved.pointerEntered()
    #expect(visibleActionIDs(saved.view) == ["capture.thumbnail.action.copy", "capture.thumbnail.action.openInMado",
                                         "capture.thumbnail.action.moveToTrash"])
    #expect(view("capture.thumbnail.overlay", in: saved.view)?.isHiddenOrHasHiddenAncestor == false)
    #expect(view("capture.thumbnail.close", in: saved.view)?.isHiddenOrHasHiddenAncestor == false)
    for later in ["annotate", "recognizeText"] {
        #expect(view("capture.thumbnail.action.\(later)", in: saved.view) == nil)
    }
    saved.pointerExited()
    #expect(visibleActionIDs(saved.view).isEmpty)

    let (unsaved, _) = thumbnail(saved: false)
    defer { unsaved.close() }
    unsaved.show()
    unsaved.pointerEntered()
    #expect(visibleActionIDs(unsaved.view) == ["capture.thumbnail.action.save", "capture.thumbnail.action.copy",
                                           "capture.thumbnail.action.openInMado"])
    let titles = ["capture.thumbnail.action.save", "capture.thumbnail.action.copy"].compactMap {
        (view($0, in: unsaved.view) as? NSButton)?.title
    }
    #expect(titles == ["Save", "Copy"])
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailStatusStrings() throws {
    let zh = try captureCatalog("zh-Hans")
    let en = try captureCatalog("en")
    let local: (CaptureThumbnailStatus, [String: String]) -> String = { status, catalog in
        CaptureThumbnailText.status(status, localize: { catalog[$0] ?? "<missing \($0)>" })
    }
    #expect(local(.saved(folder: "~/Downloads", clipboard: .copied), zh) == "已存到 ~/Downloads · 已拷贝")
    #expect(local(.notSaved(clipboard: .copied, saveFailed: false), zh) == "只在剪贴板里 · 没有存储")
    #expect(local(.saved(folder: "~/Downloads", clipboard: .copied), en) == "Saved to ~/Downloads · Copied")
    #expect(local(.notSaved(clipboard: .copied, saveFailed: false), en) == "Only on the clipboard · Not saved")
    let every: [CaptureThumbnailStatus] = [.copied, .notCopied, .copyFailed].flatMap { clip in
        [.saved(folder: "~/Downloads", clipboard: clip), .notSaved(clipboard: clip, saveFailed: false),
         .notSaved(clipboard: clip, saveFailed: true)]
    }
    for catalog in [zh, en] {
        let rendered = every.map { local($0, catalog) }
        #expect(rendered.allSatisfy { !$0.contains("<missing") })
        #expect(Set(rendered).count == every.count)
    }
    for key in ["Move to Trash", "Close Thumbnail", "Capture Thumbnail %@", "Drag to another app",
                "Couldn't move to the Trash", "Copy", "Save"] {
        #expect(zh[key] != nil && en[key] != nil, "\(key)")
    }
    #expect(zh["Move to Trash"] == "移到废纸篓")
    let (controller, _) = thumbnail(saved: true, localize: { zh[$0] ?? $0 })
    defer { controller.close() }
    controller.show()
    let label = try #require(view("capture.thumbnail.status.text", in: controller.view) as? NSTextField)
    #expect(label.stringValue == "已存到 ~/Downloads · 已拷贝")
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailTimerUsesInjectedClock() {
    let clock = FakeClock()
    let (controller, _) = thumbnail(saved: true, clock: clock)
    controller.show()
    #expect(controller.lifetime.deadline == clock.now.addingTimeInterval(5))
    clock.now += 4.9
    controller.tick()
    #expect(controller.isOpen)
    controller.pointerEntered()
    clock.now += 60
    controller.tick()
    #expect(controller.isOpen)
    controller.pointerExited()
    clock.now += 4.9
    controller.tick()
    #expect(controller.isOpen)
    clock.now += 0.1
    controller.tick()
    #expect(!controller.isOpen)
    #expect(!controller.panel.isVisible)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailHoverViewEvents() throws {
    let clock = FakeClock()
    let (controller, _) = thumbnail(saved: true, clock: clock)
    defer { controller.close() }
    controller.show()
    let thumbnailView = try #require(controller.view as? CaptureThumbnailView)
    let area = try #require(thumbnailView.trackingAreas.first)
    #expect(area.options.contains(.activeAlways))
    #expect(area.options.contains(.mouseEnteredAndExited))
    #expect(area.rect.contains(try #require(view("capture.thumbnail.thumb", in: thumbnailView)).frame))
    thumbnailView.mouseEntered(with: NSEvent())
    #expect(controller.lifetime.deadline == nil)
    #expect(!visibleActionIDs(thumbnailView).isEmpty)
    thumbnailView.mouseExited(with: NSEvent())
    #expect(controller.lifetime.deadline == clock.now.addingTimeInterval(5))
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684NewThumbnailReplacesOld() {
    let clock = FakeClock()
    let presenter = CaptureThumbnailPresenter()
    let (first, _) = thumbnail(saved: true, clock: clock)
    presenter.present(first)
    clock.now += 3
    let (second, _) = thumbnail(saved: true, clock: clock)
    presenter.present(second)
    #expect(!first.isOpen)
    #expect(second.isOpen)
    #expect(presenter.windows == [second.panel])
    clock.now += 2.5
    first.tick()
    second.tick()
    #expect(second.isOpen)
    second.close()
    #expect(presenter.windows.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailNeverKeyAndExcluded() {
    let (controller, _) = thumbnail(saved: true)
    defer { controller.close() }
    controller.show()
    let panel = controller.panel
    #expect(!panel.canBecomeKey)
    #expect(!panel.canBecomeMain)
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(panel.isVisible)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailExcludedFromEveryCaptureKind() throws {
    let presenter = CaptureThumbnailPresenter()
    let (controller, _) = thumbnail(saved: true)
    presenter.present(controller)
    defer { controller.close() }
    let id = try #require(UInt32(exactly: controller.panel.windowNumber))
    let bar = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                      backing: .buffered, defer: false)
    let targets: [CaptureRequest.Target] = [
        .region(rect: NSRect(x: 0, y: 0, width: 10, height: 10), displayID: 1,
                displayFrame: NSRect(x: 0, y: 0, width: 100, height: 100), scale: 1),
        .window(windowID: 4242), .fullScreen(displayID: 1)
    ]
    for target in targets {
        let request = CaptureHelperWindows.request(target: target, bar: bar, status: nil, thumbnails: presenter,
                                                   overlays: [])
        #expect(request.excludedWindowIDs.contains(id))
    }
    controller.close()
    let after = CaptureHelperWindows.request(target: .fullScreen(displayID: 1), bar: bar, status: nil,
                                             thumbnails: presenter, overlays: [])
    #expect(!after.excludedWindowIDs.contains(id))
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684PasteboardCopyAndNoCopy() async throws {
    let name = NSPasteboard.Name("issue684-\(UUID().uuidString)")
    let pasteboard = NSPasteboard(name: name)
    defer { pasteboard.releaseGlobally() }
    let clipboard = PasteboardCaptureClipboard(name: name)
    let png = pinnedPNG()
    #expect(await clipboard.writePNG(png))
    #expect(pasteboard.data(forType: .png) == png)
    #expect(NSImage(pasteboard: pasteboard) != nil)
    let before = pasteboard.changeCount
    let files = ThumbFiles()
    struct PNGScreen: CaptureScreenPort {
        let png: Data
        func captureCurrentDisplayPNG() async throws -> Data { png }
        func capturePNG(request: CaptureRequest) async throws -> Data { png }
    }
    let session = CaptureSession(screen: PNGScreen(png: png), files: files)
    let state = try await session.capture(request: nil,
                                          policy: CaptureOutputPolicy(savesToFolder: true, copiesToClipboard: false),
                                          clipboard: clipboard)
    #expect(state.clipboard == .notCopied)
    #expect(pasteboard.changeCount == before)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684DragPayloadWriters() throws {
    let url = URL(fileURLWithPath: "/tmp/issue684/mado-20261114153012.png")
    let png = pinnedPNG()
    let file = CaptureThumbnailDrag.writer(for: .file(url))
    let filePasteboard = NSPasteboard(name: NSPasteboard.Name("issue684-drag-\(UUID().uuidString)"))
    defer { filePasteboard.releaseGlobally() }
    filePasteboard.clearContents()
    filePasteboard.writeObjects([file])
    let urls = filePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    #expect(urls == [url])
    let image = CaptureThumbnailDrag.writer(for: .png(png))
    let imagePasteboard = NSPasteboard(name: NSPasteboard.Name("issue684-drag-\(UUID().uuidString)"))
    defer { imagePasteboard.releaseGlobally() }
    imagePasteboard.clearContents()
    imagePasteboard.writeObjects([image])
    #expect(imagePasteboard.data(forType: .png) == png)
    #expect((imagePasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684DragAfterSaveGivesFileAndCopyOnly() async throws {
    let (controller, model) = thumbnail(saved: false)
    defer { controller.close() }
    controller.show()
    let thumbnailView = try #require(controller.view as? CaptureThumbnailView)
    #expect(controller.dragPayload == .png(model.state.png))
    try await model.save()
    #expect(controller.dragPayload == .file(URL(fileURLWithPath: "/tmp/issue684/mado-20261114153012.png").deletingLastPathComponent()
        .appendingPathComponent(model.state.savedURL!.lastPathComponent)))
    let session = NSDraggingSession.self  // the mask does not depend on the session
    _ = session
    #expect(thumbnailView.dragOperationMask == .copy)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ThumbnailActionsReachTheModel() async throws {
    let trash = ThumbTrash()
    let (controller, model) = thumbnail(saved: true, trash: trash)
    controller.show()
    controller.pointerEntered()
    let button = try #require(view("capture.thumbnail.action.moveToTrash", in: controller.view) as? NSButton)
    button.performClick(nil)
    for _ in 0..<200 where controller.isOpen { await Task.yield() }
    #expect(await trash.trashed == [model.state.savedURL!])
    #expect(!controller.isOpen)
    let (closing, _) = thumbnail(saved: false)
    closing.show()
    closing.pointerEntered()
    let close = try #require(view("capture.thumbnail.close", in: closing.view) as? NSButton)
    close.performClick(nil)
    #expect(!closing.isOpen)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684TrashAdapterMovesToTrashOnly() async throws {
    final class Calls: @unchecked Sendable { var urls: [URL] = [] }
    let calls = Calls()
    let url = URL(fileURLWithPath: "/tmp/issue684/a.png")
    try await FileManagerCaptureTrash(trash: { calls.urls.append($0) }).moveToTrash(url)
    #expect(calls.urls == [url])
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("App/CaptureHelper/CaptureThumbnail.swift"),
                            encoding: .utf8)
    #expect(source.contains("trashItem(at:"))
    #expect(!source.contains("removeItem"))
}
