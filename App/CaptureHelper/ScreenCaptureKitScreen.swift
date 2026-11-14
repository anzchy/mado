import AppKit
import Foundation
import ImageIO
import ScreenCaptureKit
import MadoApplication

struct ScreenCaptureKitScreen: CaptureScreenPort {
    struct TestDisplay: Sendable {
        let width: Int
        let height: Int
        let scale: Double
    }
    var testDisplay: TestDisplay?

    init(testDisplay: TestDisplay? = nil) { self.testDisplay = testDisplay }

    private func pixelDimensions(width: Int, height: Int, scale: Double) -> (Int, Int) {
        (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }

    static func permissionState(preflight: Bool, previouslyRequested: Bool,
                                requestGranted: Bool) -> CapturePermissionState {
        if preflight || requestGranted { return .granted }
        return previouslyRequested ? .denied : .notAsked
    }
    enum Failure: Error {
        case permissionDenied, permissionNotAsked
        case displayUnavailable
        case pngEncodingFailed
    }

    func captureCurrentDisplayPNG() async throws -> Data {
        if let testDisplay {
            let pixels = pixelDimensions(width: testDisplay.width, height: testDisplay.height, scale: testDisplay.scale)
            let context = CGContext(data: nil, width: pixels.0, height: pixels.1,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return try pngData(from: context.makeImage()!)
        }
        let defaults = UserDefaults(suiteName: CaptureBarIdentity.appGroupID)
        let preflight = CGPreflightScreenCaptureAccess()
        let previouslyRequested = defaults?.bool(forKey: CaptureBarIdentity.permissionRequestedKey) == true
        var requestGranted = false
        if !preflight && !previouslyRequested {
            defaults?.set(true, forKey: CaptureBarIdentity.permissionRequestedKey)
            requestGranted = CGRequestScreenCaptureAccess()
        }
        let permission = Self.permissionState(preflight: preflight, previouslyRequested: previouslyRequested,
                                              requestGranted: requestGranted)
        defaults?.set(permission.rawValue, forKey: CaptureBarIdentity.permissionKey)
        switch permission {
        case .granted: break
        case .denied: throw Failure.permissionDenied
        case .notAsked: throw Failure.permissionNotAsked
        }
        let point = await MainActor.run { NSEvent.mouseLocation }
        let displayInfo: (UInt32, CGFloat)? = await MainActor.run {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main,
                  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            return (id, screen.backingScaleFactor)
        }
        guard let (displayID, scale) = displayInfo
        else { throw Failure.displayUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayUnavailable
        }
        let helperWindowIDs = await MainActor.run { NSApp.windows.map { UInt32($0.windowNumber) } }
        let ownWindows = content.windows.filter { helperWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        let pixels = pixelDimensions(width: scDisplay.width, height: scDisplay.height, scale: Double(scale))
        configuration.width = pixels.0
        configuration.height = pixels.1
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try pngData(from: image)
    }

    private func pngData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw Failure.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.pngEncodingFailed }
        return data as Data
    }
}
