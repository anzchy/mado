import AppKit
import Testing
import PicseeCore
@testable import PicseeMacUI

// #146 (P3-08) AC-1, automated half: S2-sized (5,000 items) fast scroll with thumbnails arriving late, out of order and
// sometimes for the wrong item; no cell may ever show another item's thumbnail. Synthetic entries, no disk: this proves
// the Grid's binding and the scheduler's identity checks, not S2 decode throughput.

private let s2Count = 5_000
private let s2RootID = AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000146")!)

/// The item number in RGB (24 bits), opaque; the check decodes pixels, not object identity. A wrong-edge answer is
/// 2 px wide, so an installed one is visible even though it fits under any edge.
private func indexPixel(_ index: Int, wide: Bool = false) -> CGImage {
    let pixel = [UInt8((index >> 16) & 0xFF), UInt8((index >> 8) & 0xFF), UInt8(index & 0xFF), 255]
    let data = Data(wide ? pixel + pixel : pixel)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(width: wide ? 2 : 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: wide ? 8 : 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

/// The item number an installed image encodes; nil for anything this test did not make as a right-edge answer.
private func decodedIndex(_ contents: Any) -> Int? {
    guard CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
    let image = contents as! CGImage
    guard image.width == 1, let data = image.dataProvider?.data as Data?, data.count >= 4 else { return nil }
    return Int(data[0]) << 16 | Int(data[1]) << 8 | Int(data[2])
}

/// An honest (request, image) pair for `entry` at `edge`; `index` is what its pixel encodes.
private func s2Response(_ entry: FolderEntry, index: Int, edge: Int, wide: Bool = false) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 146, modificationDate: nil), maximumPixelSize: edge)
    let request = ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key)
    let image = DecodedImage(image: indexPixel(index, wide: wide), sourcePixelSize: CGSize(width: 1, height: 1),
        revision: key.revision, itemID: entry.itemID)
    return (request, image)
}

/// Every thumbnail request parks here until the test answers it, in an order the test chooses.
private actor ParkedThumbnailLoads {
    struct Parked: Sendable {
        /// The item's number in the first (name) order; the pixel encodes this.
        let index: Int
        let edge: Int
        let sequence: Int
        let continuation: CheckedContinuation<(ImageDecodeRequest, DecodedImage), Never>
    }
    private var parked: [Parked] = []
    private(set) var requested = 0
    private(set) var everRequested: Set<Int> = []
    private var latest: [Int: Int] = [:]
    func park(index: Int, edge: Int) async -> (ImageDecodeRequest, DecodedImage) {
        await withCheckedContinuation { continuation in
            requested += 1
            latest[index] = requested
            everRequested.insert(index)
            parked.append(Parked(index: index, edge: edge, sequence: requested, continuation: continuation))
        }
    }
    /// The newest request for its item: the one a live record is waiting on (older ones belong to dropped records).
    func isLatest(_ parked: Parked) -> Bool { latest[parked.index] == parked.sequence }
    /// Removes up to `count` parked requests at the given random positions.
    func take(_ count: Int, seed: UInt64) -> [Parked] {
        var generator = SplitMix64(seed: seed)
        var taken: [Parked] = []
        while taken.count < count, !parked.isEmpty {
            taken.append(parked.remove(at: Int.random(in: 0..<parked.count, using: &generator)))
        }
        return taken
    }
    func takeAll() -> [Parked] { defer { parked.removeAll() }; return parked }
    func parkedIndices() -> Set<Int> { Set(parked.map(\.index)) }
    func liveFlags(_ batch: [Parked]) -> [Bool] { batch.map(isLatest) }
}

