import Foundation
import ImageIO
import Testing
import MadoApplication

@Test(.timeLimit(.minutes(3))) func issue682ScreenPortProducesNativePixelsOnTwoTimesDisplay() async throws {
    let screen: any CaptureScreenPort = ScreenCaptureKitScreen(
        testDisplay: .init(width: 80, height: 50, scale: 2))
    let png = try await screen.captureCurrentDisplayPNG()
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(image.width == 160)
    #expect(image.height == 100)
}

@Test(.timeLimit(.minutes(3))) func issue682FirstPermissionRequestIsNotCalledDenied() throws {
    #expect(ScreenCaptureKitScreen.permissionState(preflight: false, previouslyRequested: false,
                                                  requestGranted: false) == .notAsked)
    #expect(ScreenCaptureKitScreen.permissionState(preflight: false, previouslyRequested: true,
                                                  requestGranted: false) == .denied)
    #expect(ScreenCaptureKitScreen.permissionState(preflight: true, previouslyRequested: true,
                                                  requestGranted: false) == .granted)
    let catalog = try captureCatalog("zh-Hans")
    #expect(catalog["Allow Mado in System Settings › Privacy & Security › Screen & System Audio Recording, then try Capture again."]
            == "请在「系统设置 › 隐私与安全性 › 录屏与系统录音」中允许 Mado，然后再次截图。")
}
