import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

private actor Page22Leases: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease { AccessLease(url: URL(fileURLWithPath: "/page22"), rootID: nil) }
    func release(_ lease: AccessLease) {}
}

/// Each scan call waits for its own `finish(i, names)`; a private copy because MadoMacUITests cannot import the
/// application test target's controlled scanner.
private actor Page22Scanner: FolderScanning {
    private var calls = 0
    private var gates: [Int: CheckedContinuation<[String], Never>] = [:]
    private var ready: [Int: [String]] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let index = calls
        calls += 1
        let started = startWaiters.filter { calls > $0.0 }
        startWaiters.removeAll { calls > $0.0 }
        started.forEach { $0.1.resume() }
        let names: [String]
        if let early = ready.removeValue(forKey: index) { names = early }
        else { names = await withCheckedContinuation { gates[index] = $0 } }
        try await emit(names.map { FolderEntry(url: folder.appendingPathComponent($0), root: root) })
    }
    func waitForStart(_ index: Int) async {
        if calls > index { return }
        await withCheckedContinuation { startWaiters.append((index, $0)) }
    }
    func finish(_ index: Int, _ names: [String] = []) {
        if let gate = gates.removeValue(forKey: index) { gate.resume(returning: names) } else { ready[index] = names }
    }
    func finishAll() { for gate in gates.values { gate.resume(returning: []) }; gates = [:] }
}

@MainActor private final class Page22EscRecorder: NSView {
    var count = 0
    override func cancelOperation(_ sender: Any?) { count += 1 }
}

@MainActor private final class Page22DropInfo: NSObject, NSDraggingInfo {
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

private struct Page22Random: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

let page22Now = Date(timeIntervalSince1970: 1_615_809_600) // 2021-03-15T12:00:00Z

/// Real shell, grid, state host, session and coordinator. `sync()` mirrors the App's observation order; it is an
/// adapter, so CanvasWindowController wiring itself stays NOT VERIFIED here.
@MainActor private final class Page22Scene {
    let session = ViewerSession()
    let host = StatesNativeHost()
    let scanner = Page22Scanner()
    let coordinator: FolderScanCoordinator
    let window: NSWindow
    let content: NSView
    let canvas: CanvasView
    let shell: GridShellView
    let grid: GridBrowserView
    let state: ViewerStateHost
    let chrome: ViewerChromeOverlay
    let inspector = NSView()
    let presentation: GridViewerPresentation
    let rootID = AccessRootID()
    let folder = URL(fileURLWithPath: "/page22/A")
    var calls = 0
    var recents: [RecentFolder] = []
    var selected: [URL] = []
    var opened: [RecentFolder] = []
    var dropped: [[URL]] = []
    init(content: NSView = NSView()) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.content = content
        content.frame = frame
        canvas = CanvasView(frame: frame, session: session)
        shell = GridShellView(frame: NSRect(x: 0, y: 0, width: 1280, height: 772),
                              preferencesStore: InMemoryDisplayPreferencesStore())
        grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 1084, height: 732))
        state = ViewerStateHost(frame: frame, session: session)
        chrome = ViewerChromeOverlay(frame: frame, session: session)
        content.addSubview(canvas)
        content.addSubview(shell)
        shell.mainContent.addSubview(grid)
        content.addSubview(state, positioned: .above, relativeTo: shell)
        content.addSubview(chrome, positioned: .above, relativeTo: state)
        content.addSubview(inspector)
        window.contentView = content
        presentation = GridViewerPresentation(canvas: canvas, chrome: chrome, state: state, grid: grid,
                                              inspector: inspector, shell: shell)
        host.canvas = canvas; host.window = window
        session.host = host; session.imageLoader.host = host
        coordinator = FolderScanCoordinator(access: Page22Leases(), scanner: scanner)
        session.folderScan = coordinator
        shell.session = session
        shell.onSelectFolder = { [unowned self] in selected.append($0) }
        shell.onOpenRecent = { [unowned self] in opened.append($0) }
        shell.onDropFolders = { [unowned self] in dropped.append($0) }
        shell.mirrorEmptyFolderPage(to: state)
        presentation.showViewer()
    }
    var page: EmptyFolderStateView { shell.emptyFolderView }
    func tree(_ children: [String], parent: URL? = nil) {
        shell.showFolderTree(current: GridSidebarFolder(url: folder), parent: parent.map { GridSidebarFolder(url: $0) },
            children: children.map { GridSidebarFolder(url: folder.appendingPathComponent($0), count: 7) })
    }
    func sync() {
        if coordinator.isReadingFolder { presentation.showGrid(reading: true) }
        else if let snapshot = coordinator.snapshot {
            presentation.showCompletedGrid(snapshot, selection: session.selection, currentItemID: nil, offset: nil)
            session.completeFolderEntry()
        } else { presentation.showGrid(reading: false) }
        shell.setEmptyFolderState(session.isEmptyFolder, recents: recents, now: page22Now)
        state.refresh()
    }
    func nextCall() -> Int { defer { calls += 1 }; return calls }
    func open(_ names: [String]) async throws {
        let task = coordinator.begin(folder: folder, rootID: rootID)
        let index = nextCall()
        presentation.showGrid(reading: true)
        await scanner.waitForStart(index)
        sync()
        await scanner.finish(index, names)
        try await task.value
        session.beginBrowsing(items: coordinator.snapshot?.navigationEntries.map(\.itemID) ?? [],
            sourceVersion: .init(coordinator.generation), scrollAnchor: nil)
        sync()
    }
    func refresh(_ names: [String]) async throws {
        guard let task = coordinator.refresh() else { return }
        let index = nextCall()
        await scanner.waitForStart(index)
        await scanner.finish(index, names)
        try await task.value
        sync()
    }
    func waitForScanEnd(fileID: String = #fileID, line: Int = #line) async throws {
        try await waitUntil("scan ended", fileID: fileID, line: line) { !coordinator.isScanning }
    }
    var itemCount: Int { grid.collectionView(grid.collectionView, numberOfItemsInSection: 0) }
    func keyWalk() -> [NSView] {
        var views: [NSView] = []
        var view = grid.collectionView.nextKeyView
        while let next = view, views.count < 200 {
            views.append(next)
            if next === grid.collectionView { break }
            view = next.nextKeyView
        }
        return views
    }
    func close() async {
        await scanner.finishAll()
        coordinator.cancel()
        window.close()
    }
}

