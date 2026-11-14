import AppKit
import ScreenCaptureKit
import Testing
import MadoApplication

// #683 fix round 2: overlays that are already gone need no exclusion, the bar still does (opus F2);
// the display filter is built from exactly the resolved windows (gpt F1); selection finishes once (opus M1).

@MainActor private func round2Panel(_ frame: CGRect, show: Bool) -> NSPanel {
    let panel = NSPanel(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    if show { panel.orderFront(nil) }
    return panel
}

@Test(.timeLimit(.minutes(3))) func issue683Round2GoneOverlaysAreSkippedForEveryTarget() throws {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let targets: [CaptureRequest.Target] = [
        .fullScreen(displayID: 7),
        .region(rect: CGRect(x: 2, y: 2, width: 30, height: 30), displayID: 7, displayFrame: frame, scale: 2),
        .window(windowID: 88)
    ]
    for target in targets {
        let request = CaptureRequest(target: target, barWindowIDs: [21], overlayWindowIDs: [23, 24])
        let plan = try CaptureFilterPlan.resolve(request, availableWindowIDs: [21, 88])
        #expect(plan.excludedIDs == [21])
        switch (target, plan.target) {
        case (.fullScreen(7), .display(7)), (.region(_, 7, _, _), .display(7)), (.window(88), .window(88)): break
        default: Issue.record("capture filter target changed")
        }
    }
}

@Test(.timeLimit(.minutes(3))) func issue683Round2ListedOverlayIsStillExcluded() throws {
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [21], overlayWindowIDs: [23, 24])
    let plan = try CaptureFilterPlan.resolve(request, availableWindowIDs: [21, 23, 50])
    #expect(plan.excludedIDs == [21, 23])
}

@Test(.timeLimit(.minutes(3))) func issue683Round2MissingBarStillFails() {
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [21], overlayWindowIDs: [23])
    #expect(throws: CaptureFilterPlan.Failure.missingExcludedWindow) {
        try CaptureFilterPlan.resolve(request, availableWindowIDs: [23])
    }
    let window = CaptureRequest(target: .window(windowID: 88), barWindowIDs: [21], overlayWindowIDs: [])
    #expect(throws: CaptureFilterPlan.Failure.missingTargetWindow) {
        try CaptureFilterPlan.resolve(window, availableWindowIDs: [21])
    }
}

