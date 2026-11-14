import Foundation
import Testing
import MadoApplication

private actor RecordingScreen: CaptureScreenPort {
    private(set) var seenWindowID: UInt32?
    func captureCurrentDisplayPNG() throws -> Data { Data([1]) }
    func capturePNG(request: CaptureRequest) throws -> Data {
        if case let .window(id) = request.target { seenWindowID = id }
        return Data([2])
    }
}

private actor RecordingFiles: CaptureFilePort {
    private(set) var data: Data?
    func writeNewPNG(_ png: Data, named: String) throws -> URL {
        data = png
        return URL(fileURLWithPath: "/Downloads/\(named)")
    }
}

@Test(.timeLimit(.minutes(2))) func captureSessionRoutesWindowRequestThroughExistingWriter() async throws {
    let screen = RecordingScreen()
    let files = RecordingFiles()
    let session = CaptureSession(screen: screen, files: files)
    let request = CaptureRequest(target: .window(windowID: 42), barWindowIDs: [11], overlayWindowIDs: [12])
    let url = try await session.capture(request: request)
    #expect(await screen.seenWindowID == 42)
    #expect(await files.data == Data([2]))
    #expect(url.lastPathComponent.hasPrefix("mado-"))
}

@Test func captureRequestsExcludeBarAndOverlayForEveryTarget() {
    let targets: [CaptureRequest.Target] = [
        .region(rect: CGRect(x: 10, y: 20, width: 30, height: 40), displayID: 7,
                displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100), scale: 2),
        .window(windowID: 42), .fullScreen(displayID: 7)
    ]
    for target in targets {
        let request = CaptureRequest(target: target, barWindowIDs: [11, 12], overlayWindowIDs: [13])
        #expect(request.excludedWindowIDs == [11, 12, 13])
    }
}

@Test func captureRegionPixelsRoundOutwardAtOneAndTwoX() {
    let frame = CGRect(x: 100, y: 200, width: 300, height: 200)
    let rect = CGRect(x: 110.2, y: 220.4, width: 40.1, height: 30.2)
    let one = CaptureRequest(target: .region(rect: rect, displayID: 7, displayFrame: frame, scale: 1),
                             barWindowIDs: [], overlayWindowIDs: [])
    let two = CaptureRequest(target: .region(rect: rect, displayID: 7, displayFrame: frame, scale: 2),
                             barWindowIDs: [], overlayWindowIDs: [])
    #expect(one.regionPixelRect == CGRect(x: 10, y: 149, width: 41, height: 31))
    #expect(two.regionPixelRect == CGRect(x: 20, y: 298, width: 81, height: 62))
}

@Test func captureRegionPixelsClampAcrossDisplayEdges() {
    let request = CaptureRequest(target: .region(rect: CGRect(x: 90, y: -10, width: 30, height: 40),
                                                 displayID: 7, displayFrame: CGRect(x: 100, y: 0, width: 200, height: 100), scale: 2),
                                 barWindowIDs: [], overlayWindowIDs: [])
    #expect(request.regionPixelRect == CGRect(x: 0, y: 140, width: 40, height: 60))
}

@Test func captureRegionPixelsRejectEmptyAndNonRegionTargets() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let empty = CaptureRequest(target: .region(rect: CGRect(x: 2, y: 2, width: 0, height: 10),
                                                displayID: 7, displayFrame: frame, scale: 1),
                               barWindowIDs: [], overlayWindowIDs: [])
    let outside = CaptureRequest(target: .region(rect: CGRect(x: 200, y: 200, width: 10, height: 10),
                                                  displayID: 7, displayFrame: frame, scale: 1),
                                 barWindowIDs: [], overlayWindowIDs: [])
    let invalidScale = CaptureRequest(target: .region(rect: CGRect(x: 2, y: 2, width: 10, height: 10),
                                                       displayID: 7, displayFrame: frame, scale: 0),
                                      barWindowIDs: [], overlayWindowIDs: [])
    let window = CaptureRequest(target: .window(windowID: 42), barWindowIDs: [], overlayWindowIDs: [])
    #expect(empty.regionPixelRect == nil)
    #expect(outside.regionPixelRect == nil)
    #expect(invalidScale.regionPixelRect == nil)
    #expect(window.regionPixelRect == nil)
}

@Test func captureRequestExclusionsAreDerivedFromEachCallersWindowIDs() {
    let first = CaptureRequest(target: .window(windowID: 90), barWindowIDs: [1, 99], overlayWindowIDs: [2])
    let second = CaptureRequest(target: .fullScreen(displayID: 3), barWindowIDs: [7], overlayWindowIDs: [8, 99])
    #expect(first.excludedWindowIDs == [1, 2, 99])
    #expect(second.excludedWindowIDs == [7, 8, 99])
    #expect(first.excludedWindowIDs != second.excludedWindowIDs)
}
