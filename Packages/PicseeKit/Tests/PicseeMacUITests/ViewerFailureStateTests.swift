import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

private let failureMessages: [(ViewerImageFailure, String)] = [
    (.corruptImage, "The file may be damaged or its format unreadable."),
    (.unsupportedFormat, "This image format is not supported."),
    (.resourceLimit, "This image exceeds the available resources."),
    (.sourceChanged, "The file changed again while it was being opened."),
    (.access, "Access to this image is unavailable.")
]

@Test(arguments: failureMessages) @MainActor private func statesFailureMessagePartitions(_ example: (ViewerImageFailure, String)) {
    let scene = StatesScene()
    defer { scene.window.close() }
    #expect(example.0.messageKey == example.1)
    scene.state.display(.failed(example.0, "B.jpg"))
    #expect(scene.state.textLines == ["Unable to read this image", "B.jpg", example.1])
    #expect(scene.state.buttons.map { $0.accessibilityIdentifier() } == ["state.retry"])
    #expect(scene.state.buttons.first?.title == "Retry")
    #expect(!scene.state.showsProgress)
}

@Test @MainActor func statesFailureNextTracksSessionAndNeverShowsPreviousPixels() async throws {
    let scene = StatesScene(), pipeline = StatesPipeline(), leases = StatesLeases()
    defer { scene.session.closeImage(); scene.window.close() }
    await scene.open(URL(fileURLWithPath: "/A.png"), pipeline: pipeline, leases: leases)?.value
    #expect(scene.canvas.hasImage)
    #expect(scene.window.title == "A.png")
    await scene.open(URL(fileURLWithPath: "/B.jpg"), pipeline: pipeline, leases: leases)?.value
    #expect(scene.session.imageStatus == .failed(.corruptImage, "B.jpg"))
    #expect(scene.session.imageLoader.presented == nil)
    #expect(!scene.canvas.hasImage)
    #expect(scene.window.title == "Picsee")
    for enabled in [false, true, false] {
        scene.host.canNavigate = enabled
        scene.state.refresh()
        #expect(scene.session.isEnabled(.next) == enabled)
        #expect(scene.state.buttons.map { $0.accessibilityIdentifier() } == (enabled ? ["state.retry", "state.next"] : ["state.retry"]))
        if enabled {
            let next = try #require(scene.state.buttons.last)
            #expect(next.title == "Next")
            next.performClick(nil)
            #expect(scene.host.navigation == [.next])
        }
    }
}

@Test(arguments: [960.0, 238.0]) @MainActor func statesFailureKeepsEveryToolHitTestable(_ width: Double) async throws {
    let scene = StatesScene(width: width), pipeline = StatesPipeline(), leases = StatesLeases()
    defer { scene.session.closeImage(); scene.window.close() }
    await scene.open(URL(fileURLWithPath: "/B.jpg"), pipeline: pipeline, leases: leases)?.value
    scene.state.refresh(); scene.chrome.refresh(); scene.chrome.setToolsVisible(true)
    #expect(scene.chrome.tools.count == 8)  // #444: 侧栏 / 返回网格 / 更多 + ← → + − 缩放模式 +
    for tool in scene.chrome.tools {
        let point = tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: scene.content)
        #expect(scene.content.hitTest(point) === tool)
    }
    let retry = try #require(scene.state.buttons.first)
    let point = retry.convert(NSPoint(x: retry.bounds.midX, y: retry.bounds.midY), to: scene.content)
    #expect(scene.content.hitTest(point) === retry)
    for command: CommandID in [.zoomOut, .actualPixels, .zoomIn] { #expect(!scene.session.isEnabled(command)) }
    // #444: 打开 left the pod; 更多 still presents its menu over a failed image.
    let presenter = RecordingMenuPresenter()
    scene.chrome.menuPresenter = presenter
    scene.chrome.moreMenuProvider = { NSMenu(title: "More") }
    scene.chrome.tools[2].activate()
    #expect(presenter.presented.count == 1)
}

@Test @MainActor func statesLimitedKeepsActualPreviewAndDoesNotTakeFocus() async {
    let scene = StatesScene(), pipeline = StatesPipeline(), leases = StatesLeases()
    defer { scene.session.closeImage(); scene.window.close() }
    await scene.open(URL(fileURLWithPath: "/limited.png"), pipeline: pipeline, leases: leases)?.value
    scene.state.refresh()
    #expect(scene.session.imageStatus == .detailLimited)
    #expect(scene.session.imageLoader.presented?.name == "limited.png")
    #expect(scene.session.imageLoader.presented?.key.isPreview == true)
    #expect(scene.canvas.hasImage)
    #expect(scene.host.installs == 1)
    #expect(scene.host.failures == 0)
    #expect(scene.state.textLines == ["Showing reduced detail"])
    #expect(scene.state.buttons.isEmpty)
    #expect(!scene.state.acceptsFirstResponder)
    #expect(!scene.state.showsProgress)
    for tool in scene.chrome.tools {
        let point = tool.convert(NSPoint(x: tool.bounds.midX, y: tool.bounds.midY), to: scene.content)
        #expect(scene.content.hitTest(point) === tool)
    }
    await scene.open(URL(fileURLWithPath: "/C.png"), pipeline: pipeline, leases: leases)?.value
    scene.state.refresh()
    #expect(scene.session.imageStatus == .showing)
    #expect(scene.session.imageLoader.presented?.name == "C.png")
    #expect(scene.state.textLines.isEmpty)
    #expect(scene.state.buttons.isEmpty)
}
