import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

private actor Issue185Leases: AccessLeasing {
    func acquire(_ request: AccessRequest) -> AccessLease {
        AccessLease(url: URL(fileURLWithPath: "/issue185"), rootID: nil)
    }
    func release(_ lease: AccessLease) {}
}

/// Scripted names per scan call; each call waits for its own `finish(i)`.
private actor GatedScriptScanner: FolderScanning {
    private let script: [[String]]
    private var calls = 0
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<Int> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    init(_ script: [[String]]) { self.script = script }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        let index = calls
        calls += 1
        let ready = startWaiters.filter { calls > $0.0 }
        startWaiters.removeAll { calls > $0.0 }
        ready.forEach { $0.1.resume() }
        if !opened.contains(index) { await withCheckedContinuation { gates[index] = $0 } }
        let names = script[min(index, script.count - 1)]
        try await emit(names.map { FolderEntry(url: folder.appendingPathComponent($0), root: root) })
    }
    func waitForStart(_ index: Int) async {
        if calls > index { return }
        await withCheckedContinuation { startWaiters.append((index, $0)) }
    }
    func finish(_ index: Int) {
        opened.insert(index)
        gates.removeValue(forKey: index)?.resume()
    }
}

/// Completes the grid inside the scan's completion callback, before the state host's observer task runs (#185 order).
@MainActor private final class Issue185ScanHost: FolderScanHost {
    var onComplete: (() -> Void)?
    func openFolderImage(_ url: URL, rootID: AccessRootID) {}
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws {}
    func folderScanDidComplete(count: Int) { onComplete?() }
}

private struct Issue185Random: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor private final class Issue185Scene {
    let session = ViewerSession()
    let window: NSWindow
    let content: NSView
    let canvas: CanvasView
    let shell: GridShellView
    let grid: GridBrowserView
    let state: ViewerStateHost
    let chrome: ViewerChromeOverlay
    let inspector = NSView()
    let presentation: GridViewerPresentation
    let scanHost = Issue185ScanHost()
    var calls = 0
    init(scanner: GatedScriptScanner? = nil) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        content = NSView(frame: frame)
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
        presentation.showViewer()
        if let scanner {
            let coordinator = FolderScanCoordinator(access: Issue185Leases(), scanner: scanner)
            coordinator.host = scanHost
            session.folderScan = coordinator
        }
    }
    func settle() async {
        state.refresh()
        for _ in 0..<50 { await Task.yield() }
    }
    func complete(folder: String, scanner: GatedScriptScanner) async throws {
        let coordinator = try #require(session.folderScan)
        let index = calls
        calls += 1
        var completed = false
        scanHost.onComplete = { [unowned self, unowned coordinator] in
            guard let snapshot = coordinator.snapshot else { return }
            self.presentation.showCompletedGrid(snapshot, selection: self.session.selection, currentItemID: nil, offset: nil)
            completed = true
        }
        defer { scanHost.onComplete = nil }
        let task = coordinator.begin(folder: URL(fileURLWithPath: folder), rootID: AccessRootID())
        presentation.showGrid(reading: true)
        state.display(.readingFolder)
        await scanner.waitForStart(index)
        await scanner.finish(index)
        try await task.value
        #expect(completed, "\(folder): grid completed")
    }
    var itemCount: Int { grid.collectionView(grid.collectionView, numberOfItemsInSection: 0) }
    func expectHidden(_ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(state.isHidden, "\(label): isHidden", sourceLocation: sourceLocation)
        #expect(state.isAccessibilityHidden(), "\(label): accessibility hidden", sourceLocation: sourceLocation)
        #expect(state.hitTest(NSPoint(x: state.frame.midX, y: state.frame.midY)) == nil,
                "\(label): hitTest", sourceLocation: sourceLocation)
        #expect(state.buttons.allSatisfy { $0.isHiddenOrHasHiddenAncestor }, "\(label): buttons",
                sourceLocation: sourceLocation)
        #expect(presentation.isGridVisible, "\(label): grid visible", sourceLocation: sourceLocation)
    }
}

@Test @MainActor func issue185ReopenSameFolderLateEmptyRefreshStaysHidden() async throws {
    let scanner = GatedScriptScanner([["a.png", "b.png", "c.png"]])
    let scene = Issue185Scene(scanner: scanner)
    defer { scene.session.folderScan?.cancel(); scene.window.close() }
    for pass in ["open A", "reopen A"] {
        try await scene.complete(folder: "/issue185/A", scanner: scanner)
        await scene.settle()
        #expect(scene.session.imageStatus == .empty, "\(pass): precondition")
        scene.expectHidden(pass)
        #expect(scene.itemCount == 3, "\(pass): items")
    }
}

@Test @MainActor func issue185OpenAnotherFolderLateEmptyRefreshStaysHidden() async throws {
    let scanner = GatedScriptScanner([["a.png", "b.png", "c.png"], ["d.png", "e.png", "f.png", "g.png", "h.png"]])
    let scene = Issue185Scene(scanner: scanner)
    defer { scene.session.folderScan?.cancel(); scene.window.close() }
    for (folder, count) in [("/issue185/A", 3), ("/issue185/B", 5)] {
        try await scene.complete(folder: folder, scanner: scanner)
        await scene.settle()
        #expect(scene.session.imageStatus == .empty, "\(folder): precondition")
        scene.expectHidden(folder)
        #expect(scene.itemCount == count, "\(folder): items")
    }
}

