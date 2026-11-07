import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

private actor StateFocusGate {
    private var pending: CheckedContinuation<AccessImageSource, any Error>?
    private var arrival: CheckedContinuation<Void, Never>?
    func open() async throws -> AccessImageSource {
        try await withCheckedThrowingContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func finish() { pending?.resume(throwing: ImageLoadError(.cancelled)); pending = nil }
}

/// Mirrors the existing App veto without changing its ordering contract.
@MainActor private final class StateFocusWindow: NSWindow {
    weak var canvas: NSView?
    weak var session: ViewerSession?
    var prematureCanvasRequests = 0
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let canvas, responder === canvas, session?.inspectorFocus.focus != .canvas {
            prematureCanvasRequests += 1
            return false
        }
        return super.makeFirstResponder(responder)
    }
}

@MainActor private final class StateFocusInspector: NSView {
    weak var session: ViewerSession?
    override var acceptsFirstResponder: Bool { !isHidden }
    override func becomeFirstResponder() -> Bool { session?.updateFocus(.textInput); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48 { session?.tab(reverse: event.modifierFlags.contains(.shift)) }
    }
}

@MainActor private final class StateFocusNativeHost: ViewerSessionNavigationHost, ViewerChromeHost {
    weak var session: ViewerSession?
    weak var canvas: CanvasView?
    weak var state: ViewerStateHost?
    weak var chrome: ViewerChromeOverlay?
    weak var inspector: StateFocusInspector?
    var hasImage: Bool { canvas?.hasImage == true }
    var canNavigate = false
    var opens = 0
    var canvasActions = 0
    var navigations = 0
    var toolsVisibleWhenFocusRequested: [Bool] = []
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { canvasActions += 1 }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { canvasActions += 1; return 1 }
    func requestOpen() { opens += 1 }
    func navigate(_ direction: NavigationDirection) { navigations += 1 }
    func showInspector(_ visible: Bool) { inspector?.isHidden = !visible }
    func applyFocus(_ focus: FocusContext) {
        if focus == .canvas, let canvas { canvas.window?.makeFirstResponder(canvas) }
        if focus == .textInput, let inspector { inspector.window?.makeFirstResponder(inspector) }
    }
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {
        guard let canvas, let state, let chrome else { return }
        chrome.setToolsVisible(toolsVisible)
        state.linkKeyViews(to: canvas, chrome: chrome)
    }
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool {
        guard let state, let chrome else { return false }
        toolsVisibleWhenFocusRequested.append(chrome.groups.allSatisfy { !$0.isHidden })
        return ViewerStateFocus.move(reverse: reverse, entering: entering, state: state, chrome: chrome)
    }
}

