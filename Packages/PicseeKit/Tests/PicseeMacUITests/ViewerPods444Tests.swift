import AppKit
import SwiftUI
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

// #444: page 14's bottom tools. Leading pod 侧栏 / 返回网格 / 更多; zoom pod − / 缩放模式 (chevron, menu) / +.
// Geometry measured from viewer-controls.html in Chromium at 1280×800, identical in ?theme=light and ?theme=dark:
// leading pod left 16 top 748 104×38, buttons 30×28 at 21/53/85; zoom pod left 1090 174×38, − at 1095,
// select at 1127 top 754 100×26, + at 1229; the select's chevron is drawn about 9×6 centred at x 1221, y 767.
// Native y counts from the content bottom: 800 − 748 − 38 = 14.

@MainActor final class Pods444Host: ViewerSessionNavigationHost, ViewerSingleImageReturnHost, ViewerChromeHost {
    var hasImage = true
    var canNavigate = true
    var canReturnToFolder = false
    var available = false
    var zooms: [CommandID] = []
    var returns = 0, folderReturns = 0
    var intents: [ViewerChromeIntent] = []
    var store: InMemoryDisplayPreferencesStore?
    weak var overlay: ViewerChromeOverlay?
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { zooms.append(command); return 1.25 }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func navigate(_ direction: NavigationDirection) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() { returns += 1 }
    func returnSingleImageToFolder() { folderReturns += 1 }
    func applyChrome(toolsVisible: Bool, trafficLightsVisible: Bool) {}
    func focusChromeTool(reverse: Bool, entering: Bool) -> Bool {
        overlay?.focusTool(reverse: reverse, entering: entering) ?? false
    }
    var viewerSidebarAvailable: Bool { available }
    func performChromeIntent(_ intent: ViewerChromeIntent) {
        intents.append(intent)
    }
}

@MainActor final class RecordingMenuPresenter: ChromeMenuPresenting {
    var presented: [(menu: NSMenu, anchor: NSView)] = []
    var inside: ((NSMenu) -> Void)?
    var choose: Int?
    func present(_ menu: NSMenu, from view: NSView) {
        presented.append((menu, view))
        inside?(menu)
        if let choose { menu.performActionForItem(at: choose) }
    }
}

enum Pods444Source: Sendable { case browsing, preview, single, files }

@MainActor struct Pods444Scene {
    let window: NSWindow
    let overlay: ViewerChromeOverlay
    let session: ViewerSession
    let host: Pods444Host
    let store: InMemoryDisplayPreferencesStore
    let clock: ChromeViewClock
    let presenter = RecordingMenuPresenter()
    let items: [ItemID]
    init(_ source: Pods444Source = .preview, size: NSSize = NSSize(width: 1280, height: 800),
         available: Bool = true, hasImage: Bool = true, canReturnToFolder: Bool = false,
         appearance: NSAppearance.Name = .aqua) {
        _ = NSApplication.shared
        store = InMemoryDisplayPreferencesStore()
        host = Pods444Host()
        host.store = store; host.available = available; host.hasImage = hasImage
        host.canReturnToFolder = canReturnToFolder
        clock = ChromeViewClock()
        session = ViewerSession(preferencesStore: store, clock: clock, host: host)
        items = (0..<3).map { _ in ItemID.ephemeral(UUID()) }
        session.beginBrowsing(items: items, sourceVersion: .init(1), scrollAnchor: nil)
        session.select(items[1])
        switch source {
        case .browsing: break
        case .preview: CommandRouter().route(.preview, from: .key, to: session)
        case .single: session.leaveBrowsing()
        case .files:
            session.leaveBrowsing()
            session.filePreviewSet = FilePreviewSet(files: [URL(fileURLWithPath: "/p/a.png"), URL(fileURLWithPath: "/p/b.png")])
        }
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        overlay = ViewerChromeOverlay(frame: NSRect(origin: .zero, size: size), session: session)
        window.contentView = overlay
        host.overlay = overlay
        session.chromeHost = host
        overlay.menuPresenter = presenter
        overlay.refresh(filename: "a.png", position: "2 / 3")
    }
    func tool(_ id: String) -> ChromeToolView? { overlay.tools.first { $0.accessibilityIdentifier() == id } }
    // A missing tool is a detached placeholder, so its assertions fail instead of crashing the run.
    private func named(_ id: String) -> ChromeToolView { tool(id) ?? ChromeToolView(frame: .zero) }
    var sidebar: ChromeToolView { named("chrome.sidebar.button") }
    var returnTool: ChromeToolView { named("chrome.returnToGrid.button") }
    var more: ChromeToolView { named("chrome.more.button") }
    var zoom: ChromeToolView { named("command.actualPixels.button") }
    func click(_ tool: ChromeToolView) {
        let point = tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            guard let event else { continue }
            type == .leftMouseDown ? tool.mouseDown(with: event) : tool.mouseUp(with: event)
        }
    }
    func space(_ tool: ChromeToolView) {
        _ = window.makeFirstResponder(tool)
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49)
        if let event { tool.keyDown(with: event) }
    }
    func close() { window.close() }
}

