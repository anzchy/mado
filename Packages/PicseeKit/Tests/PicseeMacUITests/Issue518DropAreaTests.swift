import AppKit
import Testing
import PicseeCore
import PicseeApplication
@testable import PicseeMacUI

/// Page22 .drop-outline is positioned against recovery-scroll, independently
/// of the inset recovery-state stack. mainContent already excludes footer40.
@Test @MainActor func issue518StackInsetsPreserveFullDropArea() throws {
    _ = NSApplication.shared
    let pageDesign = try PinnedDesign.page("empty-folder")
    let inset = try pageDesign.length(".drop-outline", "inset", viewport: 1280)
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800 - (try issue518NativeTitlebarHeight())),
                                  preferencesStore: InMemoryDisplayPreferencesStore())
        shell.wantsLayer = true
        let window = NSWindow(contentRect: shell.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = shell
        shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/design/待整理")),
                             parent: nil, children: [])
        shell.setEmptyFolderState(true, recents: [], now: Date(timeIntervalSince1970: 1_615_809_600))
        shell.layoutSubtreeIfNeeded()
        let page = shell.emptyFolderView
        #expect(page.frame == shell.mainContent.bounds, "The drop target owns the full recovery-scroll frame")
        page.layoutSubtreeIfNeeded()
        let expected = shell.convert(shell.mainContent.bounds.insetBy(dx: inset, dy: inset), from: shell.mainContent)
        let actual = shell.convert(page.dropOutline.bounds, from: page.dropOutline)
        #expect(actual == expected, "Drop outline retains the recovery-scroll's18pt inset, outside stack padding")
        // Render the native backing-layer tree so the portion of the real
        // outline below the inset page must survive ancestor clipping.
        shell.mainContent.wantsLayer = true
        page.wantsLayer = true
        window.displayIfNeeded()
        page.dropOutline.isHidden = false
        // Isolate fill clipping from the dashed stroke: a border dash may
        // cross the fixed edge sample after the viewport height changes.
        page.dropBorder.isHidden = true
        page.dropOutline.layer?.backgroundColor = NSColor.magenta.cgColor
        shell.mainContent.displayIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(shell.mainContent.bounds.width), pixelsHigh: Int(shell.mainContent.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep)?.cgContext)
        try #require(shell.mainContent.layer).render(in: context)
        for y in [20, rep.pixelsHigh - 20] {
            let color = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB))
            #expect(color.redComponent > 0.9 && color.blueComponent > 0.9 && color.greenComponent < 0.1,
                    "Drop highlight is composited through the padding outside the page frame")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let folder = URL(fileURLWithPath: "/photos/Trip", isDirectory: true)
        #expect(pasteboard.writeObjects([folder as NSURL]))
        var received: [[URL]] = []
        page.onDropFolders = { received.append($0) }
        for y in [CGFloat(5), shell.mainContent.bounds.height - 5] {
            let point = shell.convert(NSPoint(x: shell.mainContent.bounds.midX, y: y), from: shell.mainContent)
            let hit = shell.hitTest(point)
            #expect(hit === page || hit?.isDescendant(of: page) == true,
                    "Empty-folder padding remains part of the folder drop destination")
            // Full target frame covers the padding: no out-of-frame hitTest
            // extension is needed to reach NSDraggingDestination callbacks.
            let local = page.convert(point, from: shell)
            #expect(page.bounds.contains(local))
            let drag = Issue518PaddingDragInfo(pasteboard, at: page.convert(local, to: nil), window: window)
            #expect(page.draggingEntered(drag) == .copy)
            #expect(page.prepareForDragOperation(drag))
            #expect(page.performDragOperation(drag))
            #expect(received.last == [folder])
            #expect(!page.isDragOver)
        }
        for point in [NSPoint(x: 40, y: 60), NSPoint(x: 640, y: 20)] {
            let hit = shell.hitTest(point)
            #expect(hit !== page && hit?.isDescendant(of: page) != true, "Sidebar/footer are not drop padding")
        }
        page.dropOutline.isHidden = true
        let choosePoint = shell.convert(NSPoint(x: page.chooseButton.bounds.midX, y: page.chooseButton.bounds.midY),
                                        from: page.chooseButton)
        #expect(shell.hitTest(choosePoint) === page.chooseButton, "Content controls retain native mouse routing")
        page.isHidden = true
        let hiddenHit = shell.hitTest(shell.convert(NSPoint(x: shell.mainContent.bounds.midX, y: 5), from: shell.mainContent))
        #expect(hiddenHit !== page && hiddenHit?.isDescendant(of: page) != true, "Hidden empty page cannot receive drops")
    }
}

