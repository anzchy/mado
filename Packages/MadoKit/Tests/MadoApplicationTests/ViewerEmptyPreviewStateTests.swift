import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class EmptyPreviewHost: ViewerSessionNavigationHost {
    var hasImage = false
    var canNavigate = true
    var navigations = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func navigate(_ direction: NavigationDirection) { navigations += 1 }
}

private actor EmptyPreviewOpeningGate {
    private var pending: CheckedContinuation<AccessImageSource, any Error>?
    private var arrival: CheckedContinuation<Void, Never>?
    func open() async throws -> AccessImageSource {
        try await withCheckedThrowingContinuation { pending = $0; arrival?.resume(); arrival = nil }
    }
    func entered() async {
        if pending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func finish() { pending?.resume(throwing: ImageLoadError(.cancelled)); pending = nil }
}

@Test @MainActor func statesEmptyPreviewCannotNavigateBeforeLoadOrAfterCancel() async {
    let host = EmptyPreviewHost(), session = ViewerSession(host: nil)
    session.host = host
    let first = ItemID.ephemeral(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let second = ItemID.ephemeral(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    session.beginBrowsing(items: [first, second], sourceVersion: .init(1), scrollAnchor: first)
    session.select(first)
    #expect(router.route(.preview, from: .button, to: session))
    #expect(session.previewSet?.itemIDs == [first, second])
    #expect(session.currentItemID == first)
    #expect(session.imageStatus == .empty)
    for entry: CommandEntry in [.menu, .button, .key] {
        #expect(!session.isEnabled(.next))
        #expect(!router.route(.next, from: entry, to: session))
        #expect(session.currentItemID == first)
        #expect(!session.isEnabled(.previous))
        #expect(!router.route(.previous, from: entry, to: session))
        #expect(session.currentItemID == first)
    }
    let gate = EmptyPreviewOpeningGate()
    session.openImage(URL(fileURLWithPath: "/A.png"), maximumPixelSize: 512) { try await gate.open() }
    let old = session.imageLoader.loadTask
    await gate.entered()
    #expect(session.imageStatus == .loading("A.png"))
    session.cancelImageOpening()
    #expect(session.imageStatus == .empty)
    #expect(session.previewSet?.itemIDs == [first, second])
    for entry: CommandEntry in [.menu, .button, .key] {
        #expect(!session.isEnabled(.next))
        #expect(!router.route(.next, from: entry, to: session))
        #expect(!session.isEnabled(.previous))
        #expect(!router.route(.previous, from: entry, to: session))
        #expect(session.currentItemID == first)
    }
    #expect(host.navigations == 0)
    await gate.finish(); await old?.value
    #expect(session.imageStatus == .empty)
    #expect(session.currentItemID == first)
}
