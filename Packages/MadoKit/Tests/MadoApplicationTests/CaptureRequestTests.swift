import Foundation
import CoreGraphics
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

@Test func issue683NegativeOriginDisplayRoundsRegionPixels() {
    let frame = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
    let rect = CGRect(x: -1900.2, y: 100.4, width: 100.1, height: 70.2)
    let request = CaptureRequest(target: .region(rect: rect, displayID: 9, displayFrame: frame, scale: 2),
                                 barWindowIDs: [], overlayWindowIDs: [])
    #expect(request.regionPixelRect == CGRect(x: 39, y: 1818, width: 201, height: 142))
}

@Test func issue683LegacyCropPreservesOnlySelectedPixels() throws {
    var pixels: [UInt8] = []
    for value in UInt8(0)..<16 { pixels += [value, 0, 0, 255] }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let request = CaptureRequest(target: .region(rect: CGRect(x: 1, y: 1, width: 2, height: 2),
                                                  displayID: 7, displayFrame: CGRect(x: 0, y: 0, width: 4, height: 4), scale: 1),
                                 barWindowIDs: [], overlayWindowIDs: [])
    let cropped = try #require(request.cropDisplayImage(image))
    #expect(cropped.width == 2 && cropped.height == 2)
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(cropped, in: CGRect(x: 0, y: 0, width: 2, height: 2))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    #expect(Set((0..<4).map { bytes[$0 * 4] }) == Set([5, 6, 9, 10]))
}

@Test(.timeLimit(.minutes(2))) func issue683CaptureResultReusesEncodedPNGForClipboard() async throws {
    let screen = RecordingScreen()
    let files = RecordingFiles()
    let session = CaptureSession(screen: screen, files: files)
    let request = CaptureRequest(target: .window(windowID: 42), barWindowIDs: [], overlayWindowIDs: [])
    let result = try await session.captureResult(request: request)
    #expect(result.png == Data([2]))
    #expect(await files.data == result.png)
    #expect(result.url.lastPathComponent.hasSuffix(".png"))
}

@Test(.timeLimit(.minutes(2))) func issue683CaptureResultWithoutRequestKeepsFullScreenBytes() async throws {
    let screen = RecordingScreen()
    let files = RecordingFiles()
    let result = try await CaptureSession(screen: screen, files: files).captureResult(request: nil)
    #expect(result.png == Data([1]))
    #expect(await files.data == Data([1]))
}

@Test func issue683LegacyCropReturnsNilForNonRegionRequest() throws {
    let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                         bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    let image = try #require(context.makeImage())
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [], overlayWindowIDs: [])
    #expect(request.cropDisplayImage(image) == nil)
}

@Test(.timeLimit(.minutes(2))) func issue683RequestKeepsBarAndOverlayIDsApart() {
    let request = CaptureRequest(target: .fullScreen(displayID: 7), barWindowIDs: [11, 12], overlayWindowIDs: [12, 13])
    #expect(request.barWindowIDs == [11, 12])
    #expect(request.overlayWindowIDs == [12, 13])
    #expect(request.excludedWindowIDs == [11, 12, 13])
}
