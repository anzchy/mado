import AppKit
import MadoApplication
import Testing

@MainActor @Test(.timeLimit(.minutes(2)))
func issue686QueuedCaptureSkipsThumbnailClosedBeforeEnumeration() throws {
    let bar = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 200, height: 40),
                      styleMask: .borderless, backing: .buffered, defer: false)
    let thumbnail = NSPanel(contentRect: CGRect(x: 0, y: 50, width: 200, height: 120),
                            styleMask: .borderless, backing: .buffered, defer: false)
    bar.orderFront(nil)
    thumbnail.orderFront(nil)
    defer { bar.orderOut(nil); thumbnail.orderOut(nil) }
    let barID = try #require(UInt32(exactly: bar.windowNumber))
    let thumbnailID = try #require(UInt32(exactly: thumbnail.windowNumber))

    // A queued read resolves both windows while visible. Open in Mado can close the
    // thumbnail before ScreenCaptureKit returns its window list.
    let request = CaptureRequestFromWindows.make(
        target: .region(rect: CGRect(x: 0, y: 0, width: 100, height: 100), displayID: 7,
                        displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2),
        bars: [bar], thumbnails: [thumbnail], overlays: [])
    #expect(request.excludedWindowIDs == [barID, thumbnailID])

    struct Window: Equatable { let id: UInt32 }
    let resolved = try CaptureFilterPlan.resolveWindows(request, windows: [Window(id: barID)], id: { $0.id })
    #expect(resolved.excludedWindows == [Window(id: barID)])
    #expect(resolved.plan.excludedIDs == [barID])

    #expect(throws: CaptureFilterPlan.Failure.missingExcludedWindow) {
        try CaptureFilterPlan.resolve(request, availableWindowIDs: [thumbnailID])
    }
}
