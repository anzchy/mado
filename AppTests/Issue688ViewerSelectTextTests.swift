import AppKit
import Testing
import MadoApplication
import MadoCore

private actor SelectRecognitionProbe {
    private(set) var calls = 0
    private var releaseFirst: CheckedContinuation<Void, Never>?
    private var released = false
    func result() async -> TextRecognitionResult {
        calls += 1
        if calls == 1 && !released {
            await withCheckedContinuation { releaseFirst = $0 }
        }
        let lines = calls == 1
            ? [TextRecognitionLine(text: "Hello", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1))]
            : []
        return TextRecognitionResult(text: lines.map(\.text).joined(), characterCount: lines.first?.text.count ?? 0,
                                     engine: .onDevice, isEmpty: lines.isEmpty, lines: lines)
    }
    func release() { released = true; releaseFirst?.resume(); releaseFirst = nil }
}

private actor EmptySelectionProbe {
    private(set) var calls = 0
    func result() -> TextRecognitionResult {
        calls += 1
        return TextRecognitionResult(text: "", characterCount: 0, engine: .onDevice, isEmpty: true)
    }
}

@Suite(.serialized) struct Issue688ViewerSelectTextTests {
@MainActor @Test(.timeLimit(.minutes(3))) func issue688SelectionCopyFailurePreservesClipboard() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let board = NSPasteboard(name: .init("mado.issue688.failed-copy.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("sentinel", forType: .string)
    controller.selectTextAdapter.pasteboard = board
    controller.selectTextAdapter.makeTextPasteboard = { board in
        NativeTextPasteboard(board, writeObjects: { target, objects in
            if target === board && (objects.first as? NSPasteboardItem)?.string(forType: .string) == "Hello" { return false }
            return target.writeObjects(objects)
        })
    }
    controller.selectTextAdapter.selection.lines = [TextRecognitionLine(
        text: "Hello", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1))]
    controller.selectTextAdapter.selection.geometry = ImageTextGeometry(
        transform: controller.canvas.backdropFrame.transform,
        imageSize: controller.canvas.backdropFrame.sourceSize)
    let box = controller.selectTextAdapter.selection.geometry.viewRect(CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1))
    #expect(controller.selectTextAdapter.selection.begin(at: CGPoint(x: box.minX + 1, y: box.midY)))
    controller.selectTextAdapter.selection.drag(to: CGPoint(x: box.maxX - 1, y: box.midY))
    #expect(!controller.selectTextAdapter.copy())
    #expect(board.string(forType: .string) == "sentinel")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue688LateRecognitionAfterItemSwitchIsDropped() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let probe = SelectRecognitionProbe()
    controller.selectTextAdapter.cancel()
    controller.selectTextAdapter.recognise = { _, intent in
        #expect(intent == .selectOnImage)
        return await probe.result()
    }
    controller.selectTextAdapter.backdropChanged(controller.canvas.backdropFrame)
    for _ in 0..<500 {
        if await probe.calls > 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.calls == 1, "phase=\(controller.session.imageLoader.phase) image=\(controller.canvas.backdropFrame.image != nil) presented=\(controller.session.imageLoader.presented != nil) grid=\(controller.gridShellVisible)")
    controller.openInput([context.second])
    try await waitUntil("second image shown", timeout: .seconds(30)) {
        controller.session.imageLoader.fileURL == context.second && controller.session.imageStatus == .showing
    }
    await probe.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.selectTextAdapter.selection.lines.isEmpty)
    #expect(controller.canvas.subviews.compactMap { $0 as? ImageTextSelectionOverlay }.allSatisfy {
        $0.selection?.selectionRects.isEmpty == true
    })
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue688WindowCloseCancelsPendingSelection() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let probe = SelectRecognitionProbe()
    controller.selectTextAdapter.cancel()
    controller.selectTextAdapter.recognise = { _, _ in await probe.result() }
    controller.selectTextAdapter.backdropChanged(controller.canvas.backdropFrame)
    for _ in 0..<500 {
        if await probe.calls == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.calls == 1)
    controller.window?.close()
    await probe.release()
    try await Task.sleep(for: .milliseconds(100))
    #expect(controller.selectTextAdapter.selection.lines.isEmpty)
    #expect(controller.canvas.subviews.compactMap { $0 as? ImageTextSelectionOverlay }.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue688AnnotateSuppressesRecognitionAndSelectionOverlay() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let probe = SelectRecognitionProbe()
    controller.selectTextAdapter.cancel()
    controller.selectTextAdapter.recognise = { _, _ in await probe.result() }
    controller.selectTextAdapter.backdropChanged(controller.canvas.backdropFrame)
    controller.enterAnnotateMode()
    try await Task.sleep(for: .milliseconds(650))
    #expect(controller.session.isAnnotating)
    #expect(await probe.calls == 0)
    #expect(controller.selectTextAdapter.selection.lines.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue688NoTextLeavesCanvasUnchanged() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let probe = EmptySelectionProbe()
    controller.selectTextAdapter.cancel()
    controller.selectTextAdapter.recognise = { _, _ in await probe.result() }
    controller.selectTextAdapter.backdropChanged(controller.canvas.backdropFrame)
    for _ in 0..<500 {
        if await probe.calls == 1 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await probe.calls == 1)
    #expect(controller.selectTextAdapter.selection.lines.isEmpty)
    #expect(controller.canvas.subviews.compactMap { $0 as? ImageTextSelectionOverlay }.isEmpty)
    #expect(!controller.selectTextAdapter.pointer(CGPoint(x: 100, y: 100)))
    controller.selectTextAdapter.backdropChanged(controller.canvas.backdropFrame)
    try await Task.sleep(for: .milliseconds(550))
    #expect(await probe.calls == 1, "an empty result is retained only for the shown item")
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue688CopySelectionAndLegacyNoSelection() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let board = NSPasteboard(name: .init("mado.issue688.select.\(UUID().uuidString)"))
    defer { board.releaseGlobally() }
    controller.selectTextAdapter.pasteboard = board
    controller.selectTextAdapter.cancel()
    board.clearContents(); board.setString("sentinel", forType: .string)
    controller.canvas.copy(nil)
    #expect(board.string(forType: .string) == "sentinel", "viewer Copy without text selection retains its old behavior")
    controller.selectTextAdapter.selection.geometry = ImageTextGeometry(
        transform: controller.canvas.backdropFrame.transform,
        imageSize: controller.canvas.backdropFrame.sourceSize)
    controller.selectTextAdapter.selection.lines = [TextRecognitionLine(text: "Hello", box: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1))]
    let box = controller.selectTextAdapter.selection.geometry.viewRect(CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.1))
    #expect(controller.selectTextAdapter.selection.begin(at: CGPoint(x: box.minX + box.width * 0.1, y: box.midY)))
    controller.selectTextAdapter.selection.drag(to: CGPoint(x: box.maxX - 1, y: box.midY))
    _ = controller.window?.makeFirstResponder(controller.canvas)
    let window = try #require(controller.window)
    let shortcut = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "c",
        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
    func items(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(items) ?? []) } }
    let mainMenu = try #require(NSApp.mainMenu)
    let copyItem = try #require(items(mainMenu).first {
        $0.action == #selector(CanvasInputBridge.copy(_:)) && $0.keyEquivalent == "c"
    })
    #expect(shortcut.modifierFlags.contains(.command))
    let copyAction = try #require(copyItem.action)
    #expect(NSApp.sendAction(copyAction, to: controller.canvas, from: copyItem))
    try context.key("c", code: 8, modifiers: [.command])
    #expect(board.string(forType: .string) == "Hello", "⌘C copies selected image text")
    board.clearContents(); board.setString("sentinel", forType: .string)
    controller.canvas.copy(nil)
    #expect(board.string(forType: .string) == "Hello", "Edit Copy uses the same canvas action")
    let before = controller.selectTextAdapter.selection.selectionRects
    controller.canvas.magnify(by: 0.4, at: CGPoint(x: 320, y: 240))
    #expect(controller.selectTextAdapter.selection.selectedText == "Hello")
    #expect(controller.selectTextAdapter.selection.selectionRects != before)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue688PressOutsideTextKeepsCanvasPan() async throws {
    let context = try await Issue690Context()
    defer { context.close() }
    let controller = try await context.open()
    let canvas = controller.canvas
    controller.selectTextAdapter.cancel()
    controller.selectTextAdapter.selection.lines = [
        TextRecognitionLine(text: "Top", box: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1))
    ]
    canvas.magnify(by: 1.0, at: CGPoint(x: 320, y: 240))
    let frame = canvas.backdropFrame
    let start = frame.transform.imageToView(CGPoint(x: frame.sourceSize.width / 2, y: frame.sourceSize.height / 2))
    #expect(!controller.selectTextAdapter.pointer(start))
    let location = canvas.convert(start, to: nil)
    let moved = canvas.convert(CGPoint(x: start.x, y: start.y + 30), to: nil)
    let windowNumber = try #require(controller.window).windowNumber
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
        timestamp: 0, windowNumber: windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let drag = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: moved, modifierFlags: [],
        timestamp: 0, windowNumber: windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
    canvas.mouseDown(with: down)
    canvas.mouseDragged(with: drag)
    #expect(canvas.backdropFrame.transform.origin.y != frame.transform.origin.y)
    #expect(controller.selectTextAdapter.selection.selectedText == nil)
}
}
