import AppKit
import Testing
import MadoApplication
import MadoCore
import MadoInfrastructure
@testable import MadoMacUI

@MainActor private final class SidebarWriteObserver: DisplayPreferencesObserver {
    var writes = 0
    func preferencesDidChange(_ preferences: DisplayPreferences) { writes += 1 }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue136RestoredSearchEditorIgnoresOnlyPendingMenuEndEditing() async throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView!.addSubview(shell)
    defer { window.close() }
    let ended = Notification(name: NSControl.textDidEndEditingNotification, object: shell.searchField)
    shell.focusSearch()
    #expect(window.firstResponder === shell.searchField.currentEditor())
    shell.preserveRestoredSearchEditorThroughMenuDispatch()
    shell.controlTextDidEndEditing(ended)
    #expect(!shell.searchField.isHidden)
    #expect(window.firstResponder === shell.searchField.currentEditor())

    shell.preserveRestoredSearchEditorThroughMenuDispatch()
    try await Task.sleep(for: .milliseconds(20))
    shell.controlTextDidEndEditing(ended)
    #expect(shell.searchField.isHidden)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridShellFramesAndColumnsFollowSidebarAtDesignViewports() throws {
    _ = NSApplication.shared
    let store = InMemoryDisplayPreferencesStore()
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772), preferencesStore: store)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1084, height: 732))
    grid.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(grid)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                          styleMask: [], backing: .buffered, defer: false)
    let host = NSView(frame: window.contentView!.bounds)
    window.contentView = host
    host.addSubview(shell)
    shell.layoutSubtreeIfNeeded()
    let scroll = try #require(grid.subviews.compactMap { $0 as? NSScrollView }.first)
    scroll.scrollerStyle = .overlay
    scroll.tile()
    #expect(shell.sidebar.frame.width == 196)
    #expect(shell.footer.frame == NSRect(x: 0, y: 0, width: 1280, height: 40))
    #expect(shell.mainFrame == NSRect(x: 196, y: 40, width: 1084, height: 732))
    #expect(grid.frame.width == 1084)
    #expect(grid.frame == issue314GridFrame(in: shell))
    grid.layoutSubtreeIfNeeded()
    let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
    #expect(abs(layout.itemSize.width - 247) < 0.1) // four columns at 1084 pt

    shell.resizeSidebar(to: 320)
    shell.layoutSubtreeIfNeeded()
    #expect(shell.sidebar.frame.width == 320)
    #expect(shell.mainFrame.width == 960)
    #expect(grid.frame == issue314GridFrame(in: shell))
    grid.layoutSubtreeIfNeeded()
    // The 1280px viewport keeps 220px minimum columns, 24px insets and 16px gaps despite 960pt content.
    #expect(abs(layout.itemSize.width - 293.333) < 0.1) // three columns at 960 pt
    #expect(store.value.gridSidebarWidth == 320)
    shell.resizeSidebar(to: 100)
    shell.layoutSubtreeIfNeeded()
    #expect(shell.sidebar.frame.width == 160)
    shell.toggleSidebar()
    shell.layoutSubtreeIfNeeded()
    #expect(shell.sidebar.isHidden)
    #expect(shell.mainFrame.width == 1280)
    grid.layoutSubtreeIfNeeded()
    #expect(grid.frame.width == 1280)
    #expect(grid.frame == issue314GridFrame(in: shell))
    #expect(abs(layout.itemSize.width - 233.6) < 0.1) // five columns after closing
    shell.toggleSidebar()
    #expect(store.value.gridSidebarWidth == 160)
    #expect(shell.mainFrame.width == 1120)

    window.setContentSize(NSSize(width: 800, height: 680))
    shell.frame = NSRect(x: 0, y: 0, width: 800, height: 652)
    shell.layoutSubtreeIfNeeded()
    #expect(shell.footer.frame.maxY == shell.mainFrame.minY)
    #expect(shell.sidebar.frame.maxX == shell.mainFrame.minX)
    #expect(shell.mainFrame.maxX == 800)
    #expect(shell.mainFrame.maxY == 652)
    #expect(grid.frame == NSRect(x: 0, y: -40, width: 640, height: 652))
    grid.layoutSubtreeIfNeeded()
    // grid-light.html: at 800px, .photo-grid keeps min 220px columns while .grid-scroll uses 16px insets and 12px gaps.
    #expect(abs(layout.itemSize.width - 298) < 0.1) // two columns at 800 × 680
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridShellFooterButtonDragAndTruthfulFolderAreAccessible() throws {
    _ = NSApplication.shared
    let store = InMemoryDisplayPreferencesStore()
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652), preferencesStore: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                          styleMask: [], backing: .buffered, defer: false)
    window.contentView!.addSubview(shell)
    shell.layoutSubtreeIfNeeded()
    let active = shell
    let label = try #require(active.sidebar.subviews.compactMap { $0 as? NSTextField }.first)
    #expect(label.isHidden)
    active.showFolder("Actual Folder")
    #expect(label.stringValue == "Actual Folder")
    #expect(!label.isHidden)
    active.showFolder(nil)
    #expect(label.isHidden)

    #expect(active.toggleButton.accessibilityIdentifier() == "grid.sidebar.toggle")
    #expect(active.toggleButton.accessibilityLabel() == "Hide sidebar")
    active.toggleButton.performClick(nil)
    #expect(!store.value.gridSidebarVisible)
    #expect(active.toggleButton.accessibilityLabel() == "Show sidebar")
    active.toggleButton.performClick(nil)
    #expect(store.value.gridSidebarVisible)

    let divider = try #require(active.sidebar.subviews.first { $0.accessibilityIdentifier() == "grid.sidebar.resize" })
    divider.resetCursorRects()
    let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 196, y: 320),
        modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1))
    let moved = try #require(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 276, y: 320),
        modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber, context: nil,
        eventNumber: 2, clickCount: 1, pressure: 1))
    divider.mouseDown(with: down)
    divider.mouseDragged(with: moved)
    #expect(active.sidebar.frame.width == 276)
    #expect(store.value.gridSidebarWidth == 196)
    divider.mouseUp(with: moved)
    #expect(store.value.gridSidebarWidth == 276)
    active.resizeSidebar(to: .infinity)
    #expect(store.value.gridSidebarWidth == 276)
    active.appearance = NSAppearance(named: .darkAqua)
    active.viewDidChangeEffectiveAppearance()
    let dark = DesignColor.sidebarBackground.components(.dark)
    let actual = try #require(active.sidebar.layer?.backgroundColor?.components)
    #expect(zip(actual, dark).allSatisfy { abs(Double($0.0) - $0.1) < 0.01 })

    #expect(GridShellView(coder: NSKeyedArchiver(requiringSecureCoding: false)) == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func compactGridLongFilenameStaysInMainColumnAboveFooter() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
                          styleMask: [], backing: .buffered, defer: false)
    window.contentView!.addSubview(shell)
    shell.layoutSubtreeIfNeeded()
    let folder = URL(fileURLWithPath: "/tmp/mado-compact-grid")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entry = FolderEntry(url: folder.appendingPathComponent(String(repeating: "a", count: 180) + ".jpg"), root: root)
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    shell.mainContent.addSubview(grid)
    grid.display(FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: [entry], isComplete: true), selectedItemID: nil)
    grid.layoutSubtreeIfNeeded()
    let cell = try #require(grid.collectionView.visibleItems().compactMap { $0 as? GridPhotoItem }.first)
    let name = try #require(cell.view.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == entry.url.lastPathComponent })
    #expect(name.maximumNumberOfLines == 1)
    #expect(name.lineBreakMode == .byTruncatingTail)
    #expect(name.frame.maxX <= cell.view.bounds.maxX)
    #expect(shell.mainContent.frame.minY == shell.footer.frame.maxY)
    let cellInShell = cell.view.convert(cell.view.bounds, to: shell)
    #expect(shell.mainContent.frame.contains(cellInShell))
    #expect(cellInShell.minY >= shell.footer.frame.maxY)
}

