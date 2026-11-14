import AppKit
import Testing
import MadoApplication

@Test(.timeLimit(.minutes(3))) func issue683FilterPlanPreservesExclusionsForAllTargets() throws {
    let displayFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let targets: [CaptureRequest.Target] = [
        .fullScreen(displayID: 7),
        .region(rect: CGRect(x: 2, y: 2, width: 30, height: 30), displayID: 7, displayFrame: displayFrame, scale: 2),
        .window(windowID: 88)
    ]
    for target in targets {
        let request = CaptureRequest(target: target, barWindowIDs: [21, 22], overlayWindowIDs: [23])
        let plan = try CaptureFilterPlan.resolve(request, availableWindowIDs: [21, 22, 23, 88])
        #expect(plan.excludedIDs == [21, 22, 23])
        switch (target, plan.target) {
        case (.fullScreen(7), .display(7)), (.region(_, 7, _, _), .display(7)), (.window(88), .window(88)): break
        default: Issue.record("capture filter target changed")
        }
    }
}

// Round 2 (opus F2): only a missing bar window fails; a gone overlay is skipped.
@Test(.timeLimit(.minutes(3))) func issue683FilterPlanRefusesMissingExcludedWindow() {
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [21], overlayWindowIDs: [23])
    #expect(throws: CaptureFilterPlan.Failure.missingExcludedWindow) {
        try CaptureFilterPlan.resolve(request, availableWindowIDs: [23])
    }
}

@Test(.timeLimit(.minutes(3))) func issue683FilterPlanReturnsActualExcludedWindowObjects() throws {
    struct Window: Equatable { let id: UInt32; let title: String }
    let windows = [Window(id: 21, title: "bar"), Window(id: 22, title: "overlay"),
                   Window(id: 90, title: "target")]
    let request = CaptureRequest(target: .window(windowID: 90), barWindowIDs: [21], overlayWindowIDs: [22])
    let resolved = try CaptureFilterPlan.resolveWindows(request, windows: windows, id: { $0.id })
    #expect(resolved.excludedWindows == Array(windows.prefix(2)))
    #expect(resolved.targetWindow == windows[2])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683RequestUsesActualBarAndOverlayWindowNumbers() throws {
    let bar = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless,
                      backing: .buffered, defer: false)
    let overlay = NSPanel(contentRect: CGRect(x: 50, y: 0, width: 40, height: 40), styleMask: .borderless,
                          backing: .buffered, defer: false)
    bar.orderFront(nil); overlay.orderFront(nil)
    defer { bar.orderOut(nil); overlay.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let overlayID = try #require(UInt32(exactly: overlay.windowNumber))
    let request = CaptureRequestFromWindows.make(target: .fullScreen(displayID: 7), bars: [bar], overlays: [overlay])
    #expect(request.excludedWindowIDs == [barID, overlayID])
}

@MainActor @Test(.timeLimit(.minutes(3))) func issue683WindowSelectionAdmissionRejectsSecondPressDuringLoad() {
    let admission = CaptureSelectionAdmission()
    #expect(admission.begin())
    #expect(!admission.begin())
    admission.end()
    #expect(admission.begin())
}
