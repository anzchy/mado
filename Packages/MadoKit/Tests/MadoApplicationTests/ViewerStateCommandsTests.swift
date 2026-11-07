import Testing
import MadoCore
import MadoApplication

@MainActor private final class EmptyCommandsHost: ViewerSessionNavigationHost {
    var hasImage = false
    var canNavigate = true
    var opens = 0
    var canvasActions = 0
    var navigations = 0
    var inspector = false
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { canvasActions += 1 }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? {
        canvasActions += 1; return 1
    }
    func requestOpen() { opens += 1 }
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) { inspector = visible }
    func navigate(_ direction: NavigationDirection) { navigations += 1 }
}

@Test @MainActor func statesEmptyCommandPolicyAndHideInspectorException() {
    let host = EmptyCommandsHost(), router = CommandRouter()
    let session = ViewerSession(host: host)
    #expect(session.imageStatus == .empty)
    for command: CommandID in [.fit, .actualPixels, .zoomIn, .zoomOut, .previous, .next, .inspector] {
        #expect(!session.isEnabled(command))
        #expect(!router.route(command, from: .button, to: session))
    }
    #expect(host.canvasActions == 0)
    #expect(host.navigations == 0)
    #expect(!host.inspector)
    #expect(session.isEnabled(.open))
    #expect(router.route(.open, from: .button, to: session))
    #expect(host.opens == 1)
    session.setInspectorVisible(true)
    #expect(session.isEnabled(.inspector))
    #expect(router.route(.inspector, from: .button, to: session))
    #expect(!session.inspectorFocus.isVisible)
    #expect(!host.inspector)
    #expect(session.inspectorFocus.focus == .canvas)
}
