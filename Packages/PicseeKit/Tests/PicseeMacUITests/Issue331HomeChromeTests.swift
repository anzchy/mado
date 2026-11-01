import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

/// #331 (spec #311 amendment, 2026-10-31): 「Hide all on Home (Recommended)」. The Home (no folder, no image: status
/// `.empty`) shows only its centre, as pinned page 21; the viewer's floating controls come back once an image opens.
private actor HomeOpeningGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}

/// The adapter CanvasWindowController provides: chrome visibility relinks the state host's loop; focus moves the window.
@MainActor private final class HomeChromeHost: ViewerImageHost, ViewerSessionNavigationHost, ViewerChromeHost {
    weak var canvas: CanvasView?
    weak var state: ViewerStateHost?
    weak var chrome: ViewerChromeOverlay?
    var canNavigate = false
    var hasImage: Bool { canvas?.hasImage == true }
    func beginImageOpening() { canvas?.beginOpening() }
    func installImage(_ image: DecodedImage, fileURL: URL) { canvas?.install(image) }
    func imageLoadFailed(_ error: any Error) { canvas?.showFailure() }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { _ = canvas?.apply(command, from: entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { canvas?.apply(command, from: entry) }
    func requestOpen() {}
    func showInspector(_ visible: Bool) {}
    func navigate(_ direction: NavigationDirection) {}
    func applyFocus(_ focus: FocusContext) {
        if focus == .canvas, let canvas { canvas.window?.makeFirstResponder(canvas) }
    }
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {
        guard let canvas, let state, let chrome else { return }
        chrome.setToolsVisible(toolsVisible)
        state.linkKeyViews(to: canvas, chrome: chrome)
    }
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool {
        guard let state, let chrome else { return false }
        return ViewerStateFocus.move(reverse: reverse, entering: entering, state: state, chrome: chrome)
    }
}

/// One window's viewer views, wired in CanvasWindowController's order (overlay link, state link, then chrome host).
@MainActor private final class HomeChromeScene {
    let session = ViewerSession()
    let host = HomeChromeHost()
    let window: NSWindow
    let content: NSView
    let canvas: CanvasView
    let state: ViewerStateHost
    let chrome: ViewerChromeOverlay
    init(hidesOnHome: Bool) {
        _ = NSApplication.shared
        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.autorecalculatesKeyViewLoop = false
        content = NSView(frame: frame)
        canvas = CanvasView(frame: frame, session: session)
        state = ViewerStateHost(frame: frame, session: session)
        chrome = ViewerChromeOverlay(frame: frame, session: session, hidesOnHome: hidesOnHome)
        host.canvas = canvas; host.state = state; host.chrome = chrome
        session.host = host; session.imageLoader.host = host
        let session = session
        canvas.openingGeneration = { session.imageLoader.generation }
        canvas.onTab = { session.tab(reverse: $0) }
        content.addSubview(canvas); content.addSubview(state); content.addSubview(chrome)
        window.contentView = content
        state.subviews.compactMap { $0 as? FirstLaunchView }.first?.pinAccessibility()
        chrome.linkKeyViews(to: canvas)
        state.linkKeyViews(to: canvas, chrome: chrome)
        session.chromeHost = host
    }
    var toolPoint: NSPoint { chrome.tools[0].convert(NSPoint(x: 15, y: 14), to: content) }
    @discardableResult func open(_ file: URL) -> Task<Void, Never>? {
        let pipeline = StatesPipeline(), leases = StatesLeases()
        session.openImage(file, maximumPixelSize: 512) {
            try await AccessImageSource.open(.fileGrant(file), access: leases, pipeline: pipeline)
        }
        return session.imageLoader.loadTask
    }
}

/// The views reached by following `nextKeyView` from the canvas, without the canvas itself.
@MainActor private func keyLoop(from canvas: NSView) -> [NSView] {
    var loop: [NSView] = []
    var view = canvas.nextKeyView
    while let next = view, next !== canvas, loop.count < 32 { loop.append(next); view = next.nextKeyView }
    return loop
}

@MainActor private func loopIDs(_ canvas: NSView) -> [String] { keyLoop(from: canvas).map { $0.accessibilityIdentifier() } }

@MainActor private func expectHidden(_ chrome: ViewerChromeOverlay, _ content: NSView, _ canvas: NSView, _ stage: String) {
    let point = chrome.tools[0].convert(NSPoint(x: 15, y: 14), to: content)
    #expect(chrome.groups.allSatisfy { $0.isHidden }, "\(stage): groups hidden")
    #expect(chrome.tools.allSatisfy { $0.isHidden }, "\(stage): tools hidden")
    #expect(!(content.hitTest(point) is ChromeToolView), "\(stage): hit test falls through, got \(String(describing: content.hitTest(point)))")
    #expect(chrome.accessibilityChildren()?.isEmpty == true, "\(stage): no accessibility children")
    #expect(chrome.tools.allSatisfy { !$0.acceptsFirstResponder }, "\(stage): no tool takes focus")
    #expect(!keyLoop(from: canvas).contains { $0 is ChromeToolView }, "\(stage): no tool in the key loop \(loopIDs(canvas))")
}

@MainActor private func expectShown(_ chrome: ViewerChromeOverlay, _ content: NSView, _ canvas: NSView, _ stage: String) {
    let point = chrome.tools[0].convert(NSPoint(x: 15, y: 14), to: content)
    let children = (chrome.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
    #expect(chrome.groups.allSatisfy { !$0.isHidden }, "\(stage): groups shown")
    #expect(chrome.tools.allSatisfy { !$0.isHidden }, "\(stage): tools shown")
    #expect(content.hitTest(point) === chrome.tools[0], "\(stage): the first tool is hit, got \(String(describing: content.hitTest(point)))")
    #expect(chrome.tools.allSatisfy { tool in children.contains { $0 === tool } }, "\(stage): all 7 tools are accessible")
    #expect(chrome.tools[0].acceptsFirstResponder, "\(stage): the first tool takes focus")
    #expect(keyLoop(from: canvas).contains { $0 === chrome.tools[0] }, "\(stage): the first tool is in the key loop \(loopIDs(canvas))")
}

private enum HomeOp: CaseIterable { case show, hide, home, notHome, refresh }

@Test(arguments: [false, true]) @MainActor func i331ShownStateLawHoldsOverEveryShortSequence(_ hidesOnHome: Bool) {
    _ = NSApplication.shared
    let session = ViewerSession()
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
                          styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.autorecalculatesKeyViewLoop = false
    defer { window.close() }
    let content = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 640))
    let canvas = CanvasView(frame: content.bounds, session: session)
    let chrome = ViewerChromeOverlay(frame: content.bounds, session: session, hidesOnHome: hidesOnHome)
    content.addSubview(canvas); content.addSubview(chrome)
    window.contentView = content
    chrome.linkKeyViews(to: canvas)
    let point = chrome.tools[0].convert(NSPoint(x: 15, y: 14), to: content)
    var requested = true, home = false
    let ops = HomeOp.allCases
    for index in 0..<(ops.count * ops.count * ops.count * ops.count) {
        var code = index
        for step in 0..<4 {
            let op = ops[code % ops.count]; code /= ops.count
            switch op {
            case .show: chrome.setToolsVisible(true); requested = true
            case .hide: chrome.setToolsVisible(false); requested = false
            case .home: chrome.setHome(true); home = true
            case .notHome: chrome.setHome(false); home = false
            case .refresh: chrome.refresh(filename: nil, position: nil)
            }
            let model = requested && !(hidesOnHome && home)
            let stage = "flag \(hidesOnHome) sequence \(index) step \(step) op \(op)"
            #expect(chrome.groups.allSatisfy { $0.isHidden == !model }, "\(stage): groups")
            #expect(chrome.tools.allSatisfy { $0.isHidden == !model }, "\(stage): tools")
            #expect(chrome.accessibilityChildren()?.count == (model ? 7 : 0), "\(stage): accessibility children")
            #expect((content.hitTest(point) === chrome.tools[0]) == model, "\(stage): hit test")
            #expect(chrome.tools[0].acceptsFirstResponder == model, "\(stage): first responder")
            #expect((canvas.nextKeyView is ChromeToolView) == model, "\(stage): key loop")
        }
    }
}

@Test @MainActor func i331DefaultOverlayIgnoresHomeInTheRealHost() {
    let scene = HomeChromeScene(hidesOnHome: false)
    defer { scene.window.close() }
    #expect(scene.session.imageStatus == .empty)
    expectShown(scene.chrome, scene.content, scene.canvas, "default overlay on the Home")
    #expect(keyLoop(from: scene.canvas).first === scene.state.buttons.first)
    #expect(scene.state.buttons.first?.accessibilityIdentifier() == "state.open")
}

@Test @MainActor func i331ColdHomeHidesControlsAndKeepsOpenInTheLoop() {
    let scene = HomeChromeScene(hidesOnHome: true)
    defer { scene.window.close() }
    #expect(scene.session.imageStatus == .empty)
    #expect(!scene.state.isHidden)
    expectHidden(scene.chrome, scene.content, scene.canvas, "cold Home")
    #expect(loopIDs(scene.canvas) == ["state.open"])
}

@Test @MainActor func i331TabOnHomeFocusesOpenAndControlsStayHidden() throws {
    let scene = HomeChromeScene(hidesOnHome: true)
    defer { scene.window.close() }
    scene.session.updateFocus(.canvas)
    #expect(scene.window.makeFirstResponder(scene.canvas))
    scene.canvas.keyDown(with: try chromeKey(48, "\t"))
    let open = try #require(scene.state.buttons.first)
    #expect(open.accessibilityIdentifier() == "state.open")
    #expect(scene.window.firstResponder === open, "first Tab focuses Choose Folder…")
    #expect(scene.chrome.groups.allSatisfy { $0.isHidden }, "keyboard recall does not reveal the controls on the Home")
    scene.window.firstResponder?.keyDown(with: try chromeKey(48, "\t"))
    #expect(!(scene.window.firstResponder is ChromeToolView))
    #expect(scene.session.inspectorFocus.focus == .canvas)
    #expect(scene.window.firstResponder === scene.canvas, "second Tab returns to the canvas")
    expectHidden(scene.chrome, scene.content, scene.canvas, "after two Tabs")
}

@Test(.timeLimit(.minutes(2))) @MainActor func i331LoadingShowsControlsAndCancelReturnsHomeHidden() async throws {
    let scene = HomeChromeScene(hidesOnHome: true)
    defer { scene.window.close() }
    let gate = HomeOpeningGate()
    scene.session.openImage(URL(fileURLWithPath: "/B.png"), maximumPixelSize: 512) {
        await gate.wait(); throw ImageLoadError(.cancelled)
    }
    let task = scene.session.imageLoader.loadTask
    await gate.entered()
    await waitUntil { scene.state.buttons.first?.accessibilityIdentifier() == "state.cancel" }
    #expect(scene.session.imageStatus == .loading("B.png"))
    #expect(scene.chrome.filename == nil)
    expectShown(scene.chrome, scene.content, scene.canvas, "loading")
    #expect(loopIDs(scene.canvas).first == "state.cancel")

    let cancel = try #require(scene.state.buttons.first)
    cancel.performClick(nil)
    await waitUntil { scene.state.buttons.first?.accessibilityIdentifier() == "state.open" }
    #expect(scene.session.imageStatus == .empty)
    expectHidden(scene.chrome, scene.content, scene.canvas, "cancelled back to the Home")
    #expect(loopIDs(scene.canvas) == ["state.open"])

    // A hide requested on the Home still holds after leaving it; the next show request reveals.
    scene.chrome.setToolsVisible(false)
    scene.state.display(.loading("C.png"))
    expectHidden(scene.chrome, scene.content, scene.canvas, "left the Home with tools hidden")
    scene.chrome.setToolsVisible(true)
    expectShown(scene.chrome, scene.content, scene.canvas, "shown on request after leaving the Home")
    scene.state.display(.empty)
    expectHidden(scene.chrome, scene.content, scene.canvas, "back on the Home")
    await gate.release()
    await task?.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func i331ShowingImageShowsControls() async throws {
    let scene = HomeChromeScene(hidesOnHome: true)
    defer { scene.window.close() }
    await scene.open(URL(fileURLWithPath: "/A.png"))?.value
    await waitUntil { scene.state.isHidden }
    #expect(scene.session.imageStatus == .showing)
    expectShown(scene.chrome, scene.content, scene.canvas, "showing an image")
    #expect(!keyLoop(from: scene.canvas).contains { $0 is NSButton && !($0 is ChromeToolView) })
}

@Test @MainActor func i331NonEmptyStatusesKeepControlsAndRefreshNeverRevealsOnHome() {
    let scene = HomeChromeScene(hidesOnHome: true)
    defer { scene.window.close() }
    scene.chrome.refresh(filename: "A.png", position: "1 / 2")
    scene.chrome.refresh(session: scene.session)
    expectHidden(scene.chrome, scene.content, scene.canvas, "refresh on the Home")
    #expect(loopIDs(scene.canvas) == ["state.open"], "refresh on the Home keeps Choose Folder… in the loop")
    let statuses: [ViewerImageStatus] = [.emptyFolder, .readingFolder, .noMatches, .detailLimited,
        .folderScanFailed("x", "x"), .showing, .loading("x"), .failed(.corruptImage, "x")]
    for status in statuses {
        scene.state.display(status)
        expectShown(scene.chrome, scene.content, scene.canvas, "\(status)")
        #expect(scene.chrome.accessibilityChildren()?.count == 7 + (scene.chrome.filename == nil ? 0 : 1))
        scene.state.display(.empty)
        expectHidden(scene.chrome, scene.content, scene.canvas, "\(status) then the Home")
        #expect(loopIDs(scene.canvas) == ["state.open"], "\(status) then the Home: \(loopIDs(scene.canvas))")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func i331TwoOverlaysDecideIndependently() async throws {
    let a = HomeChromeScene(hidesOnHome: true), b = HomeChromeScene(hidesOnHome: true)
    defer { a.window.close(); b.window.close() }
    await b.open(URL(fileURLWithPath: "/A.png"))?.value
    await waitUntil { b.state.isHidden }
    expectShown(b.chrome, b.content, b.canvas, "B shows an image")
    expectHidden(a.chrome, a.content, a.canvas, "A stays on the Home")
    #expect(loopIDs(a.canvas) == ["state.open"])
    b.session.cancelImageOpening()
    await waitUntil { !b.state.isHidden }
    #expect(b.session.imageStatus == .empty)
    expectHidden(b.chrome, b.content, b.canvas, "B back on the Home")
    expectHidden(a.chrome, a.content, a.canvas, "A still on the Home")
    #expect(loopIDs(a.canvas) == ["state.open"])
}

/// Review M1: the Home hides the controls without the session's focus lock, so a focused control hands focus back to
/// the canvas instead of keeping it on a hidden view.
@Test(.timeLimit(.minutes(2))) @MainActor func i331FocusedControlMovesToCanvasOnEnteringHome() async throws {
    let scene = HomeChromeScene(hidesOnHome: true)
    defer { scene.window.close() }
    await scene.open(URL(fileURLWithPath: "/A.png"))?.value
    await waitUntil { scene.state.isHidden }
    expectShown(scene.chrome, scene.content, scene.canvas, "showing an image")
    #expect(scene.window.makeFirstResponder(scene.chrome.tools[0]))
    #expect(scene.session.inspectorFocus.focus == .tools)
    scene.session.cancelImageOpening()
    await waitUntil { !scene.state.isHidden }
    #expect(scene.session.imageStatus == .empty)
    #expect(!(scene.window.firstResponder is ChromeToolView), "focus left on a hidden control")
    #expect(scene.window.firstResponder === scene.canvas)
    #expect(scene.session.inspectorFocus.focus == .canvas)
    expectHidden(scene.chrome, scene.content, scene.canvas, "entered the Home from a focused control")
}
