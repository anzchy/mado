import AppKit
import Foundation
import ImageIO
import ScreenCaptureKit
import MadoApplication

struct ScreenCaptureKitScreen: CaptureScreenPort {
    enum Failure: Error {
        case permissionDenied
        case displayUnavailable
        case pngEncodingFailed
    }

    func captureCurrentDisplayPNG() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw Failure.permissionDenied
        }
        let point = await MainActor.run { NSEvent.mouseLocation }
        let displayID = await MainActor.run {
            (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?
                .deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        }?.uint32Value
        guard let displayID else { throw Failure.displayUnavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.displayUnavailable
        }
        let helperWindowIDs = await MainActor.run { NSApp.windows.map { UInt32($0.windowNumber) } }
        let ownWindows = content.windows.filter { helperWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            throw Failure.pngEncodingFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.pngEncodingFailed }
        return data as Data
    }
}
