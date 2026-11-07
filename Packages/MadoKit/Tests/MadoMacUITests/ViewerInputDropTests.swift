import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class InputDropInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    init(_ pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) { }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
        classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) { }
    func resetSpringLoading() { }
}

@Test @MainActor func inputDropPasteboardTransitionsPreserveOrderAndRefuseSheets() throws {
    _ = NSApplication.shared
    let a = URL(fileURLWithPath: "/photos/A.jpg"), b = URL(fileURLWithPath: "/photos/B.png")
    let remote = URL(string: "https://example.test/image.png")!
    let rows: [([any NSPasteboardWriting], [URL])] = [
        ([b as NSURL], [b]), ([b as NSURL, a as NSURL], [b, a]),
        (["just text" as NSString], []), ([remote as NSURL], []),
        ([remote as NSURL, b as NSURL, "text" as NSString, a as NSURL], [b, a]), ([], [])
    ]
    for (objects, expected) in rows {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        if !objects.isEmpty { #expect(board.writeObjects(objects)) }
        let info = InputDropInfo(board)
        var accepts = true
        var delivered: [[URL]] = []
        let view = ViewerDropView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
                                  acceptsDrop: { accepts }, onDrop: { delivered.append($0) })
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        #expect(view.registeredDraggedTypes.contains(.fileURL))
        let operation: NSDragOperation = expected.isEmpty ? [] : .copy
        #expect(view.draggingEntered(info) == operation)
        #expect(view.draggingUpdated(info) == operation)
        #expect(delivered.isEmpty)
        accepts = false
        #expect(view.draggingEntered(info) == [])
        #expect(view.draggingUpdated(info) == [])
        #expect(view.performDragOperation(info) == false)
        #expect(delivered.isEmpty)
        accepts = true
        #expect(view.performDragOperation(info) == !expected.isEmpty)
        #expect(delivered == (expected.isEmpty ? [] : [expected]))
        #expect(view.draggingUpdated(info) == operation)
        #expect(delivered.count == (expected.isEmpty ? 0 : 1))
        #expect(view.performDragOperation(info) == !expected.isEmpty)
        #expect(delivered == (expected.isEmpty ? [] : [expected, expected]))
    }
}

@Test @MainActor func inputDropContentKeepsChromeAndCanvasHitTesting() throws {
    _ = NSApplication.shared
    let host = ChromeToolsHost()
    host.hasImage = false; host.canNavigate = false
    let session = ViewerSession(host: host)
    let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
    var dropped: [[URL]] = []
    let content = ViewerDropView(frame: frame, acceptsDrop: { true }, onDrop: { dropped.append($0) })
    let canvas = CanvasView(frame: frame, session: session)
    let state = ViewerStateHost(frame: frame, session: session)
    let chrome = ViewerChromeOverlay(frame: frame, session: session)
    content.addSubview(canvas); content.addSubview(state); content.addSubview(chrome)
    let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = content
    defer { window.close() }
    // #444: page 14's leading pod has no 打开 tool; 更多 is always enabled and presents its menu.
    let presenter = RecordingMenuPresenter()
    chrome.menuPresenter = presenter
    chrome.moreMenuProvider = { NSMenu(title: "More") }
    let tool = chrome.tools[2]
    let point = content.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), from: tool)
    #expect(content.hitTest(point) === tool)
    #expect(content.hitTest(NSPoint(x: 480, y: 100)) === canvas)
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
        timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
    tool.mouseDown(with: down); tool.mouseUp(with: up)
    #expect(presenter.presented.count == 1 && presenter.presented.first?.anchor === tool)
    #expect(session.imageStatus == .empty)
    #expect(dropped.isEmpty)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let url = URL(fileURLWithPath: "/photos/A.png")
    #expect(board.writeObjects([url as NSURL]))
    #expect(content.performDragOperation(InputDropInfo(board)))
    #expect(dropped == [[url]])
    #expect(content.hitTest(point) === tool)
}
