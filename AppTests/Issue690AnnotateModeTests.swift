import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

/// Records every native Annotate surface; answers the prompt and the panel as each test sets.
@MainActor private final class Issue690FakeUI: AnnotateNativeUI {
    var asked: [AnnotateLeaveReason] = []
    /// Answered at once when set; otherwise the answer waits in `pending`.
    var answer: AnnotateLeaveChoice?
    var pending: (@MainActor (AnnotateLeaveChoice) -> Void)?
    var panelChoice: URL?
    var panelRequests: [(folder: URL, name: String, type: UTType)] = []
    var saved: [URL] = []
    var failures: [AnnotatedCopyError] = []
    func askToLeave(_ reason: AnnotateLeaveReason, window: NSWindow?,
                    answer reply: @escaping @MainActor (AnnotateLeaveChoice) -> Void) {
        asked.append(reason)
        if let answer { reply(answer) } else { pending = reply }
    }
    func chooseSaveLocation(folder: URL, name: String, type: UTType, window: NSWindow?) async -> URL? {
        panelRequests.append((folder, name, type))
        return panelChoice
    }
    func showSaved(_ url: URL, window: NSWindow?) { saved.append(url) }
    func showSaveFailure(_ error: AnnotatedCopyError, window: NSWindow?) { failures.append(error) }
}

/// Real grants, folder scanning and ImageIO loading in an Access Root, with the window kept ordered out.
@MainActor private final class Issue690Context {
    let base: URL, folder: URL, first: URL, second: URL
    let services: AccessServices
    let ui = Issue690FakeUI()
    var controller: CanvasWindowController!
    var menu: CommandMenu!
    let previousMenu: NSMenu?
    var replies: [Bool] = []
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("mado.issue690.\(UUID().uuidString)"))

    /// `size` writes a real grey PNG of that size instead of the 400×600 fixture (#690 WI-6, page 39's 1600×2400);
    /// `existing` adds more copies of it under those names before the folder is scanned.
    init(size: CGSize? = nil, existing: [String] = []) async throws {
        previousMenu = NSApplication.shared.mainMenu
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = base.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/portrait-2x3.png")
        first = folder.appendingPathComponent("a.png")
        second = folder.appendingPathComponent("b.png")
        let data = try size.map(issue690GreyPNG) ?? Data(contentsOf: fixture)
        let folder = folder
        for url in [first, second] + existing.map({ folder.appendingPathComponent($0) }) { try data.write(to: url) }
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue690")
        _ = try await access.grant(folder: folder)
        services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    }

    /// `fakeUI: false` keeps the window's own Annotate surfaces (page 39's sheet and confirmation).
    func open(fakeUI: Bool = true) async throws -> CanvasWindowController {
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { self.services }, motionPolicy: MotionPolicy(source: Issue349Motion()))
        self.controller = controller
        if fakeUI { controller.annotateUI = ui }
        controller.annotatePasteboard = pasteboard
        controller.annotateTerminateReply = { [weak self] in self?.replies.append($0) }
        menu = CommandMenu(preferencesStore: InMemoryDisplayPreferencesStore(), openWithoutWindow: {},
            openSettings: {}, openDiagnostics: {}, windowController: { controller })
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.orderOut(nil)
        controller.openInput([first])
        try await waitUntil("a.png shown with its folder scanned", timeout: .seconds(60)) {
            controller.session.imageStatus == .showing && controller.session.imageLoader.fileURL == self.first
                && controller.session.folderScan?.sourceSnapshot?.isComplete == true
        }
        return controller
    }

    func item(_ identifier: String) throws -> NSMenuItem {
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        let main = try #require(NSApp.mainMenu)
        let found = all(main).first { $0.accessibilityIdentifier() == identifier }
        return try #require(found, "menu item \(identifier)")
    }

    func enabled(_ identifier: String) throws -> Bool { menu.validateMenuItem(try item(identifier)) }

    func perform(_ identifier: String) throws {
        let item = try item(identifier)
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws {
        let window = try #require(controller.window)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    func mark(_ rect: CGRect = CGRect(x: 100, y: 100, width: 200, height: 200)) {
        controller.session.addAnnotationMark(AnnotationMark(rect: rect))
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    func close() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        controller?.annotateSaveTask?.cancel()
        if let sheet = views(AnnotateLeaveSheetView.self).first { sheet.discardButton.performClick(nil) }
        if let controller, controller.session.isAnnotating {
            ui.answer = .discard
            _ = controller.windowShouldClose(controller.window!)
        }
        controller?.window?.close()
        NSApp.mainMenu = previousMenu
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: base)
    }
}

/// sRGB bytes of one pixel, top-left origin.
private func issue690Pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4)
    let context = try #require(CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
    return Array(bytes.prefix(3))
}

