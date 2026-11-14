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

    init() async throws {
        previousMenu = NSApplication.shared.mainMenu
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder = base.appendingPathComponent("Trip")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/portrait-2x3.png")
        first = folder.appendingPathComponent("a.png")
        second = folder.appendingPathComponent("b.png")
        try Data(contentsOf: fixture).write(to: first)
        try Data(contentsOf: fixture).write(to: second)
        let scope = SystemSecurityScope()
        let access = try FileAccess(scope: scope, bookmarks: scope,
            store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue690")
        _ = try await access.grant(folder: folder)
        services = AccessServices(files: access, recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
            browser: FolderBrowser(), watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    }

    func open() async throws -> CanvasWindowController {
        let controller = CanvasWindowController(pipeline: ImageIOPipeline(), preferencesStore: InMemoryDisplayPreferencesStore(),
            accessServices: Task { self.services }, motionPolicy: MotionPolicy(source: Issue349Motion()))
        self.controller = controller
        controller.annotateUI = ui
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