@MainActor private final class StateFocusScene {
    let clock = ChromeViewClock()
    let session: ViewerSession
    let window: StateFocusWindow
    let canvas: CanvasView
    let state: ViewerStateHost
    let chrome: ViewerChromeOverlay
    let inspector = StateFocusInspector(frame: NSRect(x: 660, y: 100, width: 240, height: 300))
    let host = StateFocusNativeHost()
    let gate = StateFocusGate()
    init() {
        _ = NSApplication.shared
        session = ViewerSession(clock: clock)
        let frame = NSRect(x: 0, y: 0, width: 960, height: 640)
        window = StateFocusWindow(contentRect: NSRect(x: -20000, y: -20000, width: 960, height: 640),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.autorecalculatesKeyViewLoop = false
        canvas = CanvasView(frame: frame, session: session)
        state = ViewerStateHost(frame: frame, session: session)
        chrome = ViewerChromeOverlay(frame: frame, session: session)
        let content = NSView(frame: frame)
        content.addSubview(canvas); content.addSubview(state); content.addSubview(chrome); content.addSubview(inspector)
        inspector.isHidden = true; inspector.session = session
        window.contentView = content; window.canvas = canvas; window.session = session
        host.session = session; host.canvas = canvas; host.state = state; host.chrome = chrome; host.inspector = inspector
        session.host = host; session.chromeHost = host
        let session = session
        canvas.onTab = { session.tab(reverse: $0) }
        canvas.onCommand = { CommandRouter().route($0, from: .key, to: session) }
    }
    func prepare(_ mode: Int) async {
        host.canNavigate = mode == 3
        if mode == 1 {
            let gate = gate
            session.openImage(URL(fileURLWithPath: "/Focus.png"), maximumPixelSize: 512) { try await gate.open() }
            await gate.entered()
        } else if mode >= 2 {
            session.openImage(URL(fileURLWithPath: "/Focus.png"), maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
            await session.imageLoader.loadTask?.value
        }
        state.refresh(); chrome.refresh(); state.linkKeyViews(to: canvas, chrome: chrome)
        session.updateFocus(.canvas); window.makeFirstResponder(canvas)
    }
    func close() {
        session.closeImage()
        let gate = gate
        Task { await gate.finish() }
        window.close()
    }
    func assertFocus(_ target: NSView) {
        #expect(window.firstResponder === target)
        #expect(session.chrome.locks.contains(.keyboardFocus) == (target !== canvas))
        #expect(session.inspectorFocus.focus == (target === canvas ? .canvas : target === inspector ? .textInput : .tools))
        if let button = target as? NSButton {
            #expect(button.focusRingType == .exterior)
            #expect(button.focusRingMaskBounds.width > 0)
        }
    }
}

// Reverse canvas→Inspector uses the separately approved minimal Session.tab branch.
@Test(arguments: [0, 1, 2, 3], [false, true]) @MainActor func statesFocusTraversesEveryStateInBothDirections(_ mode: Int, _ inspectorVisible: Bool) async throws {
    let scene = StateFocusScene()
    defer { scene.close() }
    await scene.prepare(mode)
    scene.session.setInspectorVisible(inspectorVisible)
    let expectedIDs = mode == 0 ? ["state.open"] : mode == 1 ? ["state.cancel"] : mode == 2 ? ["state.retry"] : ["state.retry", "state.next"]
    #expect(scene.state.buttons.map { $0.accessibilityIdentifier() } == expectedIDs)
    let tools = scene.chrome.tools.filter(\.acceptsFirstResponder)
    let controls: [NSView] = scene.state.buttons + tools + (inspectorVisible ? [scene.inspector] : [])
    let generation = scene.session.imageLoader.generation
    for target in controls + [scene.canvas] {
        scene.window.firstResponder?.keyDown(with: try chromeKey(48, "\t"))
        scene.assertFocus(target)
    }
    for target in Array(controls.reversed()) + [scene.canvas] {
        scene.window.firstResponder?.keyDown(with: try chromeKey(48, "\t", shift: true))
        scene.assertFocus(target)
    }
    #expect(scene.canvas.nextValidKeyView === scene.state.buttons.first)
    #expect(scene.session.imageLoader.generation == generation)
    #expect(scene.host.opens == 0)
    #expect(scene.host.canvasActions == 0)
    #expect(scene.host.navigations == 0)
    #expect(scene.window.prematureCanvasRequests == 0)
}

@Test(arguments: [0, 1, 2, 3]) @MainActor func statesFocusRecallsThenEscapesOneLevelAndRepairsReplacement(_ mode: Int) async throws {
    let scene = StateFocusScene()
    defer { scene.close() }
    await scene.prepare(mode)
    scene.clock.now = 2.5; scene.session.advanceChrome()
    #expect(scene.chrome.groups.allSatisfy { $0.isHidden })
    scene.canvas.keyDown(with: try chromeKey(48, "\t"))
    let first = try #require(scene.state.buttons.first)
    scene.assertFocus(first)
    #expect(scene.host.toolsVisibleWhenFocusRequested.last == true)

    let a = ItemID.ephemeral(UUID(uuidString: "00000000-0000-0000-0000-000000000011")!)
    let b = ItemID.ephemeral(UUID(uuidString: "00000000-0000-0000-0000-000000000012")!)
    scene.session.beginBrowsing(items: [a, b], sourceVersion: .init(1), scrollAnchor: a)
    scene.session.select(a)
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    #expect(router.route(.preview, from: .button, to: scene.session))
    let generation = scene.session.imageLoader.generation
    for button in scene.state.buttons {
        #expect(scene.window.makeFirstResponder(button))
        scene.assertFocus(button)
        scene.session.setMenuTracking(true)
        button.keyDown(with: try chromeKey(53, "\u{1b}"))
        #expect(scene.window.firstResponder === button)
        #expect(scene.session.previewSet?.currentItemID == a)
        scene.session.setMenuTracking(false)
        button.keyDown(with: try chromeKey(53, "\u{1b}"))
        scene.assertFocus(scene.canvas)
        #expect(scene.session.mode == .viewing)
        #expect(scene.session.previewSet?.currentItemID == a)
        #expect(scene.session.imageLoader.generation == generation)
    }
    scene.canvas.keyDown(with: try chromeKey(53, "\u{1b}"))
    #expect(scene.session.mode == .browsing)
    #expect(scene.session.previewSet == nil)
    #expect(scene.session.currentItemID == a)
    #expect(scene.window.makeFirstResponder(first))
    scene.state.display(.showing)
    scene.assertFocus(scene.canvas)
    #expect(scene.window.prematureCanvasRequests == 0)
    #expect(scene.host.opens == 0)
    #expect(scene.host.canvasActions == 0)
    #expect(scene.host.navigations == 0)
    #expect(scene.session.imageLoader.generation == generation)
}

@Test @MainActor func statesFocusKeyboardActivationIgnoresUnknownDisabledAndHiddenInputs() async throws {
    let scene = StateFocusScene()
    defer { scene.close() }
    await scene.prepare(0)
    let open = try #require(scene.state.buttons.first)
    #expect(scene.window.makeFirstResponder(open))
    scene.state.refresh()
    #expect(scene.state.buttons.first === open)
    #expect(scene.window.firstResponder === open)
    open.keyDown(with: try chromeKey(49, " "))
    open.keyDown(with: try chromeKey(36, "\r"))
    #expect(scene.host.opens == 2)
    open.keyDown(with: try chromeKey(0, "x"))
    #expect(scene.host.opens == 2)
    let generation = scene.session.imageLoader.generation
    open.isEnabled = false
    #expect(!open.acceptsFirstResponder)
    #expect(!open.canBecomeKeyView)
    open.keyDown(with: try chromeKey(49, " "))
    open.keyDown(with: try chromeKey(48, "\t"))
    #expect(scene.host.opens == 2)
    #expect(scene.session.imageLoader.generation == generation)
    open.isEnabled = true; scene.state.isHidden = true
    #expect(!open.acceptsFirstResponder)
    open.keyDown(with: try chromeKey(36, "\r"))
    #expect(scene.host.opens == 2)
    scene.state.isHidden = false
    #expect(open.acceptsFirstResponder)

    let loading = StateFocusScene()
    defer { loading.close() }
    await loading.prepare(1)
    let cancel = try #require(loading.state.buttons.first)
    let pending = loading.session.imageLoader.loadTask
    cancel.keyDown(with: try chromeKey(36, "\r"))
    #expect(loading.session.imageStatus == .empty)
    #expect(loading.session.imageLoader.phase == .idle)
    #expect(pending?.isCancelled == true)

    let failure = StateFocusScene()
    defer { failure.close() }
    await failure.prepare(3)
    var retries = 0
    failure.state.onRetry = { retries += 1 }
    let retry = try #require(failure.state.buttons.first)
    let next = try #require(failure.state.buttons.last)
    retry.keyDown(with: try chromeKey(49, " "))
    #expect(retries == 1)
    next.keyDown(with: try chromeKey(36, "\r"))
    #expect(failure.host.navigations == 1)
    #expect(!ViewerStateFocus.move(reverse: false, entering: false, state: failure.state, chrome: failure.chrome))
    failure.state.display(.showing); failure.chrome.setToolsVisible(false)
    #expect(!ViewerStateFocus.move(reverse: false, entering: true, state: failure.state, chrome: failure.chrome))
    let detached = ViewerStateHost(frame: .zero, session: failure.session)
    #expect(!ViewerStateFocus.move(reverse: false, entering: true, state: detached, chrome: failure.chrome))
}

@Test @MainActor func statesFocusMaskDrawsOpaqueCenterAndRoundedTransparentCorner() async throws {
    let scene = StateFocusScene()
    defer { scene.close() }
    await scene.prepare(0)
    let button = try #require(scene.state.buttons.first)
    #expect(scene.window.makeFirstResponder(button))
    let width = Int(button.bounds.width), height = Int(button.bounds.height)
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.bitmapData?.initialize(repeating: 0, count: bitmap.bytesPerRow * height)
    let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    button.drawFocusRingMask()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    #expect(bitmap.colorAt(x: width / 2, y: height / 2)?.alphaComponent == 1)
    #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
}