@Test @MainActor func issue185WatchedRefreshKeepsOverlayHidden() async throws {
    let scanner = GatedScriptScanner([["a.png", "b.png"], ["a.png", "b.png", "c.png", "d.png"]])
    let scene = Issue185Scene(scanner: scanner)
    defer { scene.session.folderScan?.cancel(); scene.window.close() }
    try await scene.complete(folder: "/issue185/A", scanner: scanner)
    await scene.settle()
    scene.expectHidden("completed")
    #expect(scene.itemCount == 2)
    let coordinator = try #require(scene.session.folderScan)
    let refresh = try #require(coordinator.refresh())
    await scanner.finish(1)
    try await refresh.value
    scene.presentation.showCompletedGrid(try #require(coordinator.snapshot), selection: scene.session.selection,
                                         currentItemID: nil, offset: nil)
    await scene.settle()
    #expect(scene.session.imageStatus == .empty)
    scene.expectHidden("watched refresh")
    #expect(scene.itemCount == 4)
}

@Test @MainActor func issue185ViewerSurfaceReshowsUnchangedEmptyStatus() async throws {
    let scene = Issue185Scene()
    defer { scene.window.close() }
    #expect(!scene.state.isHidden && scene.session.imageStatus == .empty)
    for target in [FolderEntryRestoreTarget.empty, .viewer(URL(fileURLWithPath: "/issue185/A/a.png"))] {
        scene.presentation.showGrid(reading: false)
        await scene.settle()
        scene.expectHidden("grid before \(target)")
        scene.presentation.show(target)
        #expect(!scene.state.isHidden && !scene.state.isAccessibilityHidden(), "\(target): visible")
        #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.open"])
        #expect(scene.state.textLines.first == "Drop a photo folder here")
        let button = try #require(scene.state.buttons.first)
        let center = scene.state.convert(NSPoint(x: button.frame.midX, y: button.frame.midY), to: scene.content)
        #expect(scene.state.hitTest(center) === button, "\(target): button hit")
    }
}

@Test @MainActor func issue185SurfaceVisibilityInvariantAcrossGeneratedTransitions() {
    enum Surface { case viewer, gridReading, grid }
    let statuses: [ViewerImageStatus] = [.empty, .loading("a.png"), .readingFolder,
        .folderScanFailed("Folder scan failed", "A"), .noMatches, .showing, .detailLimited,
        .failed(.corruptImage, "b.png")]
    let folder = URL(fileURLWithPath: "/issue185/A")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID()), url: folder)
    let snapshot3 = FolderSnapshot(version: .init(rootID: root.id, folder: folder, generation: 1),
        entries: ["a.png", "b.png", "c.png"].map { FolderEntry(url: folder.appendingPathComponent($0), root: root) },
        isComplete: true)
    var random = Issue185Random(state: 0x185)
    for sequence in 0..<120 {
        let scene = Issue185Scene()
        defer { scene.window.close() }
        let state = scene.state, presentation = scene.presentation
        var surface = Surface.viewer, lastStatus = scene.session.imageStatus
        for step in 0..<10 {
            let op = Int(random.next() % 10)
            var name: String
            switch op {
            case 0: presentation.showViewer(); surface = .viewer; name = "showViewer"
            case 1: presentation.showGrid(reading: false); surface = .grid; name = "showGrid(false)"
            case 2: presentation.showGrid(reading: true); surface = .gridReading; name = "showGrid(true)"
            case 3: presentation.show(.grid); surface = .grid; name = "show(.grid)"
            case 4: presentation.show(.empty); surface = .viewer; name = "show(.empty)"
            case 5: presentation.show(.viewer(folder.appendingPathComponent("a.png"))); surface = .viewer
                name = "show(.viewer)"
            case 6: presentation.restoreGrid(snapshot3, selection: scene.session.selection, offset: nil)
                surface = .grid; name = "restoreGrid"
            case 7: if presentation.showReadingOverGrid(true) { surface = .gridReading }
                name = "showReadingOverGrid"
            case 8:
                let status = statuses[Int(random.next() % UInt64(statuses.count))]
                state.display(status); lastStatus = status; name = "display(\(status))"
            default: state.refresh(); lastStatus = scene.session.imageStatus; name = "refresh"
            }
            let label = "seed 0x185 sequence \(sequence) step \(step) \(name) surface \(surface) status \(lastStatus)"
            switch surface {
            case .grid:
                #expect(state.isHidden && state.isAccessibilityHidden(), "\(label)")
                #expect(state.hitTest(NSPoint(x: state.frame.midX, y: state.frame.midY)) == nil, "\(label)")
            case .viewer:
                #expect(state.isHidden == (lastStatus == .showing), "\(label)")
                if !state.isHidden { #expect(!state.textLines.isEmpty, "\(label)") }
            case .gridReading:
                if lastStatus != .showing {
                    #expect(!state.isHidden && !state.isAccessibilityHidden(), "\(label)")
                    #expect(state.frame == scene.shell.convert(scene.shell.mainFrame, to: scene.content), "\(label)")
                }
            }
        }
    }
}