private func near(_ a: NSRect, _ b: NSRect, _ tolerance: CGFloat = 1) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor func i444LeadingPodMatchesPage14(appearance: NSAppearance.Name) {
    let scene = Pods444Scene(appearance: appearance)
    defer { scene.close() }
    // Page 14 pins the viewer with its sidebar hidden (`.workspace.sidebar-hidden`, aria-pressed false).
    scene.store.value.gridSidebarVisible = false
    scene.overlay.refresh(filename: "a.png", position: "2 / 3")
    let pod = scene.overlay.groups[0]
    #expect(near(pod.frame, NSRect(x: 16, y: 14, width: 104, height: 38)), "leading pod \(pod.frame)")
    let tools = scene.overlay.tools.filter { $0.superview === pod }.sorted { $0.frame.minX < $1.frame.minX }
    #expect(tools.map { $0.accessibilityIdentifier() }
        == ["chrome.sidebar.button", "chrome.returnToGrid.button", "chrome.more.button"])
    #expect(tools.map { $0.accessibilityLabel() ?? "" } == ["Show sidebar", "Return to grid", "More browse actions"])
    #expect(tools.map(\.symbolName) == ["sidebar.left", "square.grid.2x2", "ellipsis"])
    for (tool, x) in zip(tools, [5.0, 37, 69]) {
        #expect(near(tool.frame, NSRect(x: x, y: 5, width: 30, height: 28)), "\(tool.accessibilityIdentifier()) \(tool.frame)")
    }
    #expect(scene.overlay.tools.count == 8)
    let ids = scene.overlay.tools.map { $0.accessibilityIdentifier() }
    #expect(!ids.contains("command.open.button") && !ids.contains("command.inspector.button"))
}

@Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor func i444ZoomPodAndChevronMatchPage14(appearance: NSAppearance.Name) throws {
    let design = try PinnedDesign.page("viewer-controls", appearance: appearance == .darkAqua ? "dark" : "light")
    #expect(try design.length(".zoom-pod .zoom-label", "min-width", viewport: 1280) == 100)
    let scene = Pods444Scene(appearance: appearance)
    defer { scene.close() }
    let pod = scene.overlay.groups[2]
    #expect(near(pod.frame, NSRect(x: 1090, y: 14, width: 174, height: 38)), "zoom pod \(pod.frame)")
    let tools = scene.overlay.tools.filter { $0.superview === pod }.sorted { $0.frame.minX < $1.frame.minX }
    #expect(tools.map { $0.accessibilityIdentifier() }
        == ["command.zoomOut.button", "command.actualPixels.button", "command.zoomIn.button"])
    try #require(tools.count == 3)
    #expect(near(tools[0].frame, NSRect(x: 5, y: 5, width: 30, height: 28)))
    #expect(near(tools[1].frame, NSRect(x: 37, y: 6, width: 100, height: 26)), "zoom mode \(tools[1].frame)")
    #expect(near(tools[2].frame, NSRect(x: 139, y: 5, width: 30, height: 28)))
    let chevron = tools[1].convert(tools[1].chevronFrame, to: pod)
    #expect(abs(chevron.width - 9) <= 1 && abs(chevron.height - 6) <= 1, "chevron size \(chevron)")
    #expect(abs(chevron.midX - 131) <= 1 && abs(chevron.midY - 19) <= 1, "chevron centre \(chevron)")
    // The chevron is drawn, not only measured: some pixel inside it is opaque on the clear tool bitmap.
    let zoom = tools[1]
    zoom.layoutSubtreeIfNeeded()
    let rep = try #require(zoom.bitmapImageRepForCachingDisplay(in: zoom.bounds))
    zoom.cacheDisplay(in: zoom.bounds, to: rep)
    let scale = CGFloat(rep.pixelsWide) / zoom.bounds.width
    var inked = false
    let box = zoom.chevronFrame
    for x in Int(box.minX * scale)..<max(Int(box.minX * scale) + 1, Int(box.maxX * scale)) {
        for y in Int(box.minY * scale)..<max(Int(box.minY * scale) + 1, Int(box.maxY * scale)) {
            let row = rep.pixelsHigh - 1 - y
            if let color = rep.colorAt(x: x, y: row), color.alphaComponent > 0.3 { inked = true }
        }
    }
    #expect(inked, "chevron pixels in \(appearance.rawValue)")
}

