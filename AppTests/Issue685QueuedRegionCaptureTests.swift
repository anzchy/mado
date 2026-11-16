import AppKit
import Testing
import MadoApplication

// #685 fix r6 (opus-auditor r5confirm M1): a region Capture whose selection ends while another Capture reads waits its
// turn. Its exclusion list must be made when its read runs, so the earlier Capture's thumbnail, presented while it
// waited, is not in the region image.

private actor RecordingScreen: CaptureScreenPort {
    private(set) var requests: [CaptureRequest] = []
    func captureCurrentDisplayPNG() async throws -> Data { Data([1]) }
    func capturePNG(request: CaptureRequest) async throws -> Data {
        requests.append(request)
        return Data([1])
    }
}

private actor NoFiles: CaptureFilePort {
    func writeNewPNG(_ data: Data, named: String) throws -> URL { URL(fileURLWithPath: "/tmp/issue685/\(named)") }
}

private actor NoClipboard: CaptureClipboardPort {
    func writePNG(_ png: Data) -> Bool { true }
}

private actor NoTrash: CaptureTrashPort {
    func moveToTrash(_ url: URL) throws {}
}

private let display = NSRect(x: 0, y: 0, width: 1440, height: 900)
private let screens: [CaptureThumbnailPlacement.Screen] = [(id: 1, frame: display, visible: display)]

/// Lets other main-actor tasks run until `done` holds, at most a bounded number of turns.
@MainActor private func turns(until done: () -> Bool) async {
    var left = 1_000
    while left > 0, !done() {
        left -= 1
        await Task.yield()
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue685AQueuedRegionCaptureLeavesOutTheThumbnailPresentedWhileItWaited()
    async throws {
    let barWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let bar = CaptureBarCollapseController(bar: barWindow, localize: { $0 }, iconNeverLeft: {})
    let thumbnails = CaptureThumbnailPresenter()
    let screen = RecordingScreen()
    let session = CaptureSession(screen: screen, files: NoFiles())
    let policy = CaptureOutputPolicy(savesToFolder: false, copiesToClipboard: false)
    let clipboard = NoClipboard()
    var release: CheckedContinuation<Void, Never>?
    var presented: NSWindow?

    // Capture A (full screen) holds its read, then presents its thumbnail the way the helper does.
    let first = Task { @MainActor in
        let (state, frame) = try await bar.whileCapturing {
            await withCheckedContinuation { release = $0 }
            return try await CaptureThumbnailFlow.capture(
                request: nil, selectedDisplay: nil, session: session, policy: policy, clipboard: clipboard,
                pointer: { NSPoint(x: 100, y: 100) }, screens: { screens },
                fullScreenRequest: { CaptureRequest(target: .fullScreen(displayID: $0), barWindowIDs: [],
                                                    overlayWindowIDs: []) })
        }
        let model = CaptureThumbnailModel(state: state, session: session, clipboard: clipboard, trash: NoTrash())
        let controller = CaptureThumbnailController(model: model, visibleFrame: frame, startsTimer: false,
                                                    decodeImage: { _ in nil })
        thumbnails.present(controller)
        presented = controller.panel
    }
    await turns(until: { release != nil })

    // Capture B: a region selection over the thumbnail's corner finishes while A reads; it queues behind A.
    let region = CaptureHelperWindows.resolver(
        target: .region(rect: display, displayID: 1, displayFrame: display, scale: 2), bar: nil, status: nil,
        thumbnails: thumbnails, overlays: [])
    let second = Task { @MainActor in
        try await bar.whileCapturing {
            try await CaptureThumbnailFlow.capture(
                request: region, selectedDisplay: 1, session: session, policy: policy, clipboard: clipboard,
                pointer: { NSPoint(x: 100, y: 100) }, screens: { screens },
                fullScreenRequest: { _ in Issue.record("B is a region Capture"); return region() })
        }
    }
    await turns(until: { false })  // B reaches the queue
    release?.resume()
    try await first.value
    _ = try await second.value
    defer { thumbnails.dismiss() }

    let thumbnail = try #require(presented)
    let thumbnailID = try #require(UInt32(exactly: thumbnail.windowNumber))
    #expect(thumbnailID > 0)
    let requests = await screen.requests
    #expect(requests.count == 2)
    let regionRead = try #require(requests.last)
    #expect(regionRead.barWindowIDs.union(regionRead.overlayWindowIDs).contains(thumbnailID),
            "B's read excludes \(regionRead.barWindowIDs) \(regionRead.overlayWindowIDs), not A's thumbnail \(thumbnailID)")
}
