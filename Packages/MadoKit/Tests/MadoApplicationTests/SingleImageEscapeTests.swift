import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class SingleImageReturnHost: ViewerSessionHost, ViewerSingleImageReturnHost {
    var hasImage = true
    var canReturnToFolder = true
    var returns = 0
    var gridReturns = 0
    var focus: FocusContext = .canvas
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) { self.focus = focus }
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() { gridReturns += 1 }
    func returnSingleImageToFolder() { returns += 1 }
}

@Test(.timeLimit(.minutes(2))) @MainActor func singleImageEscRunsAfterInspectorFocusThenReturnsOnce() {
    let router = CommandRouter()
    for context in [FocusContext.textInput, .panel, .tools] {
        let host = SingleImageReturnHost(), session = ViewerSession(host: host)
        session.setInspectorVisible(true)
        session.updateFocus(context)
        #expect(session.inspectorFocus.focus == context)
        #expect(router.route(.escape, from: .key, to: session))
        #expect(host.returns == 0, "Esc from \(context) must first return focus to the canvas")
        #expect(session.inspectorFocus.focus == .canvas)
        #expect(host.focus == .canvas)
        #expect(session.inspectorFocus.isVisible)
        #expect(router.route(.escape, from: .key, to: session))
        #expect(host.returns == 1)
    }

    let host = SingleImageReturnHost(), session = ViewerSession(host: host)
    #expect(session.isEnabled(.escape))
    session.setMenuTracking(true)
    #expect(!router.route(.escape, from: .key, to: session))
    #expect(!router.route(.escape, from: .menu, to: session))
    session.setMenuTracking(false)
    #expect(host.returns == 0)
    host.canReturnToFolder = false
    #expect(!session.isEnabled(.escape))
    #expect(!router.route(.escape, from: .key, to: session))
    #expect(host.returns == 0)
    host.canReturnToFolder = true

    session.filePreviewSet = FilePreviewSet(files: [URL(fileURLWithPath: "/input/one.png"),
        URL(fileURLWithPath: "/input/two.png")])
    #expect(!session.isEnabled(.escape))
    #expect(!router.route(.escape, from: .key, to: session))
    session.filePreviewSet = nil

    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [a, b], sourceVersion: .init(1), scrollAnchor: nil)
    #expect(!router.route(.escape, from: .key, to: session))
    session.select(a)
    #expect(router.route(.preview, from: .key, to: session))
    #expect(router.route(.escape, from: .key, to: session))
    #expect(host.gridReturns == 1)
    #expect(host.returns == 0)
}
