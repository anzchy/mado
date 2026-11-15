import AppKit
import Testing
import MadoApplication

// #684 P7-10 CAP-02 fix round 1.
// F1 (gpt F1 + opus M2): the thumbnail goes on the display that was captured, fixed before the Capture.

@MainActor private final class Pointer {
    var location: NSPoint
    init(_ location: NSPoint) { self.location = location }
}

/// Records each request and moves the pointer while the Capture is running.
private actor MovingScreen: CaptureScreenPort {
    private(set) var requests: [CaptureRequest.Target?] = []
    let pointer: Pointer
    let movesTo: NSPoint
    init(pointer: Pointer, movesTo: NSPoint) {
        self.pointer = pointer
        self.movesTo = movesTo
    }

    func captureCurrentDisplayPNG() async throws -> Data {
        requests.append(nil)
        await move()
        return Data([1])
    }

    func capturePNG(request: CaptureRequest) async throws -> Data {
        requests.append(request.target)
        await move()
        return Data([1])
    }

    private func move() async {
        let pointer = pointer, to = movesTo
        await MainActor.run { pointer.location = to }
    }
}

private actor NoFiles: CaptureFilePort {
    func writeNewPNG(_ data: Data, named: String) throws -> URL { URL(fileURLWithPath: "/tmp/issue684/\(named)") }
}

private actor NoClipboard: CaptureClipboardPort {
    func writePNG(_ png: Data) -> Bool { true }
}

/// Main display 1 (menu bar 25 pt) and display 7 to its right, lower, with its own 25 pt menu bar.
private let mainFrame = NSRect(x: 0, y: 0, width: 1440, height: 900)
private let mainVisible = NSRect(x: 0, y: 0, width: 1440, height: 875)
private let secondFrame = NSRect(x: 1440, y: -200, width: 1920, height: 1080)
private let secondVisible = NSRect(x: 1440, y: -200, width: 1920, height: 1055)
private let screens: [CaptureThumbnailPlacement.Screen] = [(id: 1, frame: mainFrame, visible: mainVisible),
                                                            (id: 7, frame: secondFrame, visible: secondVisible)]

private func targetDisplay(_ target: CaptureRequest.Target?) -> UInt32? {
    switch target {
    case let .fullScreen(id)?: id
    case let .region(_, id, _, _)?: id
    case .window?, nil: nil
    }
}

@MainActor private func runFlow(request: CaptureRequest?, selectedDisplay: UInt32?, startsAt: NSPoint,
                                movesTo: NSPoint) async throws -> (frame: NSRect, captured: [CaptureRequest.Target?]) {
    let pointer = Pointer(startsAt)
    let screen = MovingScreen(pointer: pointer, movesTo: movesTo)
    let session = CaptureSession(screen: screen, files: NoFiles())
    let result = try await CaptureThumbnailFlow.capture(
        request: request, selectedDisplay: selectedDisplay, session: session,
        policy: CaptureOutputPolicy(savesToFolder: false, copiesToClipboard: false), clipboard: NoClipboard(),
        pointer: { pointer.location }, screens: { screens },
        fullScreenRequest: { CaptureRequest(target: .fullScreen(displayID: $0), barWindowIDs: [], overlayWindowIDs: []) })
    return (result.visibleFrame, await screen.requests)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684FixThumbnailStaysOnCapturedDisplayWhenPointerMoves() async throws {
    let onSecond = NSPoint(x: 2000, y: 300), onMain = NSPoint(x: 100, y: 100)
    // Bar full screen (no request): the display under the pointer when the Capture starts.
    let full = try await runFlow(request: nil, selectedDisplay: nil, startsAt: onSecond, movesTo: onMain)
    #expect(full.frame == secondVisible)
    #expect(full.captured.count == 1)
    #expect(targetDisplay(full.captured.first ?? nil) == 7, "captured \(full.captured)")
    let fullBack = try await runFlow(request: nil, selectedDisplay: nil, startsAt: onMain, movesTo: onSecond)
    #expect(fullBack.frame == mainVisible)
    #expect(targetDisplay(fullBack.captured.first ?? nil) == 1)
    // Window: the display whose selection overlay was clicked.
    let window = CaptureRequest(target: .window(windowID: 99), barWindowIDs: [], overlayWindowIDs: [])
    let picked = try await runFlow(request: window, selectedDisplay: 7, startsAt: onSecond, movesTo: onMain)
    #expect(picked.frame == secondVisible)
    // Region and explicit full screen: their own display.
    let region = CaptureRequest(target: .region(rect: .zero, displayID: 7, displayFrame: secondFrame, scale: 2),
                                barWindowIDs: [], overlayWindowIDs: [])
    #expect(try await runFlow(request: region, selectedDisplay: 7, startsAt: onSecond, movesTo: onMain).frame
            == secondVisible)
    let explicit = CaptureRequest(target: .fullScreen(displayID: 1), barWindowIDs: [], overlayWindowIDs: [])
    #expect(try await runFlow(request: explicit, selectedDisplay: nil, startsAt: onSecond, movesTo: onSecond).frame
            == mainVisible)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684FixPointerInMenuBarStripPicksThatDisplay() async throws {
    // Inside display 7's frame, above its visible frame (its menu bar): the capture and the thumbnail both use 7.
    let menuBar = NSPoint(x: 2000, y: secondFrame.maxY - 10)
    #expect(secondFrame.contains(menuBar) && !secondVisible.contains(menuBar))
    let result = try await runFlow(request: nil, selectedDisplay: nil, startsAt: menuBar, movesTo: menuBar)
    #expect(result.frame == secondVisible)
    #expect(targetDisplay(result.captured.first ?? nil) == 7, "captured \(result.captured)")
    // Display 7's Dock strip at the bottom edge of its frame.
    let dock = NSPoint(x: 3000, y: secondFrame.minY + 1)
    let docked = try await runFlow(request: nil, selectedDisplay: nil, startsAt: dock, movesTo: dock)
    #expect(docked.frame == secondVisible)
    // A window Capture whose overlay was on display 7, pointer in 7's menu bar.
    let window = CaptureRequest(target: .window(windowID: 99), barWindowIDs: [], overlayWindowIDs: [])
    #expect(try await runFlow(request: window, selectedDisplay: 7, startsAt: menuBar, movesTo: menuBar).frame
            == secondVisible)
}
