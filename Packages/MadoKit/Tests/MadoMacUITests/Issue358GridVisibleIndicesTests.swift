import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

@MainActor private final class Issue358Trace: GridThumbnailTracing {
    var ends: [Int] = []
    func firstThumbnailsBegin(generation: UInt64, items: Int) {}
    func firstThumbnailsEnd(generation: UInt64, outcome: GridFirstThumbnailsOutcome, visible: Int, shown: Int, failed: Int) {
        ends.append(visible)
    }
}

@MainActor private final class Issue358MixedLayout: NSCollectionViewFlowLayout {
    var inject = false
    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard inject else { return super.layoutAttributesForElements(in: rect) ?? [] }
        let item = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: 0, section: 0))
        item.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        let supplementary = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: "issue358", with: IndexPath(item: 999, section: 0))
        supplementary.frame = item.frame
        return [item, supplementary]
    }
}

@Test @MainActor func issue358GridVisibleIndicesIgnoreSupplementaryAttributes() {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/issue358-grid")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let entry = FolderEntry(url: folder.appendingPathComponent("A.jpg"), root: root)
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
    let trace = Issue358Trace()
    grid.thumbnailTrace = trace
    grid.display(FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1), entries: [entry], isComplete: true), selectedItemID: nil)
    let layout = Issue358MixedLayout()
    grid.collectionView.collectionViewLayout = layout
    layout.inject = true
    grid.stopThumbnails()
    #expect(trace.ends == [1], "only the item attribute belongs to the visible item set")
}