@Test(arguments: [Pods444Source.browsing, .preview, .single, .files], [false, true])
@MainActor func i444ReturnToGridToolEnabledIffCanReturnAndPressReturns(source: Pods444Source, folder: Bool) {
    for activation in 0..<3 {
        let scene = Pods444Scene(source, canReturnToFolder: folder)
        defer { scene.close() }
        let tool = scene.returnTool
        let enabled = scene.session.canReturnToSource
        #expect(enabled == (source == .preview || (source == .single && folder)), "\(source) \(folder)")
        #expect(tool.isEnabled == enabled && tool.acceptsFirstResponder == enabled && tool.isAccessibilityEnabled() == enabled)
        let before = scene.session.mode
        switch activation {
        case 0: scene.click(tool)
        case 1: _ = tool.accessibilityPerformPress()
        default: scene.space(tool)
        }
        if enabled {
            if source == .preview {
                #expect(scene.session.mode == .browsing && scene.session.previewSet == nil, "activation \(activation)")
                #expect(scene.host.returns == 1, "activation \(activation)")
            } else {
                #expect(scene.host.folderReturns == 1, "activation \(activation)")
            }
        } else {
            #expect(scene.session.mode == before && scene.host.returns == 0 && scene.host.folderReturns == 0)
        }
    }
}