@MainActor private final class IdentityAudit {
    var checkedWithImage = 0
    var mismatches: [String] = []
    var regionsWithImages: Set<Int> = []
    let number: [ItemID: Int]
    init(number: [ItemID: Int]) { self.number = number }
    func run(_ grid: GridBrowserView, phase: String) {
        for case let item as GridPhotoItem in grid.collectionView.visibleItems() {
            guard let path = grid.collectionView.indexPath(for: item) else { continue }
            if item.representedItemID != grid.itemID(at: path.item) {
                mismatches.append("\(phase): cell at \(path.item) represents another item")
            }
            guard let contents = item.tileLayer?.contents else { continue }
            checkedWithImage += 1
            regionsWithImages.insert(path.item / 500)
            let shown = decodedIndex(contents)
            let own = item.representedItemID.flatMap { number[$0] }
            if shown == nil || shown != own, mismatches.count < 50 {
                mismatches.append("\(phase): cell \(path.item) (item \(own.map(String.init) ?? "?")) shows "
                    + (shown.map { "item \($0)" } ?? "a wrong-edge or foreign image"))
            }
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FastScrollNeverShowsAnotherItemsThumbnail() async throws {
    _ = NSApplication.shared
    let folder = URL(fileURLWithPath: "/tmp/picsee-s2-fast-scroll")
    let root = ItemIdentityRoot(id: s2RootID, url: folder)
    let entries = (0..<s2Count).map { FolderEntry(url: folder.appendingPathComponent(String(format: "IMG_%05d.jpg", $0)), root: root) }
    let indexByID = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.itemID, $0.offset) })
    let snapshot = FolderSnapshot(version: .init(rootID: s2RootID, folder: folder, generation: 1), entries: entries, isComplete: true)

    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 900, height: 640))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    defer { grid.stopThumbnails(); window.close() }
    window.contentView = grid
    let loads = ParkedThumbnailLoads()
    grid.thumbnailLoader = { entry, _, coverage, _ in
        await loads.park(index: indexByID[entry.itemID]!, edge: coverage.fallbackEdge)
    }
    grid.display(snapshot, selectedItemID: nil)
    grid.setThumbnailsActive(true)
    grid.layoutSubtreeIfNeeded()
    #expect(grid.displayedItemIDs.count == s2Count)

    let audit = IdentityAudit(number: indexByID)
    var wrongItemAnswers = 0, wrongEdgeAnswers = 0, lateAnswers = 0, correctAnswers = 0
    var liveWrongItemAnswers = 0, liveWrongEdgeAnswers = 0
    var liveWrongItems: Set<ItemID> = []
    var answerSeed: UInt64 = 0x146
    func visibleIndices() -> Set<Int> {
        Set(grid.collectionView.visibleItems().compactMap { grid.collectionView.indexPath(for: $0)?.item })
    }
    /// Item numbers of the visible cells, whatever order the grid shows now.
    func visibleItems() -> Set<Int> { Set(visibleIndices().compactMap { grid.itemID(at: $0).flatMap { indexByID[$0] } }) }
    /// Answers parked requests: mostly correct, some for a different item, some at the wrong edge. A request whose cell
    /// is no longer visible is a late answer.
    func answer(_ batch: [ParkedThumbnailLoads.Parked]) async {
        let visible = visibleItems()
        let live = await loads.liveFlags(batch)
        for (parked, isLatest) in zip(batch, live) {
            var generator = SplitMix64(seed: answerSeed); answerSeed &+= 1
            let roll = Int.random(in: 0..<20, using: &generator)
            // Live: the newest request for a visible item, so its record is still waiting and the identity checks run.
            let isLive = isLatest && visible.contains(parked.index)
            if !visible.contains(parked.index) { lateAnswers += 1 }
            if roll < 3 {
                let other = (parked.index + Int.random(in: 1..<s2Count, using: &generator)) % s2Count
                wrongItemAnswers += 1
                if isLive { liveWrongItemAnswers += 1; liveWrongItems.insert(entries[parked.index].itemID) }
                parked.continuation.resume(returning: s2Response(entries[other], index: other, edge: parked.edge))
            } else if roll < 5 {
                wrongEdgeAnswers += 1
                if isLive { liveWrongEdgeAnswers += 1 }
                parked.continuation.resume(returning: s2Response(entries[parked.index], index: parked.index,
                    edge: max(1, parked.edge / 2), wide: true))
            } else {
                correctAnswers += 1
                parked.continuation.resume(returning: s2Response(entries[parked.index], index: parked.index, edge: parked.edge))
            }
        }
    }
    func settle(_ phase: String) async {
        for turn in 0..<12 {
            await Task.yield()
            audit.run(grid, phase: "\(phase) yield \(turn)")
        }
    }
    func scroll(to y: CGFloat, _ phase: String) {
        let maximum = max(0, grid.collectionView.frame.height - grid.bounds.height)
        grid.restoreContentOffset(NSPoint(x: 0, y: min(max(0, y), maximum)))
        grid.layoutSubtreeIfNeeded()
        grid.collectionView.layoutSubtreeIfNeeded()
        audit.run(grid, phase: phase)
    }

    // Fast scroll: jumps across the whole grid, single-row nudges and reversals; answers trickle in late and shuffled.
    let height = grid.collectionView.frame.height
    var path: [CGFloat] = [0, 0.97, 0.5, 0.02, 0.75, 0.25, 1.0, 0.33, 0.66, 0.1].map { height * $0 }
    var nudge = height * 0.4
    for _ in 0..<30 { nudge += [-120, 90, 240, -60, 30][path.count % 5]; path.append(nudge) }
    var failedLiveWrongItems = 0
    func countFailures() {
        for case let item as GridPhotoItem in grid.collectionView.visibleItems()
        where item.representedItemID.map(liveWrongItems.contains) == true && item.thumbnailFailed {
            failedLiveWrongItems += 1
        }
    }
    for (step, y) in path.enumerated() {
        scroll(to: y, "scroll \(step)")
        await answer(await loads.take(6, seed: UInt64(step) &+ 0x5EED))
        await settle("scroll \(step)")
        countFailures()
        // Halfway, the folder is re-sorted (reverse name order, next generation): late answers for the old order
        // arrive after it and must not land by position.
        if step == path.count / 2 {
            let resorted = FolderSnapshot(version: .init(rootID: s2RootID, folder: folder, generation: 2),
                entries: entries.reversed(), isComplete: true)
            grid.display(resorted, selectedItemID: nil)
            grid.layoutSubtreeIfNeeded()
            audit.run(grid, phase: "re-sorted")
        }
    }
    // Everything still parked is now late for most cells; answer it in shuffled order while nudging.
    for step in 0..<8 {
        scroll(to: height * 0.33 + CGFloat(step * 37), "drain \(step)")
        await answer(await loads.take(40, seed: UInt64(step) &+ 0xD7A1))
        await settle("drain \(step)")
    }
    await answer(await loads.takeAll())
    await settle("drained")
    countFailures()

    // At rest in a region never requested before (so no adversarial answer reached it): every visible cell ends up
    // showing its own thumbnail.
    scroll(to: height * 0.12, "rest")
    let resting = visibleIndices()
    let restingItems = visibleItems()
    try #require(!resting.isEmpty)
    let before = await loads.everRequested
    await waitUntil { await loads.parkedIndices().isSuperset(of: restingItems) }
    #expect(before.isDisjoint(with: restingItems), "the resting region was requested before: \(before.intersection(restingItems).sorted().prefix(5))")
    for parked in await loads.takeAll() {
        correctAnswers += 1
        parked.continuation.resume(returning: s2Response(entries[parked.index], index: parked.index, edge: parked.edge))
    }
    for index in resting { await grid.waitForThumbnail(at: index) }
    await settle("rest")
    for case let item as GridPhotoItem in grid.collectionView.visibleItems() {
        guard let index = grid.collectionView.indexPath(for: item)?.item, resting.contains(index) else { continue }
        let shown = item.tileLayer?.contents.flatMap(decodedIndex)
        let own = item.representedItemID.flatMap { indexByID[$0] }
        #expect(own != nil && shown == own, "resting cell \(index) (item \(own.map(String.init) ?? "?")) shows \(shown.map(String.init) ?? "nothing")")
    }

    #expect(audit.mismatches.isEmpty, "\(audit.mismatches.count) mismatches: \(audit.mismatches.prefix(10))")
    #expect(wrongItemAnswers > 0 && wrongEdgeAnswers > 0 && lateAnswers > 0 && correctAnswers > 0,
            "answers wrong-item \(wrongItemAnswers) wrong-edge \(wrongEdgeAnswers) late \(lateAnswers) correct \(correctAnswers)")
    #expect(liveWrongItemAnswers > 0 && liveWrongEdgeAnswers > 0,
            "wrong answers that reached a waiting record: item \(liveWrongItemAnswers) edge \(liveWrongEdgeAnswers)")
    #expect(failedLiveWrongItems > 0, "no cell given a live wrong-item answer was seen marked unavailable")
    #expect(audit.checkedWithImage >= 300, "only \(audit.checkedWithImage) cell checks saw an image")
    #expect(audit.regionsWithImages.count >= 3, "images seen in only \(audit.regionsWithImages.sorted()) of the 10 regions")
    let requested = await loads.requested
    #expect(requested > 200, "only \(requested) requests: the scroll did not reach enough cells")
    scroll(to: height, "end")
    #expect(visibleIndices().contains(s2Count - 1), "the last of 5,000 items is not reachable")
}