@Test(.timeLimit(.minutes(3))) func issue683Round2ResolveWindowsDropsGoneOverlaysAndReturnsPlan() throws {
    struct Window: Equatable { let id: UInt32 }
    let windows = [Window(id: 21), Window(id: 90)]
    let request = CaptureRequest(target: .window(windowID: 90), barWindowIDs: [21], overlayWindowIDs: [22])
    let resolved = try CaptureFilterPlan.resolveWindows(request, windows: windows, id: { $0.id })
    #expect(resolved.excludedWindows == [Window(id: 21)])
    #expect(resolved.targetWindow == Window(id: 90))
    guard case .window(90) = resolved.plan.target else { Issue.record("plan target changed"); return }
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2NeverShownBarWindowIsOptional() throws {
    let bar = round2Panel(CGRect(x: 0, y: 0, width: 40, height: 40), show: true)
    let status = round2Panel(CGRect(x: 0, y: 50, width: 40, height: 40), show: false)
    let overlay = round2Panel(CGRect(x: 50, y: 0, width: 40, height: 40), show: true)
    defer { bar.orderOut(nil); overlay.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let statusID = try #require(UInt32(exactly: status.windowNumber))
    let overlayID = try #require(UInt32(exactly: overlay.windowNumber))
    let request = CaptureRequestFromWindows.make(target: .fullScreen(displayID: 7), bars: [bar, status], overlays: [overlay])
    #expect(request.barWindowIDs == [barID])
    #expect(request.overlayWindowIDs == [statusID, overlayID])
    #expect(request.excludedWindowIDs == [barID, statusID, overlayID])
    let plan = try CaptureFilterPlan.resolve(request, availableWindowIDs: [barID])
    #expect(plan.excludedIDs == [barID])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2FullScreenRequestKeepsNeverShownWindowsOptional() throws {
    let bar = round2Panel(CGRect(x: 0, y: 0, width: 40, height: 40), show: true)
    let status = round2Panel(CGRect(x: 0, y: 50, width: 40, height: 40), show: false)
    defer { bar.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let statusID = try #require(UInt32(exactly: status.windowNumber))
    let request = ScreenCaptureKitScreen.fullScreenRequest(displayID: 7, windows: [bar, status])
    #expect(request.barWindowIDs == [barID])
    #expect(request.overlayWindowIDs == [statusID])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2OverlayReleasedBeforeResolveStillCaptures() throws {
    let bar = round2Panel(CGRect(x: 0, y: 0, width: 40, height: 40), show: true)
    defer { bar.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let request: CaptureRequest = autoreleasepool {
        let overlay = round2Panel(CGRect(x: 50, y: 0, width: 40, height: 40), show: true)
        let request = CaptureRequestFromWindows.make(target: .fullScreen(displayID: 7), bars: [bar], overlays: [overlay])
        overlay.orderOut(nil)
        overlay.close()
        return request
    }
    let listed = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    let available = Set(listed).subtracting(request.overlayWindowIDs)
    let plan = try CaptureFilterPlan.resolve(request, availableWindowIDs: available)
    #expect(plan.excludedIDs == [barID])
}

@Test(.timeLimit(.minutes(3))) func issue683Round2DisplayFilterGetsExactlyResolvedWindows() throws {
    struct Window: Equatable { let id: UInt32 }
    let windows = [Window(id: 21), Window(id: 50), Window(id: 23)]
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [21], overlayWindowIDs: [23, 99])
    var calls: [(String, [Window])] = []
    let filter = try ScreenCaptureKitScreen.displayFilter(display: "display-7", request: request, windows: windows,
                                                          id: { $0.id }) { display, excluded in
        calls.append((display, excluded))
        return "filter"
    }
    #expect(filter == "filter")
    #expect(calls.count == 1)
    #expect(calls.first?.0 == "display-7")
    #expect(calls.first?.1 == [Window(id: 21), Window(id: 23)])
}

@Test(.timeLimit(.minutes(3))) func issue683Round2DisplayFilterRefusesMissingBarWithoutBuilding() {
    struct Window { let id: UInt32 }
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [21], overlayWindowIDs: [])
    var called = false
    #expect(throws: CaptureFilterPlan.Failure.missingExcludedWindow) {
        _ = try ScreenCaptureKitScreen.displayFilter(display: 7, request: request, windows: [Window(id: 50)],
                                                     id: { $0.id }) { _, _ in called = true }
    }
    #expect(!called)
}

private final class FilterRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[UInt32]] = []
    var calls: [[UInt32]] { lock.withLock { recorded } }
    func record(_ ids: [UInt32]) { lock.withLock { recorded.append(ids) } }
}

@MainActor @Test(.timeLimit(.minutes(3)),
                 .enabled(if: CGPreflightScreenCaptureAccess(),
                          "Screen Recording is not granted to the test host, so SCShareableContent has no real SCWindow objects"))
func issue683Round2RealSCWindowsReachTheRealFilterInitializer() async throws {
    let bar = round2Panel(CGRect(x: 0, y: 0, width: 40, height: 40), show: true)
    defer { bar.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    let display = try #require(content.displays.first)
    let request = CaptureRequest(target: .fullScreen(displayID: display.displayID), barWindowIDs: [barID],
                                 overlayWindowIDs: [UInt32.max])
    var recorded: [UInt32] = []
    let filter = try ScreenCaptureKitScreen.displayFilter(display: display, request: request, windows: content.windows,
                                                          id: { $0.windowID }) { display, excluded in
        recorded = excluded.map(\.windowID)
        return SCContentFilter(display: display, excludingWindows: excluded)
    }
    #expect(recorded == [barID])
    #expect(filter.style == .display)
}

@MainActor @Test(.timeLimit(.minutes(3)),
                 .enabled(if: CGPreflightScreenCaptureAccess(),
                          "Screen Recording is not granted to the test host, so capturePNG cannot reach ScreenCaptureKit"))
func issue683Round2CapturePNGBuildsItsFilterThroughTheFactory() async throws {
    let bar = round2Panel(CGRect(x: 0, y: 0, width: 40, height: 40), show: true)
    defer { bar.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let screen = try #require(NSScreen.main)
    let displayID = try #require((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value)
    let recorder = FilterRecorder()
    let capture = ScreenCaptureKitScreen(makeDisplayFilter: { display, excluded in
        recorder.record(excluded.map(\.windowID))
        return SCContentFilter(display: display, excludingWindows: excluded)
    })
    let request = CaptureRequestFromWindows.make(target: .fullScreen(displayID: displayID), bars: [bar], overlays: [])
    _ = try await capture.capturePNG(request: request)
    #expect(recorder.calls.count == 1)
    #expect(recorder.calls.first?.contains(barID) == true)
}

// MARK: one-shot finish (opus M1)

@MainActor private func round2Mouse(_ type: NSEvent.EventType, _ panel: NSWindow, _ point: CGPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                   windowNumber: panel.windowNumber, context: nil, eventNumber: 1,
                                   clickCount: 1, pressure: 1))
}