/// Descendant labels' strings, top to bottom then left to right.
@MainActor private func textLabels(of view: NSView) -> [String] {
    func collect(_ view: NSView) -> [NSTextField] {
        view.subviews.flatMap { sub -> [NSTextField] in
            guard !sub.isHidden else { return [] }
            return (sub as? NSTextField).map { [$0] } ?? collect(sub)
        }
    }
    return collect(view).map { ($0, $0.convert($0.bounds, to: nil)) }
        .sorted { $0.1.maxY != $1.1.maxY ? $0.1.maxY > $1.1.maxY : $0.1.minX < $1.1.minX }
        .map(\.0.stringValue)
}

@MainActor private func frame(_ view: NSView, in page: NSView) -> NSRect { page.convert(view.bounds, from: view) }

@MainActor private func sameViews(_ a: [NSView], _ b: [NSView]) -> Bool {
    a.map(ObjectIdentifier.init) == b.map(ObjectIdentifier.init)
}

private func recentFolders(_ count: Int) -> [RecentFolder] {
    (0..<count).map { index in
        RecentFolder(rootID: AccessRootID(), url: URL(fileURLWithPath: "/recent/R\(index)"), displayName: "R\(index)",
            openedAt: page22Now.addingTimeInterval(-Double(count - index) * 86_400))
    }
}