@Test(arguments: [false, true], [false, true])
@MainActor func i444SidebarToolFollowsSessionState(canToggle: Bool, visible: Bool) {
    let scene = Pods444Scene(.preview, available: canToggle)
    defer { scene.close() }
    scene.store.value.gridSidebarVisible = visible
    scene.overlay.refresh(filename: "a.png")
    let tool = scene.sidebar
    func check(_ label: String) {
        let shown = scene.session.isViewerSidebarShown
        #expect(tool.isEnabled == canToggle, "\(label)")
        #expect(tool.accessibilityLabel() == (shown ? "Hide sidebar" : "Show sidebar"), "\(label)")
        #expect((tool.accessibilityValue() as? NSNumber)?.boolValue == shown, "\(label)")
    }
    check("before")
    let wasShown = scene.session.isViewerSidebarShown
    scene.click(tool)
    check("after press")
    if canToggle { #expect(scene.session.isViewerSidebarShown == !wasShown) }
    else { #expect(scene.host.intents.isEmpty && scene.store.value.gridSidebarVisible == visible) }
}

@Test @MainActor func i444PodTooltipsMatchPage14() {
    let scene = Pods444Scene()
    defer { scene.close() }
    scene.store.value.gridSidebarVisible = false
    scene.overlay.refresh(filename: "a.png")
    scene.overlay.pointerMoved(NSPoint(x: 30, y: 30))
    #expect(scene.sidebar.toolTip == "Show sidebar (⌃⌘S)")
    #expect(scene.returnTool.toolTip == "Return to grid (Esc)")
    #expect(scene.more.toolTip == "More browse actions")
    #expect(scene.zoom.toolTip == "Zoom mode")
    #expect(scene.overlay.tools.allSatisfy { $0.toolTip != "Fit window (0)" })
    scene.click(scene.sidebar)
    scene.overlay.pointerMoved(NSPoint(x: 30, y: 30))
    #expect(scene.sidebar.toolTip == "Hide sidebar (⌃⌘S)")
    scene.click(scene.sidebar)
    scene.overlay.pointerMoved(NSPoint(x: 30, y: 30))
    #expect(scene.sidebar.toolTip == "Show sidebar (⌃⌘S)")
}

@Test @MainActor func i444ZoomModeLabelFollowsZoomMode() {
    let scene = Pods444Scene()
    defer { scene.close() }
    func label() -> String? { scene.zoom.accessibilityValue() as? String }
    scene.session.beginCanvasImage(); scene.overlay.refresh(filename: "a.png")
    #expect(label() == "Fit window")
    CommandRouter().route(.actualPixels, from: .key, to: scene.session); scene.overlay.refresh(filename: "a.png")
    #expect(label() == "1:1 · 100%")
    var generator = SystemRandomNumberGenerator()
    let values = [0.05, 0.333, 0.999, 1.0, 1.5, 4.0, 32.0] + (0..<40).map { _ in Double.random(in: 0.01...32, using: &generator) }
    for value in values {
        scene.session.reportCanvasZoom(value); scene.overlay.refresh(filename: "a.png")
        #expect(label() == ScaleIndicator(actualPixels: false, customZoom: value) {}.label, "custom \(value)")
    }
    #expect(label() != "1:1 · 100%")
    scene.session.reportCanvasZoom(1.0); scene.overlay.refresh(filename: "a.png")
    #expect(label() == "100%")
    #expect(scene.zoom.accessibilityRole() == .button)
    #expect(!(scene.zoom.accessibilityHelp() ?? "").isEmpty)
}

@Test @MainActor func i444ZoomMenuRoutesAndRoundTripsFitActualFit() {
    let scene = Pods444Scene()
    defer { scene.close() }
    scene.session.beginCanvasImage(); scene.overlay.refresh(filename: "a.png")
    let initialLabel = scene.zoom.accessibilityValue() as? String
    func open(choose: Int?) -> NSMenu {
        scene.presenter.choose = choose
        scene.zoom.activate()
        scene.overlay.refresh(filename: "a.png")
        return scene.presenter.presented.last?.menu ?? NSMenu()
    }
    let first = open(choose: 1)
    #expect(first.items.map(\.title) == ["Fit window", "1:1 · 100%"])
    #expect(scene.presenter.presented.last?.anchor === scene.zoom)
    #expect(scene.session.zoomMode == .actualPixels && scene.host.zooms.last == .actualPixels)
    #expect(scene.zoom.accessibilityValue() as? String == "1:1 · 100%")
    let second = open(choose: 0)
    #expect(second.items.map(\.state) == [.off, .on], "checkmark on 1:1 while it was current")
    #expect(scene.session.zoomMode == .fit && scene.host.zooms.last == .fit)
    #expect(scene.zoom.accessibilityValue() as? String == initialLabel)
    let third = open(choose: nil)
    #expect(third.items.map(\.state) == [.on, .off])
    scene.session.reportCanvasZoom(2.0)
    #expect(open(choose: nil).items.map(\.state) == [.off, .off])
    // Each item sets its own mode, whatever the starting mode (no toggling).
    let starts: [(String, () -> Void)] = [
        ("custom", { scene.session.reportCanvasZoom(2.0) }),
        ("actual", { CommandRouter().route(.actualPixels, from: .key, to: scene.session) }),
        ("fit", { CommandRouter().route(.fit, from: .key, to: scene.session) })]
    for (name, start) in starts {
        for index in [0, 1] {
            start()
            _ = open(choose: index)
            let expected: ViewerZoomMode = index == 0 ? .fit : .actualPixels
            #expect(scene.session.zoomMode == expected, "\(name) → item \(index)")
            #expect(scene.host.zooms.last == (index == 0 ? .fit : .actualPixels), "\(name) → item \(index)")
        }
    }
}

@Test(arguments: [true, false])
@MainActor func i444ZoomToolOpensMenuByClickSpaceAndAXPressOnlyWhenImageAvailable(hasImage: Bool) {
    for activation in 0..<3 {
        let scene = Pods444Scene(hasImage: hasImage)
        defer { scene.close() }
        let mode = scene.session.zoomMode
        switch activation {
        case 0: scene.click(scene.zoom)
        case 1: scene.space(scene.zoom)
        default: _ = scene.zoom.accessibilityPerformPress()
        }
        if hasImage {
            #expect(scene.presenter.presented.count == 1, "activation \(activation)")
            #expect(scene.presenter.presented.first?.anchor === scene.zoom)
            #expect(scene.presenter.presented.first?.menu.items.count == 2)
        } else {
            #expect(scene.presenter.presented.isEmpty, "activation \(activation)")
            #expect(!scene.zoom.isAccessibilityEnabled() && !scene.zoom.acceptsFirstResponder)
            #expect(scene.session.zoomMode == mode)
        }
    }
}

@Test(arguments: ["zoom", "more"])
@MainActor func i444MenuLockHeldOnlyWhileEitherMenuPresents(menu: String) {
    let scene = Pods444Scene()
    defer { scene.close() }
    scene.overlay.moreMenuProvider = { let m = NSMenu(); m.addItem(withTitle: "x", action: nil, keyEquivalent: ""); return m }
    let before = scene.session.chrome.locks
    for cycle in 0..<3 {
        var inside = false
        scene.presenter.inside = { _ in
            inside = true
            scene.clock.now += 10
            scene.session.advanceChrome()
            #expect(scene.session.isMenuTracking, "cycle \(cycle)")
            #expect(scene.session.chrome.locks.contains(.menu), "cycle \(cycle)")
            #expect(!scene.session.chrome.isHidden, "cycle \(cycle)")
        }
        (menu == "zoom" ? scene.zoom : scene.more).activate()
        #expect(inside, "cycle \(cycle) presented")
        #expect(!scene.session.isMenuTracking && !scene.session.chrome.locks.contains(.menu), "cycle \(cycle)")
    }
    #expect(scene.session.chrome.locks == before)
}

@Test @MainActor func i444MoreToolPresentsProviderMenuOrDoesNothing() {
    let scene = Pods444Scene()
    defer { scene.close() }
    let menu = NSMenu()
    scene.overlay.moreMenuProvider = { menu }
    scene.click(scene.more)
    #expect(scene.presenter.presented.count == 1)
    #expect(scene.presenter.presented.first?.menu === menu && scene.presenter.presented.first?.anchor === scene.more)
    scene.overlay.moreMenuProvider = nil
    let locks = scene.session.chrome.locks
    scene.more.activate()
    #expect(scene.presenter.presented.count == 1)
    #expect(scene.session.chrome.locks == locks)
    #expect(scene.more.isEnabled)
}

@Test(arguments: [false, true], [false, true])
@MainActor func i444PodsNeverOverlapAcrossContentWidths(notice: Bool, longName: Bool) {
    let scene = Pods444Scene()
    defer { scene.close() }
    scene.overlay.setMetadataSortState(notice ? .pending : .idle)
    scene.overlay.refresh(filename: longName ? String(repeating: "n", count: 400) + ".png" : "a.png", position: "2 / 3")
    for width in 238...1600 {
        scene.overlay.frame = NSRect(x: 0, y: 0, width: CGFloat(width), height: 800)
        let groups = scene.overlay.groups.map(\.frame)
        for i in groups.indices { for j in groups.indices where i < j {
            let overlap = groups[i].intersection(groups[j])
            #expect(overlap.isNull || overlap.width * overlap.height == 0, "width \(width): \(i)/\(j)")
        } }
        #expect(groups[2].minX == CGFloat(width) - 190, "width \(width)")
        #expect(groups[0].width == 104 && groups[2].width == 174, "width \(width)")
        #expect(groups.allSatisfy { $0.minX >= 0 }, "width \(width)")
    }
}

@Test @MainActor func i444RowBreakThresholdsUseNewPodWidths() {
    let scene = Pods444Scene()
    defer { scene.close() }
    func layout(_ width: CGFloat) { scene.overlay.frame = NSRect(x: 0, y: 0, width: width, height: 800) }
    layout(318)
    #expect(scene.overlay.groups[0].frame.minY == 14)
    layout(317)
    #expect(scene.overlay.groups[0].frame.minY == 106)
    layout(1280)
    let navigation = scene.overlay.groups[1].frame.width
    let threshold = navigation + 326
    layout(threshold)
    #expect(scene.overlay.groups.map(\.frame.minY) == [14, 14, 14])
    layout(threshold - 1)
    #expect(scene.overlay.groups[1].frame.minY == 60)
}

@Test @MainActor func i444TabOrderIsEnabledToolsInVisualOrder() {
    let rows: [(Pods444Source, Bool, Bool, Bool)] = [  // source, sidebar available, folder, image
        (.preview, true, false, true), (.preview, false, false, true), (.preview, true, false, false),
        (.single, false, true, true), (.single, false, false, true), (.browsing, false, false, false)]
    for (source, available, folder, image) in rows {
        let scene = Pods444Scene(source, available: available, hasImage: image, canReturnToFolder: folder)
        defer { scene.close() }
        // Rows are the pods' rows (the 26 pt 缩放模式 control sits 1 pt higher than its 28 pt neighbours).
        let expected = scene.overlay.tools.filter(\.acceptsFirstResponder).sorted {
            let a = $0.convert($0.bounds, to: nil), b = $1.convert($1.bounds, to: nil)
            let rowA = $0.superview?.frame.minY ?? a.minY, rowB = $1.superview?.frame.minY ?? b.minY
            return rowA != rowB ? rowA > rowB : a.minX < b.minX
        }
        var forward: [NSView] = []
        var moved = scene.overlay.focusTool(reverse: false, entering: true)
        while moved, let responder = scene.window.firstResponder as? NSView {
            forward.append(responder)
            moved = scene.overlay.focusTool(reverse: false, entering: false)
        }
        #expect(forward.map(ObjectIdentifier.init) == expected.map(ObjectIdentifier.init), "\(source) \(available) \(image)")
        var backward: [NSView] = []
        moved = scene.overlay.focusTool(reverse: true, entering: true)
        while moved, let responder = scene.window.firstResponder as? NSView {
            backward.append(responder)
            moved = scene.overlay.focusTool(reverse: true, entering: false)
        }
        #expect(backward.map(ObjectIdentifier.init) == expected.reversed().map(ObjectIdentifier.init))
        if source == .preview, !available, image { #expect(expected.first === scene.returnTool) }
    }
}

@Test @MainActor func i444ToolEnablementTracksSessionTransitionsOnOneOverlay() {
    let scene = Pods444Scene(.browsing, available: false)
    defer { scene.close() }
    func check(_ step: String) {
        scene.overlay.refresh(filename: "a.png")
        for (tool, expected) in [(scene.sidebar, scene.session.canToggleViewerSidebar),
                                 (scene.returnTool, scene.session.canReturnToSource)] {
            #expect(tool.isEnabled == expected && tool.acceptsFirstResponder == expected
                    && tool.isAccessibilityEnabled() == expected, "\(step) \(tool.accessibilityIdentifier())")
        }
        #expect(scene.zoom.isEnabled == scene.session.isEnabled(.actualPixels), "\(step) zoom")
    }
    check("browsing")
    CommandRouter().route(.preview, from: .key, to: scene.session)
    check("preview unavailable")
    scene.host.available = true
    check("preview available")
    #expect(scene.sidebar.isEnabled && scene.returnTool.isEnabled)
    scene.session.perform(intent: .returnToGrid)
    check("returned")
    scene.session.leaveBrowsing()
    check("single")
    scene.host.canReturnToFolder = true
    check("single with folder")
    #expect(scene.returnTool.isEnabled)
    scene.session.filePreviewSet = FilePreviewSet(files: [URL(fileURLWithPath: "/p/a.png"), URL(fileURLWithPath: "/p/b.png")])
    check("file set")
    #expect(!scene.returnTool.isEnabled && !scene.sidebar.isEnabled)
}

/// The live face's own action (the SwiftUI component's tap) runs the tool's activation, like a click on the view.
@Test @MainActor func i444FaceActionActivatesItsTool() throws {
    let scene = Pods444Scene(.preview)
    defer { scene.close() }
    let face = try #require(scene.returnTool.subviews.first as? NSHostingView<ChromeToolFace>)
    #expect(scene.session.mode == .viewing && scene.session.previewSet != nil)
    face.rootView.action()
    #expect(scene.session.mode == .browsing && scene.session.previewSet == nil, "返回网格's face returns to the grid")
    #expect(scene.session.selection.currentItemID == scene.items[1], "the grid selection is the origin's")
}

/// Without a presenter (the App installs NSMenu's pop-up) the pod menus stay closed: nothing tracks, no menu lock.
@Test @MainActor func i444NoPresenterLeavesPodMenusClosed() {
    let scene = Pods444Scene(hasImage: true)
    defer { scene.close() }
    scene.overlay.menuPresenter = nil
    var built = 0
    scene.overlay.moreMenuProvider = { built += 1; return NSMenu() }
    let mode = scene.session.zoomMode
    scene.zoom.activate()
    scene.more.activate()
    #expect(built == 1, "更多 still builds its menu")
    #expect(scene.session.zoomMode == mode)
    #expect(!scene.session.isMenuTracking && !scene.session.chrome.locks.contains(.menu))
}
