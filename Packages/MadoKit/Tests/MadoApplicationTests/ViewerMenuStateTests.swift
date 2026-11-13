import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class MenuStateHost: ViewerSessionNavigationHost {
    var hasImage = true
    var canNavigate = true
    var canvas: [CommandID] = []
    var entries: [CommandEntry] = []
    var inspections: [Bool] = []
    var navigation: [NavigationDirection] = []
    var opens = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { canvas.append(command); entries.append(entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? {
        canvas.append(command); entries.append(entry); return 1.5
    }
    func requestOpen() { opens += 1 }
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) { inspections.append(visible) }
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
}

private actor MenuOpeningGate {
    private var pending: CheckedContinuation<AccessImageSource, any Error>?
    private var arrival: CheckedContinuation<Void, Never>?
    func open() async throws -> AccessImageSource {
        try await withCheckedThrowingContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func fail() { pending?.resume(throwing: ImageLoadError(.corruptImage)); pending = nil }
}

@MainActor private func assertMenuImageCommandsBlocked(_ session: ViewerSession, host: MenuStateHost) {
    let inspections = host.inspections
    for entry: CommandEntry in [.menu, .button, .key] {
        for command: CommandID in [.fit, .actualPixels, .zoomIn, .zoomOut, .inspector] {
            #expect(!session.isEnabled(command))
            #expect(!CommandRouter().route(command, from: entry, to: session))
        }
        #expect(session.isEnabled(.open))
        #expect(CommandRouter().route(.open, from: entry, to: session))
    }
    #expect(host.canvas.isEmpty)
    #expect(host.inspections == inspections)
    #expect(!session.inspectorFocus.isVisible)
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesMenuLoadingFailureAndEmptyRejectStaleHostImageAcrossEntries() async {
    let host = MenuStateHost(), gate = MenuOpeningGate()
    let session = ViewerSession(host: host)
    session.openImage(URL(fileURLWithPath: "/B.jpg"), maximumPixelSize: 512) { try await gate.open() }
    let pending = session.imageLoader.loadTask
    await gate.entered()
    #expect(session.imageStatus == .loading("B.jpg"))
    #expect(host.hasImage)
    assertMenuImageCommandsBlocked(session, host: host)
    #expect(host.opens == 3)
    #expect(host.inspections.isEmpty)
    session.setInspectorVisible(true)
    #expect(session.isEnabled(.inspector))
    #expect(CommandRouter().route(.inspector, from: .menu, to: session))
    #expect(!session.isEnabled(.inspector))
    #expect(host.inspections == [true, false])
    await gate.fail(); await pending?.value
    #expect(session.imageStatus == .failed(.corruptImage, "B.jpg"))
    assertMenuImageCommandsBlocked(session, host: host)
    #expect(host.opens == 6)
    #expect(host.canvas.isEmpty)
    #expect(host.inspections == [true, false])
    #expect(session.isEnabled(.next))
    #expect(CommandRouter().route(.next, from: .menu, to: session))
    #expect(host.navigation == [.next])
    session.closeImage(); host.hasImage = false
    #expect(session.imageStatus == .empty)
    #expect(!session.isEnabled(.previous))
    #expect(!session.isEnabled(.next))
    #expect(!session.isEnabled(.inspector))
    #expect(session.isEnabled(.open))
}

@Test(.timeLimit(.minutes(2))) @MainActor func statesMenuShowingEnablesImageActionsAcrossEntries() async {
    let host = MenuStateHost(), pipeline = LoadPipeline(), access = LoadLeases()
    let session = ViewerSession(host: host)
    let file = URL(fileURLWithPath: "/A.png")
    session.openImage(file, maximumPixelSize: 512) {
        try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: pipeline)
    }
    await session.imageLoader.loadTask?.value
    #expect(session.imageStatus == .showing)
    #expect(session.imageLoader.presented?.fileURL == file)
    for entry: CommandEntry in [.menu, .button, .key] {
        for command: CommandID in [.fit, .actualPixels, .zoomIn, .zoomOut] {
            #expect(session.isEnabled(command))
            #expect(CommandRouter().route(command, from: entry, to: session))
        }
    }
    #expect(host.canvas == [.fit, .actualPixels, .zoomIn, .zoomOut,
        .fit, .actualPixels, .zoomIn, .zoomOut, .fit, .actualPixels, .zoomIn, .zoomOut])
    #expect(host.entries == [.menu, .menu, .menu, .menu, .button, .button, .button, .button, .key, .key, .key, .key])
    #expect(session.isEnabled(.inspector))
    #expect(CommandRouter().route(.inspector, from: .key, to: session))
    #expect(session.inspectorFocus.isVisible)
    #expect(host.inspections == [true])
    session.closeImage()
}