private func issue690Image(_ url: URL) throws -> CGImage {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// The mark's left edge at (100, 150) is drawn in page 39's fixed red #dc2626 (B7, #690 WI-5); the centre (200, 200)
/// keeps the original.
private func issue690ExpectFlattened(_ image: CGImage, original: CGImage) throws {
    #expect(image.width == original.width && image.height == original.height)
    let edge = try issue690Pixel(image, x: 100, y: 150)
    #expect(abs(Int(edge[0]) - 220) <= 4 && abs(Int(edge[1]) - 38) <= 4 && abs(Int(edge[2]) - 38) <= 4, "mark edge \(edge)")
    let centre = try issue690Pixel(image, x: 200, y: 200), originalCentre = try issue690Pixel(original, x: 200, y: 200)
    #expect(centre == originalCentre)
}

@MainActor @Suite(.serialized) struct Issue690AnnotateModeTests {
    @Test(.timeLimit(.minutes(3))) func issue690CommandEEntersAndEscapeExits() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        #expect(try context.enabled("annotate.enter.menu"))
        #expect(try context.item("annotate.enter.menu").keyEquivalent == "e")
        try context.perform("annotate.enter.menu")
        #expect(controller.session.isAnnotating)
        #expect(try !context.enabled("annotate.enter.menu"))
        // R picks the rectangle tool; ← and → never change the image.
        try context.key("r", code: 15)
        #expect(controller.session.annotateMode?.tool == .rectangle)
        try context.key(String(UnicodeScalar(NSRightArrowFunctionKey)!), code: 124, modifiers: [.numericPad, .function])
        try context.key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: 123, modifiers: [.numericPad, .function])
        #expect(controller.session.imageLoader.fileURL == context.first)
        #expect(controller.session.isAnnotating)
        // With unsaved marks Esc asks; 取消 keeps the marks.
        context.mark()
        context.ui.answer = .cancel
        try context.key("\u{1b}", code: 53)
        #expect(context.ui.asked == [.escape])
        #expect(controller.session.annotateMode?.document.marks.count == 1)
        // 不存储 leaves; without marks Esc leaves at once.
        context.ui.answer = .discard
        try context.key("\u{1b}", code: 53)
        #expect(!controller.session.isAnnotating)
        try context.perform("annotate.enter.menu")
        try context.key("\u{1b}", code: 53)
        #expect(!controller.session.isAnnotating)
        #expect(context.ui.asked == [.escape, .escape])
        // Outside Annotate Mode R starts nothing and browsing is back.
        try context.key("r", code: 15)
        #expect(!controller.session.isAnnotating)
        #expect(controller.session.isEnabled(.next))
    }

    @Test(.timeLimit(.minutes(3))) func issue690BrowsingMenuItemsDisabled() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        #expect(try context.enabled("command.next.menu"))
        #expect(try !context.enabled("annotate.save.menu"))
        #expect(try context.item("annotate.save.menu").keyEquivalent == "s")
        controller.enterAnnotateMode()
        for id in ["command.next.menu", "command.previous.menu", "command.open.menu", "annotate.save.menu"] {
            #expect(try !context.enabled(id), "\(id) while annotating without marks")
        }
        context.mark()
        #expect(try context.enabled("annotate.save.menu"))
        #expect(try !context.enabled("command.next.menu"))
    }

    @Test(.timeLimit(.minutes(3))) func issue690UndoRedoAndCopyFollowTheDocument() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        let undo = NSMenuItem(title: "Undo", action: #selector(CanvasWindowController.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(CanvasWindowController.redo(_:)), keyEquivalent: "z")
        let copy = NSMenuItem(title: "Copy", action: #selector(CanvasWindowController.copy(_:)), keyEquivalent: "c")
        #expect(!controller.validateMenuItem(copy) && !controller.validateMenuItem(undo))
        controller.enterAnnotateMode()
        #expect(controller.validateMenuItem(copy))
        #expect(!controller.validateMenuItem(undo) && !controller.validateMenuItem(redo))
        context.mark()
        #expect(controller.validateMenuItem(undo) && !controller.validateMenuItem(redo))
        controller.undo(nil)
        #expect(controller.session.annotateMode?.document.marks.isEmpty == true)
        #expect(controller.validateMenuItem(redo))
        controller.redo(nil)
        #expect(controller.session.annotateMode?.document.marks.count == 1)
    }

    @Test(.timeLimit(.minutes(3))) func issue690CopyPutsFlattenedImageOnPasteboard() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.mark()
        let before = try context.names()
        controller.copy(nil)
        try await waitUntil("pasteboard holds an image", timeout: .seconds(60)) {
            context.pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
        }
        let image = try #require(NSImage(pasteboard: context.pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        try issue690ExpectFlattened(image, original: issue690Image(context.first))
        #expect(try context.names() == before)
        #expect(controller.session.annotateMode?.needsPrompt == true)
    }

    @Test(.timeLimit(.minutes(3))) func issue690SaveTwiceWritesAnnotatedAndAnnotated2() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        let original = try Data(contentsOf: context.first)
        controller.enterAnnotateMode()
        context.mark()
        try context.perform("annotate.save.menu")
        try await waitUntil("first copy saved", timeout: .seconds(60)) { context.ui.saved.count == 1 }
        let copy = context.folder.appendingPathComponent("a-annotated.png")
        #expect(context.ui.saved.map(\.standardizedFileURL) == [copy.standardizedFileURL])
        try issue690ExpectFlattened(issue690Image(copy), original: issue690Image(context.first))
        #expect(controller.session.isAnnotating)
        #expect(controller.session.annotateMode?.needsPrompt == false)
        #expect(controller.session.imageLoader.fileURL == context.first)
        context.mark(CGRect(x: 20, y: 20, width: 40, height: 40))
        controller.saveAnnotatedCopy()
        try await waitUntil("second copy saved", timeout: .seconds(60)) { context.ui.saved.count == 2 }
        #expect(context.ui.saved.last?.lastPathComponent == "a-annotated-2.png")
        #expect(try context.names() == ["a-annotated-2.png", "a-annotated.png", "a.png", "b.png"])
        #expect(try Data(contentsOf: context.first) == original)
        #expect(context.ui.panelRequests.isEmpty && context.ui.failures.isEmpty)
        // The Preview Set is unchanged: → stays on a.png while annotating.
        #expect(controller.session.imageLoader.fileURL == context.first)
    }

    @Test(.timeLimit(.minutes(3))) func issue690UnwritableFolderFallsBackToPanel() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        let elsewhere = context.base.appendingPathComponent("Out")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: context.folder.path)
        controller.enterAnnotateMode()
        context.mark()
        // The panel is cancelled: the refusal is reported and the marks stay unsaved.
        controller.saveAnnotatedCopy()
        try await waitUntil("refusal reported", timeout: .seconds(60)) { context.ui.failures == [.permissionDenied] }
        #expect(context.ui.panelRequests.count == 1)
        #expect(context.ui.panelRequests.first?.folder.standardizedFileURL == context.folder.standardizedFileURL)
        #expect(context.ui.panelRequests.first?.name == "a-annotated.png")
        #expect(context.ui.panelRequests.first?.type == .png)
        #expect(controller.session.annotateMode?.directRefused == true)
        #expect(controller.session.annotateMode?.needsPrompt == true)
        // The next ⌘S goes straight to the panel and writes the chosen file.
        let chosen = elsewhere.appendingPathComponent("chosen.png")
        context.ui.panelChoice = chosen
        controller.saveAnnotatedCopy()
        try await waitUntil("panel copy saved", timeout: .seconds(60)) { context.ui.saved.count == 1 }
        #expect(context.ui.saved == [chosen])
        #expect(context.ui.panelRequests.count == 2)
        try issue690ExpectFlattened(issue690Image(chosen), original: issue690Image(context.first))
        #expect(try context.names() == ["a.png", "b.png"])
        #expect(controller.session.annotateMode?.needsPrompt == false)
    }

    @Test(.timeLimit(.minutes(3))) func issue690SourceDeletedReportsAndStays() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.mark()
        try FileManager.default.removeItem(at: context.first)
        controller.saveAnnotatedCopy()
        try await waitUntil("missing original reported", timeout: .seconds(60)) { !context.ui.failures.isEmpty }
        #expect(context.ui.failures == [.sourceMissing])
        #expect(controller.session.isAnnotating)
        #expect(controller.session.annotateMode?.needsPrompt == true)
        #expect(try context.names() == ["b.png"])
    }

    @Test(.timeLimit(.minutes(3))) func issue690CloseAsksAndFollowsTheAnswer() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        let window = try #require(controller.window)
        controller.enterAnnotateMode()
        #expect(controller.windowShouldClose(window) == true, "no marks: close at once")
        #expect(!controller.session.isAnnotating && context.ui.asked.isEmpty)
        controller.enterAnnotateMode()
        context.mark()
        context.ui.answer = .cancel
        #expect(controller.windowShouldClose(window) == false)
        #expect(context.ui.asked == [.closeWindow])
        #expect(controller.session.annotateMode?.document.marks.count == 1)
        // 存储 writes the copy, then closes the window.
        context.ui.answer = .save
        var closed = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                              queue: nil) { _ in MainActor.assumeIsolated { closed = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        #expect(controller.windowShouldClose(window) == false)
        try await waitUntil("saved, then closed", timeout: .seconds(60)) { closed }
        #expect(context.ui.saved.map(\.lastPathComponent) == ["a-annotated.png"])
        #expect(!controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue690CloseDiscardCloses() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        let window = try #require(controller.window)
        controller.enterAnnotateMode()
        context.mark()
        context.ui.answer = .discard
        #expect(controller.windowShouldClose(window) == true)
        #expect(context.ui.asked == [.closeWindow])
        #expect(!controller.session.isAnnotating)
        #expect(try context.names() == ["a.png", "b.png"])
    }

    @Test(.timeLimit(.minutes(3))) func issue690QuitAsksAndReplies() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        #expect(controller.annotateShouldTerminate() == .terminateNow)
        controller.enterAnnotateMode()
        context.mark()
        #expect(controller.annotateShouldTerminate() == .terminateLater)
        #expect(context.ui.asked == [.quitApp])
        let cancel = try #require(context.ui.pending)
        cancel(.cancel)
        #expect(context.replies == [false])
        #expect(controller.session.isAnnotating)
        #expect(controller.annotateShouldTerminate() == .terminateLater)
        let discard = try #require(context.ui.pending)
        discard(.discard)
        #expect(context.replies == [false, true])
        #expect(!controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue690ExternalOpenAsksAndCancelKeeps() async throws {
        let context = try await Issue690Context()
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        context.mark()
        context.ui.answer = .cancel
        controller.openInput([context.second])
        #expect(context.ui.asked == [.changeImage])
        #expect(controller.session.isAnnotating)
        #expect(controller.session.imageLoader.fileURL == context.first)
        context.ui.answer = .discard
        controller.openInput([context.second])
        #expect(context.ui.asked == [.changeImage, .changeImage])
        #expect(!controller.session.isAnnotating)
        try await waitUntil("b.png opened after 不存储", timeout: .seconds(60)) { controller.session.imageLoader.fileURL == context.second }
    }
}

