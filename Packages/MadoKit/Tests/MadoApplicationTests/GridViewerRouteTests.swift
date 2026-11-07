import Foundation
import Testing
import MadoCore
import MadoApplication

@MainActor private final class GridRouteHost: ViewerSessionHost {
    var hasImage = true
    var opened: [ItemID] = []
    var returned = 0
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) { opened.append(id) }
    func returnToGrid() { returned += 1 }
}

@Test @MainActor func gridViewerRouteOpensStableCurrentAndReturnsAfterUpdate() {
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), inserted = ItemID.ephemeral(UUID())
    let host = GridRouteHost()
    let session = ViewerSession(host: host)
    let router = CommandRouter(implementedCommands: Set(CommandID.allCases))
    session.beginBrowsing(items: [a, b], sourceVersion: .init(1), scrollAnchor: a)
    session.select(b)
    #expect(router.route(.preview, from: .key, to: session))
    #expect(host.opened == [b])
    session.updateItems([inserted, a, b], sourceVersion: .init(2))
    #expect(router.route(.escape, from: .key, to: session))
    #expect(host.returned == 1)
    #expect(session.selection.currentItemID == b)
    #expect(session.scrollAnchor == a)
    #expect(router.route(.enter, from: .key, to: session))
    #expect(host.opened == [b, b])
}

@Test @MainActor func gridPreviewRemovalPresentsReconciledSuccessorThenEmptyGrid() {
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), c = ItemID.ephemeral(UUID())
    let host = GridRouteHost(), session = ViewerSession(host: host)
    session.beginBrowsing(items: [a, b, c], sourceVersion: .init(1), scrollAnchor: a)
    session.select(b)
    #expect(CommandRouter().route(.preview, from: .key, to: session))
    #expect(host.opened == [b])

    session.updateItems([a, c], sourceVersion: .init(2))
    #expect(session.previewSet?.currentItemID == c)
    #expect(host.opened == [b, c])
    #expect(host.returned == 0)

    session.updateItems([], sourceVersion: .init(3))
    #expect(session.previewSet?.currentItemID == nil)
    #expect(host.opened == [b, c])
    #expect(host.returned == 1)
}

@Test @MainActor func defaultRouterEnablesGridPreviewKeysOnlyWhenBrowseHasItems() {
    let session = ViewerSession(host: GridRouteHost())
    let router = CommandRouter()
    #expect(!router.route(.preview, from: .key, to: session))
    let id = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [id], sourceVersion: .init(1), scrollAnchor: id)
    session.select(id)
    #expect(router.route(.preview, from: .key, to: session))
    #expect(router.route(.escape, from: .key, to: session))
    #expect(router.route(.enter, from: .key, to: session))
}

@Test @MainActor func issue140FolderScanCannotPresentOutsideSearchedOrFrozenPreviewSet() {
    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID()), c = ItemID.ephemeral(UUID())
    // Search projection and frozen Preview Set both pass only their viewed IDs to the session.
    for viewed in [[a, c]] {
        let host = GridRouteHost(), session = ViewerSession(host: host)
        session.beginBrowsing(items: viewed, sourceVersion: .init(1), scrollAnchor: a)
        session.select(a)
        #expect(CommandRouter().route(.preview, from: .key, to: session))
        #expect(!session.allowsFolderScanPresentation)
        session.updateItems([c], sourceVersion: .init(2))
        #expect(host.opened == [a, c])
        #expect(!host.opened.contains(b))
        session.updateItems([], sourceVersion: .init(3))
        #expect(host.returned == 1)
        #expect(session.allowsFolderScanPresentation)
    }
}