@Test(.timeLimit(.minutes(2))) @MainActor func sidebarDragUsesMouseDownWidthAndWritesOnceOnRelease() throws {
    _ = NSApplication.shared
    let store = InMemoryDisplayPreferencesStore()
    let observer = SidebarWriteObserver()
    store.observe(observer)
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652), preferencesStore: store)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680), styleMask: [], backing: .buffered, defer: false)
    window.contentView!.addSubview(shell)
    shell.layoutSubtreeIfNeeded()
    let divider = try #require(shell.sidebar.subviews.first { $0.accessibilityIdentifier() == "grid.sidebar.resize" })
    func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 320), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
    divider.mouseDown(with: try event(.leftMouseDown, 196))
    divider.mouseDragged(with: try event(.leftMouseDragged, 500))
    #expect(shell.sidebar.frame.width == 320)
    divider.mouseDragged(with: try event(.leftMouseDragged, 206))
    #expect(shell.sidebar.frame.width == 206)
    #expect(observer.writes == 0)
    divider.mouseUp(with: try event(.leftMouseUp, 206))
    #expect(store.value.gridSidebarWidth == 206)
    #expect(observer.writes == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridSidebarControlsAreInKeyboardLoopAndExposeAdjustableWidth() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
                              preferencesStore: InMemoryDisplayPreferencesStore())
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    shell.mainContent.addSubview(grid)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 680))
    let window = NSWindow(contentRect: host.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.autorecalculatesKeyViewLoop = false
    window.contentView = host
    host.addSubview(shell)
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView(), shell: shell)
    presentation.showGrid(reading: false)
    let divider = try #require(shell.sidebar.subviews.first { $0.accessibilityIdentifier() == "grid.sidebar.resize" })
    #expect(grid.collectionView.nextKeyView === shell.toggleButton)
    #expect(shell.toggleButton.nextKeyView === divider)
    #expect(divider.accessibilityRole() == .splitter)
    #expect(divider.accessibilityLabel() == "Resize sidebar")
    #expect((divider.accessibilityMinValue() as? NSNumber)?.intValue == 160)
    #expect((divider.accessibilityMaxValue() as? NSNumber)?.intValue == 320)
    #expect((divider.accessibilityValue() as? NSNumber)?.intValue == 196)
    #expect(divider.accessibilityPerformIncrement())
    #expect(shell.sidebar.frame.width > 196)
    #expect(window.makeFirstResponder(grid.collectionView))
    window.selectNextKeyView(nil)
    #expect(window.firstResponder === shell.toggleButton)
    #expect(window.makeFirstResponder(shell.toggleButton))
    window.selectNextKeyView(nil)
    #expect(window.firstResponder === divider)
    let arrow = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "→", charactersIgnoringModifiers: "→", isARepeat: false, keyCode: 124))
    divider.keyDown(with: arrow)
    #expect(shell.sidebar.frame.width > 204)
    #expect(divider.accessibilityPerformDecrement())
    #expect(shell.sidebar.frame.width == 204)
}