@MainActor private func round2Escape(_ panel: NSWindow) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
}

private func round2Describe(_ target: CaptureRequest.Target?) -> String {
    switch target {
    case nil: "nil"
    case let .region(rect, _, _, _)?: "region \(Int(rect.width))x\(Int(rect.height))"
    case let .window(id)?: "window \(id)"
    case .fullScreen?: "full"
    }
}

@MainActor private func round2Drag(_ panel: NSWindow) throws {
    panel.sendEvent(try round2Mouse(.leftMouseDown, panel, CGPoint(x: 20, y: 20)))
    panel.sendEvent(try round2Mouse(.leftMouseDragged, panel, CGPoint(x: 50, y: 40)))
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2EscapeMidDragThenMouseUpDoesNotCapture() throws {
    let screen = try #require(NSScreen.main)
    let before = NSPasteboard.general.changeCount
    var results: [String] = []
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .region) { results.append(round2Describe($0)) }
    defer { panel.orderOut(nil) }
    try round2Drag(panel)
    panel.sendEvent(try round2Escape(panel))
    panel.sendEvent(try round2Mouse(.leftMouseUp, panel, CGPoint(x: 50, y: 40)))
    #expect(results == ["nil"])
    #expect(NSPasteboard.general.changeCount == before)
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2RegionFinishesOnlyOnce() throws {
    let screen = try #require(NSScreen.main)
    var results: [String] = []
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .region) { results.append(round2Describe($0)) }
    defer { panel.orderOut(nil) }
    panel.sendEvent(try round2Escape(panel))
    panel.sendEvent(try round2Escape(panel))
    try round2Drag(panel)
    panel.sendEvent(try round2Mouse(.leftMouseUp, panel, CGPoint(x: 50, y: 40)))
    #expect(results == ["nil"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2NormalDragStillCapturesOnce() throws {
    let screen = try #require(NSScreen.main)
    var results: [String] = []
    let panel = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .region) { results.append(round2Describe($0)) }
    defer { panel.orderOut(nil) }
    try round2Drag(panel)
    panel.sendEvent(try round2Mouse(.leftMouseUp, panel, CGPoint(x: 50, y: 40)))
    panel.sendEvent(try round2Escape(panel))
    #expect(results == ["region 30x20"])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683Round2WindowPickFinishesOnlyOnce() throws {
    let screen = try #require(NSScreen.main)
    let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
    let candidates = [ScreenCaptureKitScreen.WindowCandidate(id: 41, frame: CGRect(x: screen.frame.minX + 20,
        y: top - screen.frame.minY - 80, width: 60, height: 60))]
    var picked: [String] = []
    let picker = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window, windows: candidates) {
        picked.append(round2Describe($0))
    }
    defer { picker.orderOut(nil) }
    picker.sendEvent(try round2Mouse(.leftMouseDown, picker, CGPoint(x: 30, y: 30)))
    picker.sendEvent(try round2Escape(picker))
    picker.sendEvent(try round2Mouse(.leftMouseDown, picker, CGPoint(x: 30, y: 30)))
    #expect(picked == ["window 41"])

    var cancelled: [String] = []
    let cancelledPicker = CaptureSelectionPanel(screen: screen, displayID: 1, mode: .window, windows: candidates) {
        cancelled.append(round2Describe($0))
    }
    defer { cancelledPicker.orderOut(nil) }
    cancelledPicker.sendEvent(try round2Escape(cancelledPicker))
    cancelledPicker.sendEvent(try round2Mouse(.leftMouseDown, cancelledPicker, CGPoint(x: 30, y: 30)))
    #expect(cancelled == ["nil"])
}