// MARK: - #690 WI-6: page 39 in the viewer window

/// A lossless mid-grey PNG of `size`.
private func issue690GreyPNG(_ size: CGSize) throws -> Data {
    let width = Int(size.width), height = Int(size.height)
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private let page39Size = CGSize(width: 1600, height: 2400)
private let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
private let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)

private func issue690Near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

extension Issue690Context {
    var content: NSView { controller.window!.contentView! }

    /// Every view of `type` under the window's content view.
    func views<T: NSView>(_ type: T.Type) -> [T] {
        guard let root = controller?.window?.contentView else { return [] }
        func walk(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(walk) }
        return walk(root)
    }

    /// A view's frame in the content view, origin at the top left.
    func topLeft(_ view: NSView) -> CGRect {
        let rect = content.convert(view.bounds, from: view)
        return content.isFlipped ? rect : CGRect(x: rect.minX, y: content.bounds.height - rect.maxY,
                                                 width: rect.width, height: rect.height)
    }

    /// The shown image's frame in the canvas (top left).
    func imageRect() throws -> CGRect {
        let canvas = try #require(views(CanvasView.self).first)
        let frame = canvas.backdropFrame
        let a = frame.transform.imageToView(.zero)
        let b = frame.transform.imageToView(CGPoint(x: frame.sourceSize.width, y: frame.sourceSize.height))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    func expectImage(_ rect: CGRect, _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) throws {
        let found = try imageRect()
        #expect(issue690Near(found, rect), "\(note) \(found)", sourceLocation: sourceLocation)
    }

    func strip() throws -> AnnotateStripView { try #require(views(AnnotateStripView.self).first, "the strip is shown") }
    func overlay() throws -> AnnotationOverlayView { try #require(views(AnnotationOverlayView.self).first, "the overlay") }
    func sheet() throws -> AnnotateLeaveSheetView { try #require(views(AnnotateLeaveSheetView.self).first, "the sheet") }

    func mouse(_ view: NSView, _ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: 0, windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1))
    }

    /// A drag on the overlay between two of its (top-left) points.
    func drag(from a: CGPoint, to b: CGPoint) throws {
        let view = try overlay()
        view.mouseDown(with: try mouse(view, .leftMouseDown, a))
        view.mouseDragged(with: try mouse(view, .leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)))
        view.mouseDragged(with: try mouse(view, .leftMouseDragged, b))
        view.mouseUp(with: try mouse(view, .leftMouseUp, b))
    }

    func click(_ point: CGPoint) throws { try drag(from: point, to: point) }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: file(name).path) }

    func arrow(_ characters: String, shift: Bool = false) throws {
        try key(characters, code: characters == rightArrow ? 124 : 123,
                modifiers: shift ? [.numericPad, .function, .shift] : [.numericPad, .function])
    }

    /// Lets a navigation the key may have started reach the loader.
    func settle() async throws { try await Task.sleep(for: .milliseconds(400)) }
}

