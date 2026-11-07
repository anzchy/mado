import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

@MainActor private final class EdgeDropInfo: NSObject, NSDraggingInfo {
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

@MainActor private func edgePage() -> EmptyFolderStateView {
    _ = NSApplication.shared
    let page = EmptyFolderStateView(frame: NSRect(x: 0, y: 0, width: 1084, height: 732))
    page.display(subfolders: [URL(fileURLWithPath: "/edge/A/sub")], recents: [], includeSubfoldersAvailable: true)
    return page
}

@Test @MainActor func page22ViewsAreNotArchivable() {
    let coder = NSKeyedArchiver(requiringSecureCoding: false)
    #expect(EmptyFolderStateView(coder: coder) == nil)
    #expect(EmptyFolderTile(coder: coder) == nil)
    #expect(EmptyFolderRecentButton(coder: coder) == nil)
}

/// The focus ring follows the control's rounded shape; a control without a layer gets a square ring.
@Test @MainActor func page22FocusRingMaskCoversTheControlShape() throws {
    let tile = try #require(edgePage().tiles.first)
    let bare = EmptyFolderButton(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
    #expect(bare.layer == nil)
    for control in [tile, bare] as [EmptyFolderControl] {
        #expect(control.focusRingMaskBounds == control.bounds)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(control.bounds.width),
            pixelsHigh: Int(control.bounds.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.black.setFill()
        control.drawFocusRingMask()
        NSGraphicsContext.restoreGraphicsState()
        #expect(rep.colorAt(x: Int(control.bounds.midX), y: Int(control.bounds.midY))?.alphaComponent == 1)
        let corner = try #require(rep.colorAt(x: 0, y: 0)).alphaComponent
        #expect(control === tile ? corner < 0.5 : corner == 1, "rounded tile corner, square bare corner")
    }
}

@Test @MainActor func page22DragEndedClearsOutlineAndEmptyPasteboardIsRefused() {
    let page = edgePage()
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    #expect(page.draggingEntered(EdgeDropInfo(board)) == [])
    #expect(!page.isDragOver && page.dropOutline.isHidden)
    #expect(!page.performDragOperation(EdgeDropInfo(board)))
    #expect(board.writeObjects([URL(fileURLWithPath: "/photos/Trip", isDirectory: true) as NSURL]))
    #expect(page.draggingEntered(EdgeDropInfo(board)) == .copy && !page.dropOutline.isHidden)
    page.draggingEnded(EdgeDropInfo(board))
    #expect(!page.isDragOver && page.dropOutline.isHidden)
}

@Test @MainActor func page22ChooseWithoutSessionDoesNothing() {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    shell.setEmptyFolderState(true, recents: [], now: Date())
    #expect(shell.emptyFolderVisible && shell.session == nil)
    shell.emptyFolderView.chooseButton.performClick(nil)
    shell.emptyFolderView.primaryButton.performClick(nil)
    #expect(shell.emptyFolderVisible, "no session: the actions are inert and the page stays")
}

@Test @MainActor func page22WithoutRecentsShowsOnlyTheChooseAction() {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    shell.setEmptyFolderState(true, recents: [], now: Date())
    let page = shell.emptyFolderView
    #expect(page.recentsGroup.isHidden && page.tiles.isEmpty && page.primaryButton.isHidden)
    #expect(page.keyViews.count == 1 && page.keyViews.first === page.chooseButton)
    #expect(page.chooseButton.style == .secondary)
    shell.setEmptyFolderState(false, recents: [], now: Date())
    #expect(!shell.emptyFolderVisible)
}