@Test @MainActor func page22SubfolderCaseShowsTilesActionsAndNoCounts() async throws {
    let scene = Page22Scene()
    scene.tree(["2024 冲绳", "手机备份", "扫描件"])
    try await scene.open([])
    let page = scene.page
    #expect(scene.shell.emptyFolderVisible)
    #expect(page.tiles.count == 3)
    #expect(page.tiles.map { textLabels(of: $0) } == ["2024 冲绳", "手机备份", "扫描件"].map { [$0, "Subfolder"] })
    #expect(!page.tiles.flatMap { textLabels(of: $0) }.joined().contains("7"), "no image counts on tiles")
    #expect(page.heading.stringValue == "This level has no images, but has 3 subfolders")
    #expect(page.primaryButton.title == "Browse Including Subfolders")
    #expect(page.chooseButton.title == "Choose Another Folder…")
    #expect(!page.primaryButton.isHiddenOrHasHiddenAncestor && !page.chooseButton.isHiddenOrHasHiddenAncestor)
    #expect(page.recentsGroup.isHidden)
    for tile in page.tiles {
        let center = scene.shell.convert(NSPoint(x: tile.bounds.midX, y: tile.bounds.midY), from: tile)
        #expect(scene.shell.mainContent.hitTest(center) === tile)
    }
    await scene.close()

    // Part B: a parent row never becomes a tile; only the current folder's children do.
    let partB = Page22Scene()
    partB.recents = recentFolders(2)
    partB.tree(["x", "y"], parent: URL(fileURLWithPath: "/page22"))
    try await partB.open([])
    #expect(partB.page.tiles.map { textLabels(of: $0).first } == ["x", "y"])
    #expect(partB.page.heading.stringValue == "This level has no images, but has 2 subfolders")
    partB.tree([], parent: URL(fileURLWithPath: "/page22"))
    partB.sync()
    #expect(partB.page.tiles.isEmpty && !partB.page.recentsGroup.isHidden && partB.page.recentRows.count == 2)
    #expect(partB.shell.emptyFolderVisible)
    await partB.close()

    // Part C (owner decision): with Include Subfolders already on and still empty, the primary action is hidden.
    let partC = Page22Scene()
    #expect(partC.coordinator.setRecursiveEnabled(true) == nil)
    partC.tree(["2024 冲绳", "手机备份"])
    try await partC.open([])
    #expect(partC.session.folderRecursiveEnabled && partC.shell.emptyFolderVisible)
    #expect(partC.page.tiles.count == 2)
    #expect(partC.page.primaryButton.isHiddenOrHasHiddenAncestor)
    #expect(!partC.page.chooseButton.isHiddenOrHasHiddenAncestor)
    #expect(!partC.page.keyViews.contains { $0 === partC.page.primaryButton })
    await partC.close()
}

@Test @MainActor func page22UpdatesWhenSidebarChildrenArrive() async throws {
    let scene = Page22Scene()
    scene.recents = recentFolders(2)
    scene.tree([])
    try await scene.open([])
    #expect(scene.page.tiles.isEmpty && scene.page.recentRows.count == 2 && !scene.page.recentsGroup.isHidden)
    scene.tree(["c1", "c2"])
    #expect(scene.page.tiles.count == 2 && scene.page.recentsGroup.isHidden)
    #expect(scene.shell.folderTree.rows.last?.nextKeyView === scene.page.tiles.first)
    scene.tree([])
    #expect(scene.page.tiles.isEmpty && scene.page.recentRows.count == 2 && !scene.page.recentsGroup.isHidden)
    #expect(scene.shell.folderTree.rows.last?.nextKeyView === scene.page.recentRows.first)
    await scene.close()
}

@Test @MainActor func page22StateSurvivesLaterShellCalls() async throws {
    let scene = Page22Scene()
    scene.tree(["a", "b", "c"])
    try await scene.open([])
    let before = scene.keyWalk()
    #expect(before.contains { $0 === scene.page.tiles.first })
    let calls: [(String, () -> Void)] = [
        ("show(.grid)", { scene.presentation.show(.grid) }),
        ("showGrid(reading: false)", { scene.presentation.showGrid(reading: false) }),
        ("showSearchEmpty", { scene.shell.showSearchEmpty(true, term: "x") }),
        ("linkKeyViews", { scene.shell.linkKeyViews(from: scene.grid.collectionView) }),
    ]
    for (name, call) in calls {
        call()
        let shell = scene.shell
        #expect(shell.emptyFolderVisible, "\(name): visible")
        #expect(!shell.searchEmptyVisible, "\(name): search-empty hidden")
        #expect(!shell.searchButton.isEnabled && !shell.sortButton.isEnabled && !shell.searchField.isEnabled, "\(name): footer")
        #expect(sameViews(scene.keyWalk(), before), "\(name): key loop")
    }
    await scene.close()
}