@Test(.timeLimit(.minutes(2))) @MainActor func savedSidebarWidthSizesGridWhenAppHostReopens() throws {
    _ = NSApplication.shared
    let suite = "grid-host-reopen-\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let saved = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    saved.value.gridSidebarWidth = 284
    let reopened = UserDefaultsDisplayPreferencesStore(defaults: defaults)
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772), preferencesStore: reopened)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    grid.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(grid)
    let host = NSView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
    host.addSubview(shell)
    let presentation = GridViewerPresentation(canvas: NSView(), chrome: NSView(), state: NSView(),
        grid: grid, inspector: NSView(), shell: shell)
    presentation.showGrid(reading: false)
    #expect(shell.mainFrame == NSRect(x: 284, y: 40, width: 996, height: 732))
    #expect(grid.frame == issue314GridFrame(in: shell))
    shell.frame.size.width = 800
    shell.layoutSubtreeIfNeeded()
    #expect(grid.frame == issue314GridFrame(in: shell))
    #expect(grid.frame.width == 516)
}

/// PR #304 CI: footer status updates re-run the shell's layout without moving the main frame. The shell resets every
/// main-content view on that pass, so it must tell the owner each time, after the reset, or a carved strip is lost.
@Test(.timeLimit(.minutes(2))) @MainActor func gridShellReportsEveryMainContentLayoutAfterResettingContentFrames() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let carved = NSView()
    shell.mainContent.addSubview(carved)
    var frameChanges = 0, contentLayouts: [NSRect] = []
    shell.onMainFrameChange = { _ in frameChanges += 1 }
    shell.onMainContentLayout = {
        contentLayouts.append(carved.frame)
        carved.frame = NSRect(x: 0, y: shell.mainContent.bounds.maxY - 44, width: shell.mainContent.bounds.width, height: 44)
    }
    shell.layoutSubtreeIfNeeded()
    #expect(frameChanges == 1 && contentLayouts == [shell.mainContent.bounds])
    for update in [{ shell.setCurrentFile("DSC_0001.jpg") }, { shell.setSearchStatus(resultCount: 3, term: "") },
                   { shell.setReadingStatus(true) }] {
        update()
        shell.layoutSubtreeIfNeeded()
    }
    #expect(frameChanges == 1, "the main frame never moved")
    #expect(contentLayouts.count == 4)
    #expect(contentLayouts.allSatisfy { $0 == shell.mainContent.bounds }, "each report follows the content reset")
    #expect(carved.frame == NSRect(x: 0, y: shell.mainContent.bounds.maxY - 44, width: shell.mainContent.bounds.width, height: 44))
}