/// Page 39's rectangle drawn by the drag (400,200)→(500,300) at zoom 0.32, origin (352, 16).
private let page39DragRect = CGRect(x: 150, y: 575, width: 312.5, height: 312.5)

private func issue690CatalogValue(_ key: String, _ language: String) throws -> String {
    let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("App/Resources/Localizable.xcstrings")
    let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let strings = try #require(root["strings"] as? [String: Any])
    let entry = try #require(strings[key] as? [String: Any], "catalog key \(key)")
    let localizations = try #require(entry["localizations"] as? [String: Any], "\(key) localizations")
    let localized = try #require(localizations[language] as? [String: Any], "\(key) \(language)")
    let unit = try #require(localized["stringUnit"] as? [String: Any])
    return try #require(unit["value"] as? String)
}

@MainActor @Suite(.serialized) struct Issue690AnnotateWindowTests {
    @Test(.timeLimit(.minutes(3))) func issue690WindowFitStripAndRoundTrip() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let chrome = try #require(context.views(ViewerChromeOverlay.self).first)
        let chromeHidden = chrome.isHidden
        try context.expectImage(CGRect(x: 384, y: 16, width: 512, height: 768))
        try context.perform("annotate.enter.menu")
        try context.expectImage(CGRect(x: 352, y: 16, width: 512, height: 768))
        let strip = try context.strip()
        #expect(issue690Near(context.topLeft(strip), CGRect(x: 1220, y: 146, width: 48, height: 508)), "\(context.topLeft(strip))")
        #expect(strip.superview === context.content)
        let overlay = try context.overlay()
        #expect(overlay.isActive && context.topLeft(overlay) == context.content.bounds)
        #expect(chrome.isHidden, "the viewer chrome steps aside for page 39")
        try context.key("\u{1b}", code: 53)
        #expect(!controller.session.isAnnotating)
        try context.expectImage(CGRect(x: 384, y: 16, width: 512, height: 768))
        #expect(strip.superview == nil && overlay.superview == nil)
        #expect(context.views(AnnotateStripView.self).isEmpty && context.views(AnnotationOverlayView.self).isEmpty)
        #expect(chrome.isHidden == chromeHidden)
    }

    @Test(.timeLimit(.minutes(3))) func issue690WindowResizeKeepsReserve() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        let window = try #require(controller.window)
        controller.enterAnnotateMode()
        window.setContentSize(NSSize(width: 1440, height: 900))
        try context.expectImage(CGRect(x: 398.67, y: 16, width: 578.67, height: 868))
        #expect(issue690Near(context.topLeft(try context.strip()), CGRect(x: 1380, y: 196, width: 48, height: 508)))
        window.setContentSize(NSSize(width: 1280, height: 480))
        let short = context.topLeft(try context.strip())
        #expect(issue690Near(short, CGRect(x: 1220, y: 12, width: 48, height: 456)), "\(short)")
        #expect(try context.imageRect().maxX <= 1280 - 64 + 1, "the image never runs under the strip")
    }

    @Test(.timeLimit(.minutes(3))) func issue690LeaveAfterResizeRefits() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try #require(controller.window).setContentSize(NSSize(width: 1440, height: 900))
        try context.key("\u{1b}", code: 53)
        #expect(!controller.session.isAnnotating)
        try context.expectImage(CGRect(x: 430.67, y: 16, width: 578.67, height: 868))
    }

    @Test(.timeLimit(.minutes(3))) func issue690DragOnOverlayAddsSelectedMark() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let state = try #require(controller.session.annotateMode)
        #expect(state.document.marks.map(\.rect) == [page39DragRect])
        #expect(state.document.marks.first.map { abs($0.style.lineWidth - 9.375) < 1e-9 } == true)
        #expect(state.selectedMark == 0)
        #expect(try context.overlay().marks == state.document.marks, "the overlay shows the session's marks")
    }

    @Test(.timeLimit(.minutes(3))) func issue690VClickArrowNudgesWithoutChangingImage() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("v", code: 9)
        #expect(controller.session.annotateMode?.tool == .select)
        try context.click(CGPoint(x: 300, y: 700))
        #expect(controller.session.annotateMode?.selectedMark == nil)
        try context.click(CGPoint(x: 450, y: 250))
        #expect(controller.session.annotateMode?.selectedMark == 0)
        try context.arrow(rightArrow)
        #expect(controller.session.annotateMode?.document.marks.first?.rect.minX == 151)
        try context.arrow(rightArrow, shift: true)
        #expect(controller.session.annotateMode?.document.marks.first?.rect.minX == 161)
        try context.arrow(leftArrow)
        #expect(controller.session.annotateMode?.document.marks.first?.rect.minX == 160)
        #expect(try context.overlay().marks.first?.rect.minX == 160)
        try await context.settle()
        #expect(controller.session.imageLoader.fileURL == context.first)
        for _ in 0..<3 { #expect(controller.session.undoAnnotation()) }
        #expect(controller.session.annotateMode?.document.marks.map(\.rect) == [page39DragRect])
    }

    @Test(.timeLimit(.minutes(3))) func issue690ArrowWithoutSelectionChangesNothing() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("v", code: 9)
        try context.click(CGPoint(x: 300, y: 700))
        try context.arrow(rightArrow)
        try await context.settle()
        #expect(controller.session.annotateMode?.document.marks.map(\.rect) == [page39DragRect])
        #expect(controller.session.imageLoader.fileURL == context.first)
        #expect(controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue690KeysReleasedAfterLeaving() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        try context.key("\u{1b}", code: 53)
        #expect(!controller.session.isAnnotating)
        try context.arrow(rightArrow)
        try await waitUntil("→ browses again", timeout: .seconds(60)) {
            // Folder navigation loads the scanned (resolved, /private/var) URL.
            controller.session.imageLoader.fileURL?.resolvingSymlinksInPath() == context.second.resolvingSymlinksInPath()
        }
        try context.key("v", code: 9)
        #expect(controller.session.annotateMode == nil)
    }

    @Test(.timeLimit(.minutes(3))) func issue690StripButtonsDriveSession() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        let strip = try context.strip()
        strip.button(.select).performClick(nil)
        #expect(controller.session.annotateMode?.tool == .select)
        strip.button(.rectangle).performClick(nil)
        #expect(controller.session.annotateMode?.tool == .rectangle)
        strip.button(.arrow).performClick(nil)
        #expect(controller.session.annotateMode?.tool == .rectangle, "a tool owned by #692 stays disabled")
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        strip.button(.undo).performClick(nil)
        #expect(controller.session.annotateMode?.document.marks == [])
        strip.button(.redo).performClick(nil)
        #expect(controller.session.annotateMode?.document.marks.map(\.rect) == [page39DragRect])
        strip.button(.copy).performClick(nil)
        try await waitUntil("the strip's Copy fills the pasteboard", timeout: .seconds(60)) {
            NSImage(pasteboard: context.pasteboard) != nil
        }
        let copied = try #require(NSImage(pasteboard: context.pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(copied.width == 1600 && copied.height == 2400)
        let edge = try issue690Pixel(copied, x: 150, y: 700)
        #expect(abs(Int(edge[0]) - 220) <= 2 && abs(Int(edge[1]) - 38) <= 2 && abs(Int(edge[2]) - 38) <= 2, "copied edge \(edge)")
        strip.button(.save).performClick(nil)
        try await waitUntil("the strip's Save writes the copy", timeout: .seconds(60)) {
            context.exists("a-annotated.png") && controller.session.annotateMode?.isSaving == false
        }
        strip.button(.done).performClick(nil)
        #expect(!controller.session.isAnnotating, "Done leaves at once when every mark is saved")
    }

    @Test(.timeLimit(.minutes(3))) func issue690StripFollowsKeys() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open()
        controller.enterAnnotateMode()
        let strip = try context.strip()
        #expect(strip.button(.rectangle).state == .on && strip.button(.select).state == .off)
        #expect(!strip.button(.undo).isEnabled)
        try context.key("v", code: 9)
        #expect(strip.button(.select).state == .on && strip.button(.rectangle).state == .off)
        try context.key("r", code: 15)
        #expect(strip.button(.rectangle).state == .on && strip.button(.select).state == .off)
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        #expect(strip.button(.undo).isEnabled && strip.button(.save).isEnabled)
        try context.key("z", code: 6, modifiers: [.command])
        #expect(controller.session.annotateMode?.document.marks == [])
        #expect(!strip.button(.undo).isEnabled && strip.button(.redo).isEnabled)
    }

    @Test(.timeLimit(.minutes(3))) func issue690SaveShowsConfirmationAndStays() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.perform("annotate.save.menu")
        try await waitUntil("saved with the confirmation", timeout: .seconds(60)) {
            !context.views(AnnotateSaveConfirmationView.self).isEmpty
        }
        #expect(context.exists("a-annotated.png"))
        let confirmation = try #require(context.views(AnnotateSaveConfirmationView.self).first)
        let frame = context.topLeft(confirmation)
        #expect(frame.height == 36 && abs(frame.minY - 12) <= 1 && abs(frame.midX - 608) <= 1, "\(frame)")
        #expect(confirmation.messageField.stringValue.contains("a-annotated.png"))
        #expect(controller.session.isAnnotating)
        try #require(controller.window).setContentSize(NSSize(width: 1440, height: 900))
        #expect(abs(context.topLeft(confirmation).midX - 688) <= 1, "\(context.topLeft(confirmation))")
    }

    @Test(.timeLimit(.minutes(3))) func issue690SecondSaveReplacesConfirmation() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        controller.saveAnnotatedCopy()
        try await waitUntil("first confirmation", timeout: .seconds(60)) {
            !context.views(AnnotateSaveConfirmationView.self).isEmpty
        }
        try context.drag(from: CGPoint(x: 600, y: 200), to: CGPoint(x: 700, y: 300))
        #expect(context.views(AnnotateSaveConfirmationView.self).isEmpty, "a new mark dismisses the confirmation")
        controller.saveAnnotatedCopy()
        try await waitUntil("second confirmation", timeout: .seconds(60)) {
            !context.views(AnnotateSaveConfirmationView.self).isEmpty
        }
        #expect(context.exists("a-annotated-2.png"))
        let confirmations = context.views(AnnotateSaveConfirmationView.self)
        #expect(confirmations.count == 1)
        #expect(confirmations.first?.messageField.stringValue.contains("a-annotated-2.png") == true)
    }

    @Test(.timeLimit(.minutes(3))) func issue690RevealReceivesSavedURL() async throws {
        let context = try await Issue690Context(size: page39Size, existing: ["a-annotated.png"])
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        var revealed: [URL] = []
        controller.annotateRevealInFinder = { revealed.append($0) }
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        controller.saveAnnotatedCopy()
        try await waitUntil("confirmation", timeout: .seconds(60)) {
            !context.views(AnnotateSaveConfirmationView.self).isEmpty
        }
        try #require(context.views(AnnotateSaveConfirmationView.self).first).revealButton.performClick(nil)
        let expected = context.file("a-annotated-2.png").resolvingSymlinksInPath()
        #expect(revealed.map { $0.resolvingSymlinksInPath() } == [expected])
        #expect(context.exists("a-annotated-2.png"))
    }

    @Test(.timeLimit(.minutes(3))) func issue690ConfirmationDismissals() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        controller.saveAnnotatedCopy()
        try await waitUntil("confirmation", timeout: .seconds(60)) {
            !context.views(AnnotateSaveConfirmationView.self).isEmpty
        }
        try #require(context.views(AnnotateSaveConfirmationView.self).first).closeButton.performClick(nil)
        #expect(context.views(AnnotateSaveConfirmationView.self).isEmpty)
        #expect(controller.session.isAnnotating)
        try context.drag(from: CGPoint(x: 600, y: 200), to: CGPoint(x: 700, y: 300))
        controller.saveAnnotatedCopy()
        try await waitUntil("confirmation again", timeout: .seconds(60)) {
            !context.views(AnnotateSaveConfirmationView.self).isEmpty
        }
        try context.strip().button(.done).performClick(nil)
        #expect(!controller.session.isAnnotating)
        #expect(context.views(AnnotateSaveConfirmationView.self).isEmpty, "the confirmation never outlives the mode")
    }

    @Test(.timeLimit(.minutes(3))) func issue690EscShowsInWindowSheet() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        let window = try #require(controller.window)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("\u{1b}", code: 53)
        #expect(window.attachedSheet == nil, "page 39's sheet lives in the window, not as an NSAlert")
        let sheet = try context.sheet()
        let panel = context.topLeft(sheet.panel)
        #expect(panel.width == 400 && panel.minY == 0 && abs(panel.midX - 640) <= 1, "\(panel)")
        #expect(context.topLeft(sheet.scrim) == context.content.bounds)
        #expect(sheet.titleField.stringValue.contains("a.png"))
        #expect(sheet.bodyField.stringValue.contains("a-annotated.png"))
        #expect(controller.session.isAnnotating)
    }

    @Test(.timeLimit(.minutes(3))) func issue690SheetPlannedNameFromListing() async throws {
        let context = try await Issue690Context(size: page39Size, existing: ["a-annotated.png"])
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("\u{1b}", code: 53)
        let body = try context.sheet().bodyField.stringValue
        #expect(body.contains("a-annotated-2.png"), "\(body)")
    }

    @Test(.timeLimit(.minutes(3))) func issue690SheetBlocksKeysAndMenus() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("v", code: 9)
        try context.click(CGPoint(x: 450, y: 250))
        let marks = try #require(controller.session.annotateMode?.document.marks)
        try context.key("\u{1b}", code: 53)
        _ = try context.sheet()
        #expect(try !context.enabled("annotate.enter.menu"))
        #expect(try !context.enabled("annotate.save.menu"))
        for action in [#selector(CanvasWindowController.undo(_:)), #selector(CanvasWindowController.copy(_:))] {
            #expect(!controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")), "\(action)")
        }
        try context.key("r", code: 15)
        #expect(controller.session.annotateMode?.tool == .select)
        try context.arrow(rightArrow)
        try context.key("z", code: 6, modifiers: [.command])
        controller.undo(nil)
        #expect(controller.session.annotateMode?.document.marks == marks)
        try await context.settle()
        #expect(controller.session.imageLoader.fileURL == context.first)
        // Esc answers 取消.
        try context.key("\u{1b}", code: 53)
        #expect(context.views(AnnotateLeaveSheetView.self).isEmpty)
        #expect(controller.session.isAnnotating && controller.session.annotateMode?.document.marks == marks)
    }

    @Test(.timeLimit(.minutes(3))) func issue690SheetScrimIsTopmost() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        let undo = try context.strip().button(.undo)
        try context.key("\u{1b}", code: 53)
        let sheet = try context.sheet()
        let frame = try #require(context.content.superview)
        let undoCentre = frame.convert(CGPoint(x: undo.bounds.midX, y: undo.bounds.midY), from: undo)
        let canvasPoint = frame.convert(CGPoint(x: 608, y: 400), from: try context.overlay())
        for point in [undoCentre, canvasPoint] {
            let hit = try #require(context.content.hitTest(point))
            #expect(hit === sheet || hit.isDescendant(of: sheet), "\(hit)")
        }
        #expect(controller.session.annotateMode?.document.marks.count == 1)
    }

    @Test(.timeLimit(.minutes(3))) func issue690SheetChoices() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("\u{1b}", code: 53)
        try context.sheet().cancelButton.performClick(nil)
        #expect(context.views(AnnotateLeaveSheetView.self).isEmpty)
        #expect(controller.session.isAnnotating && controller.session.annotateMode?.document.marks.count == 1)
        try context.key("\u{1b}", code: 53)
        try context.sheet().discardButton.performClick(nil)
        #expect(!controller.session.isAnnotating)
        #expect(try context.names() == ["a.png", "b.png"])
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("\u{1b}", code: 53)
        try context.sheet().saveButton.performClick(nil)
        try await waitUntil("saved, then left", timeout: .seconds(60)) { !controller.session.isAnnotating }
        #expect(context.exists("a-annotated.png"))
        #expect(context.views(AnnotateLeaveSheetView.self).isEmpty)
    }

    @Test(.timeLimit(.minutes(3))) func issue690EveryExitTearsDown() async throws {
        let context = try await Issue690Context(size: page39Size)
        defer { context.close() }
        let controller = try await context.open(fakeUI: false)
        func expectTornDown(_ exit: String) throws {
            #expect(!controller.session.isAnnotating, "\(exit)")
            #expect(context.views(AnnotateStripView.self).isEmpty && context.views(AnnotationOverlayView.self).isEmpty,
                    "\(exit)")
            try context.expectImage(CGRect(x: 384, y: 16, width: 512, height: 768), exit)
        }
        controller.enterAnnotateMode()
        try context.strip().button(.done).performClick(nil)
        try expectTornDown("Done")
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.strip().button(.done).performClick(nil)
        try context.sheet().discardButton.performClick(nil)
        try expectTornDown("Don't Save")
        controller.enterAnnotateMode()
        try context.drag(from: CGPoint(x: 400, y: 200), to: CGPoint(x: 500, y: 300))
        try context.key("\u{1b}", code: 53)
        try context.sheet().saveButton.performClick(nil)
        try await waitUntil("saved, then left", timeout: .seconds(60)) { !controller.session.isAnnotating }
        try expectTornDown("Save")
    }

    @Test(.timeLimit(.minutes(1))) func issue690CatalogZhHans() throws {
        let expected: [String: String] = [
            "Select": "选择", "Arrow": "箭头", "Rectangle": "矩形", "Text": "文字", "Highlighter": "荧光笔",
            "Pen": "画笔", "Redact": "遮挡", "Crop": "裁剪", "Step": "序号", "Undo": "撤销", "Redo": "重做",
            "Copy": "拷贝", "Save": "存储", "Done": "完成", "Saved as %@": "已存储为 %@",
            "Show in Finder": "在访达中显示", "Close": "关闭", "Don't Save": "不存储", "Cancel": "取消",
            "Annotation Tools": "标注工具",
            "Save the annotations on “%@”?": "要存储对“%@”的标注吗？",
            "Save keeps the original unchanged and saves a copy as %@. Don't Save discards these marks.":
                "存储会另存为 %@，原图不变。不存储则丢弃这些标记。",
        ]
        for (key, value) in expected {
            let found = try issue690CatalogValue(key, "zh-Hans")
            #expect(found == value, "\(key)")
            #expect(!found.contains("即将推出"), "\(key): tools owned by #692/#693 are disabled, not labelled")
        }
    }
}
