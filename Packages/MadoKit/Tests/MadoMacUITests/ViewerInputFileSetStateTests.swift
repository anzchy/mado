import AppKit
import Testing
import MadoCore
@testable import MadoApplication
@testable import MadoMacUI

@MainActor private final class FileSetNativeAdapter: ViewerInputHost, ViewerSessionNavigationHost {
    let scene: StatesScene
    let pipeline = StatesPipeline()
    let leases = StatesLeases()
    var retry: ViewerRetryIntent?
    var notices: [ViewerInputNotice] = []
    var prompts: [URL] = []
    var navigation: [NavigationDirection] = []
    var opened: [URL] = []
    init(_ scene: StatesScene) { self.scene = scene; scene.session.host = self }
    var hasImage: Bool { scene.canvas.hasImage }
    var canNavigate: Bool { true }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) {
        opened.append(url); retry = ViewerRetryIntent(fileURL: url, accessRequest: accessRequest)
        scene.open(url, request: accessRequest, pipeline: pipeline, leases: leases)
    }
    func showInputNotice(_ notice: ViewerInputNotice) { notices.append(notice) }
    func promptForInputFolder(_ folder: URL) { prompts.append(folder) }
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { scene.host.performCanvas(command, from: entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { scene.host.performCanvasZoom(command, from: entry) }
    func requestOpen() { scene.host.requestOpen() }
    func applyFocus(_ focus: FocusContext) { scene.host.applyFocus(focus) }
    func showInspector(_ visible: Bool) { scene.host.showInspector(visible) }
}

@Test(.timeLimit(.minutes(2))) @MainActor func inputFileSetFailedMemberNativeNextAndRetryPreserveIndex() async throws {
    let scene = StatesScene(), adapter = FileSetNativeAdapter(scene), intent = AccessIntent()
    defer { scene.session.closeImage(); scene.window.close() }
    scene.state.onRetry = { adapter.retry?.reopen { adapter.openInputImage($0, accessRequest: $1) } }
    let a = URL(fileURLWithPath: "/photos/A.png"), b = URL(fileURLWithPath: "/photos/B.jpg")
    let c = URL(fileURLWithPath: "/photos/C.png")
    let admission = ViewerInputAdmission(access: adapter.leases, pipeline: adapter.pipeline, maximumPixelSize: 512, rootCovering: { _ in nil })
    await scene.session.openInput([c, a, b], operation: intent.begin(), admission: admission, host: adapter)
    await scene.session.imageLoader.loadTask?.value
    #expect(scene.session.imageStatus == .showing)
    #expect(CommandRouter().route(.next, from: .key, to: scene.session))
    await scene.session.imageLoader.loadTask?.value
    scene.state.refresh()
    #expect(scene.session.imageStatus == .failed(.corruptImage, "B.jpg"))
    #expect(!scene.canvas.hasImage)
    #expect(scene.session.filePreviewSet?.index == 1)
    #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.retry", "state.next"])
    let retryButton = try #require(scene.state.buttons.first { $0.identifier?.rawValue == "state.retry" })
    retryButton.performClick(nil)
    await scene.session.imageLoader.loadTask?.value
    scene.state.refresh()
    #expect(scene.session.filePreviewSet?.index == 1)
    #expect(adapter.retry?.fileURL == b)
    #expect(adapter.retry?.accessRequest == nil)
    #expect(scene.session.filePreviewSet?.members == [a, b, c])
    let nextButton = try #require(scene.state.buttons.first { $0.identifier?.rawValue == "state.next" })
    #expect(nextButton.isEnabled)
    nextButton.performClick(nil)
    await scene.session.imageLoader.loadTask?.value
    #expect(scene.session.filePreviewSet?.index == 2)
    #expect(scene.session.imageLoader.presented?.fileURL == c)
    #expect(scene.canvas.hasImage)
    #expect(adapter.opened == [a, b, b, c])
    #expect(adapter.notices.isEmpty && adapter.prompts.isEmpty && adapter.navigation.isEmpty)
    await scene.session.openInput([a, b], operation: intent.begin(), admission: admission, host: adapter)
    await scene.session.imageLoader.loadTask?.value
    #expect(CommandRouter().route(.next, from: .menu, to: scene.session))
    await scene.session.imageLoader.loadTask?.value
    scene.state.refresh()
    #expect(scene.session.imageStatus == .failed(.corruptImage, "B.jpg"))
    #expect(scene.state.buttons.map { $0.identifier?.rawValue } == ["state.retry"])
    #expect(scene.session.isEnabled(.next) == false)
}