@MainActor private func issue314GridFrame(in shell: GridShellView) -> NSRect {
    NSRect(x: 0, y: -shell.footer.bounds.height, width: shell.mainContent.bounds.width,
        height: shell.mainContent.bounds.height + shell.footer.bounds.height)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue314GridScrollsBehindBottomBarAndClearsItAtTheEnd() throws {
    _ = NSApplication.shared
    let shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 800, height: 652),
        preferencesStore: InMemoryDisplayPreferencesStore())
    let grid = GridBrowserView(frame: NSRect(origin: .zero, size: shell.mainFrame.size))
    grid.autoresizingMask = [.width, .height]
    shell.mainContent.addSubview(grid)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 680),
        styleMask: [], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = shell
    defer { window.close() }
    let folder = URL(fileURLWithPath: "/tmp/mado-grid-314")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let entries = (0..<24).map {
        FolderEntry(url: folder.appendingPathComponent(String(format: "%02d.jpg", $0)), root: root)
    }
    grid.display(FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: entries, isComplete: true), selectedItemID: nil)
    grid.activate()
    shell.layoutSubtreeIfNeeded()
    grid.layoutSubtreeIfNeeded()

    let design = try PinnedDesign.page("grid-light")
    let barHeight = try design.length(".grid-bottom-bar", "height", viewport: 800)
    let bottomPadding = try design.length(".grid-scroll", "padding-bottom", viewport: 800)
    let gridInShell = grid.convert(grid.bounds, to: shell)
    #expect(abs(gridInShell.minY - shell.footer.frame.minY) < 0.01)
    #expect(abs(gridInShell.maxY - shell.bounds.maxY) < 0.01)
    let scroll = try #require(grid.collectionView.enclosingScrollView)
    let layout = try #require(grid.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)
    #expect(abs(scroll.contentInsets.bottom - barHeight) < 0.01)
    #expect(abs(scroll.contentInsets.bottom + layout.sectionInset.bottom - bottomPadding) < 0.01)

    shell.setCurrentFile(String(repeating: "Long旅行FileName", count: 12) + ".jpg")
    shell.setSearchStatus(resultCount: entries.count, term: "")
    shell.layoutSubtreeIfNeeded()
    let fileStatus = try #require(shell.footer.subviews.first {
        $0.accessibilityIdentifier() == "grid.current-file-status"
    })
    let controls: [NSView] = [shell.toggleButton, fileStatus, shell.searchStatus,
        shell.searchButton, shell.sortButton, shell.infoButton, shell.displayButton]
    for first in controls.indices {
        for second in controls.indices where second > first {
            #expect(!NSIntersectsRect(controls[first].frame, controls[second].frame),
                "800×680 controls overlap: \(controls[first].frame) and \(controls[second].frame)")
        }
    }

    let lastIndex = entries.count - 1
    let endOffset = max(0, grid.collectionView.bounds.height - scroll.contentView.bounds.height
        + scroll.contentInsets.bottom)
    #expect(endOffset > 0)
    grid.restoreContentOffset(NSPoint(x: 0, y: endOffset))
    grid.layoutSubtreeIfNeeded()
    var lastFrame = grid.collectionView.convert(grid.collectionView.frameForItem(at: lastIndex), to: shell)
    #expect(lastFrame.minY >= shell.footer.frame.maxY - 0.5,
        "Last row at the end is behind the Bottom Bar: \(lastFrame)")

    grid.restoreContentOffset(.zero)
    grid.activate(currentItemID: entries[0].itemID)
    let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
        charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124))
    for _ in 1..<entries.count { grid.collectionView.keyDown(with: right) }
    #expect(grid.currentItemID == entries[lastIndex].itemID)
    lastFrame = grid.collectionView.convert(grid.collectionView.frameForItem(at: lastIndex), to: shell)
    #expect(lastFrame.minY >= shell.footer.frame.maxY - 0.5,
        "Keyboard-selected last item is behind the Bottom Bar: \(lastFrame)")
}