@MainActor private final class Issue518PaddingDragInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(_ pasteboard: NSPasteboard, at point: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingLocation = point; draggingDestinationWindow = window
    }
    var draggingSourceOperationMask: NSDragOperation { .copy }
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

@Test @MainActor func issue518Fix3PopulatedRecentListAndPaddingRouteFolderDrops() throws {
    _ = NSApplication.shared
    for appearance in [NSAppearance.Name.aqua, .darkAqua] {
        let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 960, height: 640),
            preferencesStore: InMemoryDisplayPreferencesStore())
        let window = NSWindow(contentRect: shell.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.appearance = NSAppearance(named: appearance)
        window.contentView = shell
        shell.showFolderTree(current: GridSidebarFolder(url: URL(fileURLWithPath: "/design/待整理")),
            parent: nil, children: [])
        let now = Date(timeIntervalSince1970: 1_615_809_600)
        let recents = (0..<10).map { index in
            RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/r\(index + 1)"),
                displayName: "最近文件夹 \(index + 1)", openedAt: now.addingTimeInterval(-Double(index + 1) * 86_400))
        }
        shell.setEmptyFolderState(true, recents: recents, now: now)
        shell.layoutSubtreeIfNeeded()
        let page = shell.emptyFolderView
        page.layoutSubtreeIfNeeded()
        let last = try #require(page.recentRows.last)
        let scroll = try #require(last.enclosingScrollView)
        let document = try #require(scroll.documentView)
        #expect(page.recentRows.count == 10)
        #expect(document.bounds.height > scroll.contentSize.height + 1,
            "The drag must cross the populated, genuinely scrollable list hierarchy")
        #expect(!page.chooseButton.isDescendant(of: scroll))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let folder = URL(fileURLWithPath: "/photos/Trip", isDirectory: true)
        #expect(pasteboard.writeObjects([folder as NSURL]))
        var received: [[URL]] = []
        page.onDropFolders = { received.append($0) }
        for position in 0..<2 {
            if position == 1 { last.scrollToVisible(last.bounds) }
            let clip = page.convert(scroll.contentView.bounds, from: scroll.contentView)
            let group = page.convert(page.recentsGroup.bounds, from: page.recentsGroup)
            let points = [
                NSPoint(x: clip.midX, y: clip.midY),
                NSPoint(x: group.maxX + 5, y: group.midY),
                NSPoint(x: page.bounds.midX, y: 5),
                NSPoint(x: page.bounds.midX, y: page.bounds.maxY - 5),
            ]
            for (index, local) in points.enumerated() {
                let point = shell.convert(local, from: page)
                let hit = try #require(shell.hitTest(point))
                #expect(hit === page || hit.isDescendant(of: page), "List and surrounding padding hit the page subtree")
                if index == 0 {
                    #expect(hit === scroll || hit.isDescendant(of: scroll), "List point exercises the nested clip/row hierarchy")
                }
                var destination: NSView? = hit
                while let current = destination, !current.registeredDraggedTypes.contains(.fileURL) {
                    destination = current.superview
                }
                #expect(destination === page, "The first registered folder-drop destination is the page")
                let drag = Issue518PaddingDragInfo(pasteboard, at: page.convert(local, to: nil), window: window)
                let before = received.count
                #expect(page.draggingEntered(drag) == .copy)
                #expect(page.isDragOver && !page.dropOutline.isHidden)
                #expect(page.draggingUpdated(drag) == .copy)
                #expect(page.prepareForDragOperation(drag))
                #expect(page.performDragOperation(drag))
                #expect(received.count == before + 1 && received.last == [folder], "Real pasteboard URL delivered once")
                #expect(!page.isDragOver && page.dropOutline.isHidden)
            }
        }
        for point in [NSPoint(x: 40, y: 60), NSPoint(x: 640, y: 20)] {
            let hit = shell.hitTest(point)
            #expect(hit !== page && hit?.isDescendant(of: page) != true, "Sidebar/footer remain outside page drop destination")
        }
    }
}
