import AppKit
import Foundation
import ImageIO
import ScreenCaptureKit
import MadoApplication

struct ScreenCaptureKitScreen: CaptureScreenPort {
    struct WindowCandidate: Sendable {
        let id: UInt32
        let frame: CGRect
    }
    struct TestDisplay: Sendable {
        let width: Int
        let height: Int
        let scale: Double
    }
    var testDisplay: TestDisplay?
    typealias DisplayFilterFactory = @Sendable (SCDisplay, [SCWindow]) -> SCContentFilter
    let makeDisplayFilter: DisplayFilterFactory

    init(testDisplay: TestDisplay? = nil,
         makeDisplayFilter: @escaping DisplayFilterFactory = { SCContentFilter(display: $0, excludingWindows: $1) }) {
        self.testDisplay = testDisplay
        self.makeDisplayFilter = makeDisplayFilter
    }

    /// The production display filter: the display and exactly the resolved excluded windows.
    static func displayFilter<Display, Window, Filter>(display: Display, request: CaptureRequest, windows: [Window],
                                                        id: (Window) -> UInt32,
                                                        make: (Display, [Window]) -> Filter) throws -> Filter {
        displayFilter(display: display, resolved: try CaptureFilterPlan.resolveWindows(request, windows: windows, id: id),
                      make: make)
    }

    /// `capturePNG` resolves once and calls this with the result.
    static func displayFilter<Display, Window, Filter>(display: Display,
                                                        resolved: CaptureFilterPlan.ResolvedWindows<Window>,
                                                        make: (Display, [Window]) -> Filter) -> Filter {
        make(display, resolved.excludedWindows)
    }

    /// Full screen excludes every helper window; shown ones are required, never-shown ones optional.
    @MainActor static func fullScreenRequest(displayID: UInt32, windows: [NSWindow]) -> CaptureRequest {
        CaptureRequestFromWindows.make(target: .fullScreen(displayID: displayID), bars: windows, overlays: [])
    }

    /// The one configuration every capture mode (region, window, full screen) starts from.
    /// No capture includes the pointer (owner 2026-11-14); ScreenCaptureKit shows it by default.
    static func configuration(for request: CaptureRequest) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = false
        return configuration
    }

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
        case displayUnavailable, windowUnavailable, regionUnavailable
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
        let point = await MainActor.run { NSEvent.mouseLocation }
        let displayID: UInt32? = await MainActor.run {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return nil }
            return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        }
        guard let displayID else { throw Failure.displayUnavailable }
        let request = await MainActor.run { Self.fullScreenRequest(displayID: displayID, windows: NSApp.windows) }
        return try await capturePNG(request: request)
    }

    func capturePNG(request: CaptureRequest) async throws -> Data {
        try checkPermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let resolved = try CaptureFilterPlan.resolveWindows(request, windows: content.windows, id: { $0.windowID })
        let configuration = Self.configuration(for: request)
        let filter: SCContentFilter
        var legacyCrop = false
        switch resolved.plan.target {
        case let .window(windowID):
            guard let window = resolved.targetWindow, window.windowID == windowID,
                  window.isOnScreen && window.windowLayer == 0
            else { throw Failure.windowUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            let windowFrame = window.frame
            let scale = await MainActor.run {
                let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
                let center = CGPoint(x: windowFrame.midX, y: primaryTop - windowFrame.midY)
                return NSScreen.screens.first { $0.frame.contains(center) }?.backingScaleFactor ?? 1
            }
            configuration.width = Int((windowFrame.width * scale).rounded(.up))
            configuration.height = Int((windowFrame.height * scale).rounded(.up))
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw Failure.displayUnavailable
            }
            filter = Self.displayFilter(display: display, resolved: resolved, make: makeDisplayFilter)
            let scale: CGFloat
            if case let .region(_, _, _, requestedScale) = request.target {
                scale = requestedScale
            } else {
                scale = await MainActor.run {
                    NSScreen.screens.first {
                        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
                    }?.backingScaleFactor ?? 1
                }
            }
            let pixels = pixelDimensions(width: display.width, height: display.height, scale: Double(scale))
            configuration.width = pixels.0
            configuration.height = pixels.1
            if case .region = request.target {
                guard let pixelRect = request.regionPixelRect else { throw Failure.regionUnavailable }
                if #available(macOS 15, *) {
                    configuration.sourceRect = CGRect(x: pixelRect.minX / scale, y: pixelRect.minY / scale,
                                                      width: pixelRect.width / scale, height: pixelRect.height / scale)
                    configuration.width = Int(pixelRect.width)
                    configuration.height = Int(pixelRect.height)
                } else {
                    legacyCrop = true
                }
            }
        }
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        if legacyCrop {
            guard let cropped = request.cropDisplayImage(image) else { throw Failure.regionUnavailable }
            return try pngData(from: cropped)
        }
        return try pngData(from: image)
    }

    func selectableWindows(excluding excludedIDs: Set<UInt32>) async throws -> [WindowCandidate] {
        try checkPermission()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                     as? [[String: Any]] ?? []).enumerated().reduce(into: [UInt32: Int]()) { result, entry in
            if let id = (entry.element[kCGWindowNumber as String] as? NSNumber)?.uint32Value {
                result[id] = entry.offset
            }
        }
        return content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && !excludedIDs.contains($0.windowID)
                && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        }.map { WindowCandidate(id: $0.windowID, frame: $0.frame) }
            .sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }

    private func checkPermission() throws {
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
