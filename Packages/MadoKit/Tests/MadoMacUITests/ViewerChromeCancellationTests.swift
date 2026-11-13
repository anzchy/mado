import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

private actor ChromeOpeningGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
}

@MainActor private final class ChromeCancellationHost: ViewerImageHost {
    let session: ViewerSession
    init(_ session: ViewerSession) { self.session = session }
    func beginImageOpening() {}
    func installImage(_ image: DecodedImage, fileURL: URL) {}
    func imageLoadFailed(_ error: any Error) { _ = session.dismissCancelledImageFailure(error) }
}

@MainActor private func filenameLabel(_ chrome: ViewerChromeOverlay) throws -> NSTextField {
    try #require(chrome.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityIdentifier() == "chrome.filename" })
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesChromeCancelClearsLabelAcrossRefreshAndReopen() async throws {
    let scene = StatesScene()
    defer { scene.window.close() }
    let label = try filenameLabel(scene.chrome)
    let navigationURL = URL(fileURLWithPath: "/B.png")
    let gate = ChromeOpeningGate()
    scene.session.openImage(navigationURL, maximumPixelSize: 512) {
        await gate.wait(); throw ImageLoadError(.cancelled)
    }
    let task = scene.session.imageLoader.loadTask
    await gate.entered()
    scene.state.refresh(); scene.chrome.refresh(session: scene.session)
    #expect(scene.session.imageStatus == .loading("B.png"))
    #expect(scene.chrome.filename == "B.png")
    #expect(label.stringValue == "B.png")
    let cancel = try #require(scene.state.buttons.first { $0.accessibilityIdentifier() == "state.cancel" })
    cancel.performClick(nil)
    for _ in 0..<2 {
        scene.chrome.refresh(session: scene.session)
        #expect(scene.session.imageStatus == .empty)
        #expect(scene.session.imageLoader.fileURL == nil)
        #expect(scene.chrome.filename == nil)
        #expect(label.stringValue == "")
    }
    #expect(navigationURL.lastPathComponent == "B.png")
    #expect(scene.state.buttons.first?.accessibilityIdentifier() == "state.open")
    await gate.release(); await task?.value
    scene.chrome.refresh(session: scene.session)
    #expect(label.stringValue == "")

    let c = URL(fileURLWithPath: "/C.png")
    scene.session.openImage(c, maximumPixelSize: 512) { throw ImageLoadError(.cancelled) }
    let reopened = scene.session.imageLoader.loadTask
    scene.chrome.refresh(session: scene.session)
    #expect(scene.chrome.filename == "C.png")
    #expect(label.stringValue == "C.png")
    scene.session.cancelImageOpening()
    await reopened?.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesChromeDeliveredCancellationAndDismissClearLabel() async throws {
    let scene = StatesScene()
    let host = ChromeCancellationHost(scene.session)
    scene.session.imageLoader.host = host
    defer { scene.window.close() }
    let label = try filenameLabel(scene.chrome)
    let failures: [(String, any Error)] = [
        ("external.png", ImageLoadError(.cancelled)), ("task.png", CancellationError())
    ]
    for (name, error) in failures {
        scene.session.openImage(URL(fileURLWithPath: "/" + name), maximumPixelSize: 512) { throw error }
        scene.chrome.refresh(session: scene.session)
        #expect(scene.chrome.filename == name)
        #expect(label.stringValue == name)
        await scene.session.imageLoader.loadTask?.value
        for _ in 0..<2 {
            scene.chrome.refresh(session: scene.session)
            #expect(scene.session.imageStatus == .empty)
            #expect(scene.session.imageLoader.fileURL == nil)
            #expect(scene.chrome.filename == nil)
            #expect(label.stringValue == "")
        }
    }
    scene.session.openImage(URL(fileURLWithPath: "/dismiss.png"), maximumPixelSize: 512) {
        throw ImageLoadError(.cancelled)
    }
    let task = scene.session.imageLoader.loadTask
    scene.chrome.refresh(session: scene.session)
    #expect(label.stringValue == "dismiss.png")
    #expect(scene.session.dismissCancelledImageFailure(ImageLoadError(.cancelled)))
    for _ in 0..<2 {
        scene.chrome.refresh(session: scene.session)
        #expect(scene.session.imageStatus == .empty)
        #expect(scene.session.imageLoader.fileURL == nil)
        #expect(scene.chrome.filename == nil)
        #expect(label.stringValue == "")
    }
    await task?.value
}
