import Foundation
import ScreenCaptureKit
import Testing
import MadoApplication

// #683 fix round 3, F2 (owner 2026-11-14 「不带指针（推荐）」): no capture mode includes the mouse pointer.

@Test func issue683Fix3CapturesExcludeThePointer() {
    let requests: [CaptureRequest] = [
        CaptureRequest(target: .region(rect: CGRect(x: 0, y: 0, width: 100, height: 80), displayID: 1,
                                       displayFrame: CGRect(x: 0, y: 0, width: 800, height: 600), scale: 2),
                       barWindowIDs: [21], overlayWindowIDs: [22]),
        CaptureRequest(target: .window(windowID: 88), barWindowIDs: [21], overlayWindowIDs: [22]),
        CaptureRequest(target: .fullScreen(displayID: 1), barWindowIDs: [21], overlayWindowIDs: [])
    ]
    for request in requests {
        #expect(ScreenCaptureKitScreen.configuration(for: request).showsCursor == false)
    }
}