@Test @MainActor func page22TileBoundaries() async throws {
    var x0: CGFloat?
    for count in [1, 3, 4, 60] {
        let scene = Page22Scene()
        scene.tree((0..<count).map { "sub\($0)" })
        try await scene.open([])
        let page = scene.page, tiles = page.tiles
        try #require(tiles.count == count)
        let frames = tiles.map { frame($0, in: page) }
        for (index, tileFrame) in frames.enumerated() { #expect(abs(tileFrame.width - 150) < 0.5, "\(count): width \(index)") }
        let first = try #require(frames.first)
        if x0 == nil { x0 = first.minX }
        #expect(abs(first.minX - x0!) < 0.5, "\(count): grid does not move with the tile count")
        for (index, tileFrame) in frames.prefix(3).enumerated() {
            #expect(abs(tileFrame.minX - (first.minX + CGFloat(index) * 164)) < 0.5, "\(count): column \(index)")
        }
        if count >= 4 {
            #expect(abs(frames[3].minX - first.minX) < 0.5, "\(count): tile 4 wraps to column 1")
            #expect(abs(first.minY - frames[3].maxY - 14) < 0.5, "\(count): row gap")
        }
        if count == 60 {
            let document = try #require(page.scrollView.documentView)
            #expect(document.frame.height > page.scrollView.contentView.bounds.height)
            var walked: [NSView] = []
            var view = scene.shell.folderTree.rows.last?.nextKeyView
            while let next = view, walked.count < 61 { walked.append(next); view = next.nextKeyView }
            #expect(sameViews(walked, tiles + [page.primaryButton]))
        }
        await scene.close()
    }
}

@Test @MainActor func page22RecentsRowsRenderCappedModelOrder() async throws {
    let scene = Page22Scene()
    scene.recents = recentFolders(12)
    scene.tree([])
    try await scene.open([])
    guard case .recents(let expected) = EmptyFolderContent.make(subfolders: [],
        recents: scene.recents, now: page22Now, locale: .current, calendar: .current) else {
        Issue.record("model did not produce the recents case"); await scene.close(); return
    }
    let rows = scene.page.recentRows
    #expect(rows.count == 10)
    for (index, row) in rows.enumerated() where index < expected.count {
        #expect(textLabels(of: row) == [expected[index].folder.displayName, expected[index].relativeTime], "row \(index)")
    }
    #expect(rows.first.map { textLabels(of: $0).first } == "R11")
    #expect(rows.last.map { textLabels(of: $0).first } == "R2")
    await scene.close()
}

@Test(arguments: ["items", "empty", "cancel"])
@MainActor func page22IncludeSubfoldersStartsReadingOverShellThenGridOrPage22(ending: String) async throws {
    let scene = Page22Scene()
    scene.tree(["sub"])
    try await scene.open([])
    #expect(scene.shell.emptyFolderVisible && scene.session.mode == .browsing)
    scene.page.primaryButton.performClick(nil)
    try #require(scene.coordinator.isScanning, "Include Subfolders started the rescan")
    await scene.scanner.waitForStart(1)
    scene.sync()
    #expect(scene.coordinator.isReadingFolder)
    #expect(!scene.shell.emptyFolderVisible)
    #expect(!scene.state.isHidden && scene.state.textLines == ["Reading Folder…", "Looking for images to browse. Please wait."])
    #expect(scene.state.frame == scene.shell.convert(scene.shell.mainFrame, to: scene.content))
    switch ending {
    case "items":
        await scene.scanner.finish(1, ["sub/a.png", "sub/b.png"])
        try await scene.waitForScanEnd()
        scene.sync()
        #expect(scene.itemCount == 2 && !scene.shell.emptyFolderVisible)
    case "empty":
        await scene.scanner.finish(1)
        try await scene.waitForScanEnd()
        scene.sync()
        #expect(scene.shell.emptyFolderVisible && scene.session.folderRecursiveEnabled)
    default:
        scene.state.onCancelFolderReading = { [unowned scene] in
            if let target = scene.session.cancelFolderEntry() { scene.presentation.show(target) }
        }
        let cancel = try #require(scene.state.buttons.first { $0.identifier?.rawValue == "state.cancel-folder" })
        cancel.performClick(nil)
        scene.sync()
        #expect(scene.shell.emptyFolderVisible && !scene.session.folderRecursiveEnabled)
        await scene.scanner.finish(1, ["sub/late.png"])
        try await scene.waitForScanEnd()
        scene.sync()
        #expect(scene.shell.emptyFolderVisible, "a late completion is ignored")
    }
    await scene.close()
}

@Test @MainActor func page22ActionsRouteToOpenTileAndRecent() async throws {
    let scene = Page22Scene()
    let recents = recentFolders(3)
    scene.recents = recents
    scene.tree(["2024 冲绳", "手机备份", "扫描件"])
    try await scene.open([])
    try #require(scene.page.tiles.count == 3)
    scene.page.tiles[1].performClick(nil)
    #expect(scene.selected == [scene.folder.appendingPathComponent("手机备份")])
    scene.tree([])
    let row = try #require(scene.page.recentRows.first)
    row.performClick(nil)
    #expect(scene.opened == [recents[2]], "the newest recent, mapped after sorting")
    scene.page.chooseButton.performClick(nil)
    #expect(scene.host.opens == 1)
    await scene.close()
}

@Test(arguments: ["subfolders", "recents"])
@MainActor func page22ChooseAnotherFolderRoutesOpenInBothCases(kind: String) async throws {
    let scene = Page22Scene()
    scene.recents = recentFolders(2)
    scene.tree(kind == "subfolders" ? ["a", "b", "c"] : [])
    try await scene.open([])
    let page = scene.page, choose = page.chooseButton
    let before = scene.host.opens
    #expect(choose.title == "Choose Another Folder…")
    #expect(!choose.isHiddenOrHasHiddenAncestor && choose.isEnabled)
    choose.performClick(nil)
    #expect(scene.host.opens == before + 1)
    if kind == "recents" {
        #expect(choose !== page.primaryButton && page.primaryButton.isHiddenOrHasHiddenAncestor)
        #expect(choose.style == .secondary)
    } else {
        #expect(choose.style == .text)
    }
    await scene.close()
}

@Test @MainActor func page22DropTargetOutlineAndForwarding() async throws {
    let scene = Page22Scene()
    scene.tree([])
    try await scene.open([])
    let page = scene.page
    let folder = URL(fileURLWithPath: "/photos/Trip", isDirectory: true)
    let folderBoard = NSPasteboard.withUniqueName(), textBoard = NSPasteboard.withUniqueName()
    let imageBoard = NSPasteboard.withUniqueName()
    defer { folderBoard.releaseGlobally(); textBoard.releaseGlobally(); imageBoard.releaseGlobally() }
    #expect(folderBoard.writeObjects([folder as NSURL]))
    #expect(textBoard.writeObjects(["just text" as NSString]))
    #expect(imageBoard.writeObjects([URL(fileURLWithPath: "/photos/a.jpg") as NSURL]))
    let folderInfo = Page22DropInfo(folderBoard), textInfo = Page22DropInfo(textBoard)
    #expect(page.registeredDraggedTypes.contains(.fileURL))
    #expect(page.draggingEntered(Page22DropInfo(imageBoard)) == [], "the label says folder: a file is refused")
    #expect(!page.performDragOperation(Page22DropInfo(imageBoard)) && scene.dropped.isEmpty)
    #expect(page.draggingEntered(textInfo) == [])
    #expect(!page.isDragOver && page.dropOutline.isHidden)
    #expect(page.draggingEntered(folderInfo) == .copy)
    #expect(page.draggingUpdated(folderInfo) == .copy)
    #expect(page.isDragOver && !page.dropOutline.isHidden)
    #expect(page.dropBorder.lineWidth == 1.5)
    var accent: NSColor?
    page.effectiveAppearance.performAsCurrentDrawingAppearance { accent = DesignColor.accent.nsColor.usingColorSpace(.sRGB) }
    let stroke = try #require(page.dropBorder.strokeColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
    #expect(stroke == accent)
    page.draggingExited(nil)
    #expect(!page.isDragOver && page.dropOutline.isHidden)
    #expect(page.draggingEntered(folderInfo) == .copy)
    #expect(page.performDragOperation(folderInfo))
    #expect(scene.dropped == [[folder]])
    #expect(!page.isDragOver && page.dropOutline.isHidden)
    #expect(!page.performDragOperation(textInfo))
    #expect(scene.dropped == [[folder]])
    scene.shell.setEmptyFolderState(false, recents: [], now: page22Now)
    #expect(page.draggingEntered(folderInfo) == [])
    #expect(!page.isDragOver)
    await scene.close()
}

@Test @MainActor func page22NeverDuringReadingOrOverItems() async throws {
    let pool = ["a.png", "b.jpg", "c.heic"]
    let filters: [Set<String>?] = [nil, ["png"], ["jpg"], ["heic"]]
    var random = Page22Random(state: 0x2222)
    for sequence in 0..<40 {
        let scene = Page22Scene()
        scene.recents = recentFolders(2)
        scene.tree(random.below(2) == 0 ? [] : ["sub"])
        func names() -> [String] { Array(pool.shuffled(using: &random).prefix(random.below(4))) }
        func check(_ label: String) {
            let shell = scene.shell, visible = shell.emptyFolderVisible
            #expect(visible == (!shell.isHidden && scene.session.isEmptyFolder), "\(label): law")
            if visible {
                #expect(!scene.coordinator.isReadingFolder && scene.itemCount == 0, "\(label): no reading, no items")
                #expect(scene.state.isHidden && !shell.searchEmptyVisible, "\(label): alone")
            }
            if scene.coordinator.isReadingFolder { #expect(!visible, "\(label): reading") }
        }
        for step in 0..<(1 + random.below(8)) {
            let label = "seed 0x2222 sequence \(sequence) op \(step)"
            switch random.below(6) {
            case 0: try await scene.open(names()); check("\(label) begin")
            case 1: try await scene.refresh(names()); check("\(label) refresh")
            case 2:
                scene.session.setFolderConditions(.init(selectedExtensions: filters[random.below(filters.count)]))
                scene.sync(); check("\(label) filter")
            case 3:
                guard let task = scene.session.setFolderRecursiveEnabled(!scene.session.folderRecursiveEnabled) else {
                    scene.sync(); check("\(label) toggle skipped"); continue
                }
                let index = scene.nextCall()
                await scene.scanner.waitForStart(index)
                scene.sync(); check("\(label) toggle reading")
                if random.below(3) == 0, let target = scene.session.cancelFolderEntry() {
                    scene.presentation.show(target)
                    scene.sync(); check("\(label) toggle cancelled")
                }
                await scene.scanner.finish(index, names())
                _ = try? await task.value
                scene.sync(); check("\(label) toggle")
            case 4:
                if let target = scene.session.cancelFolderEntry() { scene.presentation.show(target) }
                else { scene.coordinator.cancel() }
                scene.sync(); check("\(label) cancel")
            default:
                scene.shell.showSearchEmpty(true, term: "x")
                scene.sync(); check("\(label) search-empty")
            }
        }
        await scene.close()
    }
}

/// AC-3 at model level only: a filter that empties a non-empty folder is `.noMatches`, never page 22. It does not prove
/// a visible message: the grid surface hides the state host and shows nothing for this case until #125 adds the
/// grid-owned No Images Match page (FOLDER-08 limit).
@Test @MainActor func filterEmptyingFolderIsNoMatchesStatusWithoutPage22() async throws {
    let scene = Page22Scene()
    scene.tree(["sub"])
    try await scene.open(["a.jpg", "b.jpg"])
    scene.session.setFolderConditions(.init(selectedExtensions: ["png"]))
    scene.sync()
    #expect(scene.session.imageStatus == .noMatches)
    #expect(!scene.session.isEmptyFolder && !scene.shell.emptyFolderVisible)
    scene.session.setFolderConditions(.init())
    scene.sync()
    #expect(scene.itemCount == 2 && !scene.shell.emptyFolderVisible)
    await scene.close()
}

@Test @MainActor func page22FooterDisabledSidebarUsableAndSearchEmptyHidden() async throws {
    let scene = Page22Scene()
    let shell = scene.shell
    scene.tree(["sub"])
    scene.presentation.showGrid(reading: false)
    shell.showSearchEmpty(true, term: "x")
    #expect(shell.searchEmptyVisible)
    try await scene.open([])
    #expect(shell.emptyFolderVisible && !shell.searchEmptyVisible)
    #expect(!shell.searchButton.isEnabled && !shell.sortButton.isEnabled && !shell.searchField.isEnabled)
    var walked: [NSView] = [shell.toggleButton]
    while let next = shell.adjacentFooterKeyView(to: walked[walked.count - 1], reverse: false), walked.count < 50 {
        walked.append(next)
    }
    #expect(!walked.contains { $0 === shell.searchButton || $0 === shell.sortButton || $0 === shell.searchField })
    #expect(walked.contains { $0.accessibilityIdentifier() == "grid.sidebar.resize" })
    #expect(walked.contains { $0 === scene.page.chooseButton }, "page controls join the footer's Tab order")
    #expect(shell.toggleButton.isEnabled)
    for width in [CGFloat(1280), 1084] {
        shell.toggleSidebar()
        #expect(scene.page.frame == shell.mainContent.bounds && shell.mainContent.bounds.width == width)
        #expect(shell.emptyFolderVisible)
    }
    try await scene.refresh(["a.png"])
    #expect(!shell.emptyFolderVisible && scene.itemCount == 1)
    #expect(shell.searchButton.isEnabled && shell.sortButton.isEnabled && shell.searchField.isEnabled)
    await scene.close()
}

@Test @MainActor func page22KeyLoopAndAccessibility() async throws {
    let recorder = Page22EscRecorder()
    let scene = Page22Scene(content: recorder)
    scene.tree(["2024 冲绳", "手机备份", "扫描件"])
    try await scene.open([])
    let page = scene.page, shell = scene.shell
    let divider = try #require(shell.adjacentFooterKeyView(to: shell.toggleButton, reverse: false))
    // #114: the implemented Display button stays in the loop on page 22 (never a dead control).
    let subfolderLoop: [NSView] = [shell.toggleButton, divider] + shell.folderTree.rows + page.tiles
        + [page.primaryButton, page.chooseButton, shell.displayButton, scene.grid.collectionView]
    #expect(sameViews(scene.keyWalk(), subfolderLoop))
    for control in page.keyViews { #expect((control as? NSControl)?.focusRingType == .exterior) }
    #expect(page.heading.accessibilityRole()?.rawValue == "AXHeading")
    #expect(page.tiles.first?.accessibilityLabel() == "2024 冲绳, Subfolder")
    #expect(page.accessibilityLabel() == "Content area: drop a folder to open it")
    let tile = try #require(page.tiles.first)
    #expect(tile.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: nil))
    #expect(recorder.count == 1, "Esc passes up the responder chain")

    scene.recents = recentFolders(2)
    scene.tree([])
    scene.sync()
    let recentsLoop: [NSView] = [shell.toggleButton, divider] + shell.folderTree.rows + page.recentRows
        + [page.chooseButton, shell.displayButton, scene.grid.collectionView]
    #expect(sameViews(scene.keyWalk(), recentsLoop))
    for control in page.keyViews { #expect((control as? NSControl)?.focusRingType == .exterior) }
    #expect(page.recentsGroup.accessibilityLabel() == "Recently Opened")
    #expect(page.recentsGroup.accessibilityRole() == .group)
    await scene.close()
}

@Test func page22LocalizationExactValues() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("App/Resources/Localizable.xcstrings"))
    let catalog = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let strings = try #require(catalog["strings"] as? [String: Any])
    func unit(_ key: String, _ language: String) -> String? {
        let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
        return ((localizations?[language] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }
    for (key, chinese) in [
        ("This folder has no images to browse yet", "这个文件夹还没有可浏览的图片"),
        ("Open a subfolder, show the images in subfolders too, or drop another folder here.",
         "打开一个子文件夹，把子文件夹里的图片一起显示，或把其他文件夹拖到这里。"),
        ("Choose another folder to continue, or drop a folder here.", "换一个文件夹继续，或把文件夹拖到这里。"),
        ("Browse Including Subfolders", "包含子文件夹浏览"), ("Choose Another Folder…", "选择其他文件夹…"),
        ("Recently Opened", "最近打开"), ("Subfolder", "子文件夹"), ("%@, Subfolder", "%@，子文件夹"),
        ("Content area: drop a folder to open it", "内容区：可拖入文件夹打开"),
        ("%1$@, %2$@", "%1$@，%2$@"),
    ] {
        #expect(unit(key, "en") == key, "\(key) en")
        #expect(unit(key, "zh-Hans") == chinese, "\(key) zh-Hans")
    }
    let plural = "This level has no images, but has %lld subfolders"
    #expect(unit(plural, "zh-Hans") == "这一层没有图片，但有 %lld 个子文件夹")
    let english = ((strings[plural] as? [String: Any])?["localizations"] as? [String: Any])?["en"] as? [String: Any]
    let forms = (english?["variations"] as? [String: Any])?["plural"] as? [String: Any]
    func form(_ name: String) -> String? {
        ((forms?[name] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
    }
    #expect(form("one") == "This level has no images, but has %lld subfolder")
    #expect(form("other") == "This level has no images, but has %lld subfolders")
    #expect(strings["No Images in This Folder"] == nil)
}

/// Owner decision C (#137): the viewer surface renders page 22's content for an empty folder session, never the
/// generic first-launch state, and its actions route exactly as on the grid page.
@Test @MainActor func viewerEmptyFolderSessionShowsPage22AndRoutesLikeTheGrid() async throws {
    let scene = Page22Scene()
    let recents = recentFolders(2)
    scene.recents = recents
    scene.tree(["sub"])
    try await scene.open([])
    scene.presentation.showViewer()
    scene.state.refresh()
    let page = scene.state.emptyFolderView
    #expect(scene.session.imageStatus == .emptyFolder)
    #expect(!scene.state.isHidden && !page.isHiddenOrHasHiddenAncestor && scene.shell.isHidden)
    #expect(!scene.state.textLines.contains(String(localized: "Drop a photo folder here")))
    #expect(!textLabels(of: scene.state).contains(String(localized: "Drop a photo folder here")))
    #expect(page.heading.stringValue == "This level has no images, but has 1 subfolders")
    let tile = try #require(page.tiles.first)
    #expect(tile.url == scene.folder.appendingPathComponent("sub"))
    tile.performClick(nil)
    #expect(scene.selected == [scene.folder.appendingPathComponent("sub")])
    let opens = scene.host.opens
    page.chooseButton.performClick(nil)
    #expect(scene.host.opens == opens + 1)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let dropped = URL(fileURLWithPath: "/photos/Trip", isDirectory: true)
    #expect(board.writeObjects([dropped as NSURL]))
    #expect(page.performDragOperation(Page22DropInfo(board)) && scene.dropped == [[dropped]])
    scene.tree([])
    let row = try #require(page.recentRows.first)
    row.performClick(nil)
    #expect(scene.opened == [recents[1]])
    scene.tree(["sub"])
    page.primaryButton.performClick(nil)
    #expect(scene.session.folderRecursiveEnabled)
    await scene.close()
}

/// gpt M2: with page 22 shown the footer search is disabled, so focusing search is refused.
@Test @MainActor func page22RefusesSearchFocus() async throws {
    let scene = Page22Scene()
    scene.tree(["sub"])
    try await scene.open([])
    let shell = scene.shell
    #expect(shell.emptyFolderVisible && !shell.searchAvailable)
    shell.focusSearch()
    #expect(shell.searchField.isHidden && !shell.searchButton.isHidden)
    #expect(scene.window.firstResponder !== shell.searchField && scene.window.firstResponder !== shell.searchField.currentEditor())
    try await scene.refresh(["a.png"])
    #expect(shell.searchAvailable)
    shell.focusSearch()
    #expect(!shell.searchField.isHidden)
    await scene.close()
}

/// L1: a real folder URL without a trailing slash is still a folder; a mixed drop forwards only its folders.
@Test @MainActor func page22DropForwardsOnlyFolders() async throws {
    let scene = Page22Scene()
    scene.tree([])
    try await scene.open([])
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let real = URL(fileURLWithPath: base.path, isDirectory: false), file = URL(fileURLWithPath: "/photos/a.jpg")
    #expect(!real.hasDirectoryPath)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    #expect(board.writeObjects([file as NSURL, real as NSURL]))
    #expect(scene.page.performDragOperation(Page22DropInfo(board)))
    #expect(scene.dropped.map { $0.map(\.standardizedFileURL.path) } == [[real.standardizedFileURL.path]])
    await scene.close()
}

/// opus L3: page 22 replacing the Reading State moves focus to its first control, not the hidden collection view.
@Test @MainActor func page22ReplacingReadingStateFocusesAPageControl() async throws {
    for children in [["sub"], []] {
        let scene = Page22Scene()
        scene.recents = recentFolders(2)
        scene.tree(children)
        try await scene.open([])
        let first = try #require(scene.page.keyViews.first)
        #expect(scene.window.firstResponder === first, "children \(children)")
        #expect(!first.isHiddenOrHasHiddenAncestor)
        await scene.close()
    }
    let scene = Page22Scene()
    scene.tree(["sub"])
    try await scene.open([])
    #expect(scene.window.makeFirstResponder(scene.shell.toggleButton))
    scene.shell.setEmptyFolderState(true, recents: [], now: page22Now)
    #expect(scene.window.firstResponder === scene.shell.toggleButton, "focus outside the content area stays put")
    await scene.close()
}
