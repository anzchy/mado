import AppKit
import Testing
import MadoCore
@testable import MadoMacUI

private func coverageSnapshot(count: Int) -> FolderSnapshot {
    let folder = URL(fileURLWithPath: "/tmp/grid-thumbnail-coverage")
    let rootID = AccessRootID(rawValue: UUID())
    let root = ItemIdentityRoot(id: rootID, url: folder)
    return FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: (0..<count).map { FolderEntry(url: folder.appendingPathComponent("\($0).jpg"), root: root) }, isComplete: true)
}

/// A decoded thumbnail whose request edge and pixels follow `edge`, from an upright source of `source` pixels.
private func coverageDecoded(_ entry: FolderEntry, edge: Int, source: CGSize) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 1, modificationDate: nil), maximumPixelSize: edge)
    let request = ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key)
    let long = max(source.width, source.height)
    let width = max(1, Int(Double(edge) * source.width / long)), height = max(1, Int(Double(edge) * source.height / long))
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return (request, DecodedImage(image: context.makeImage()!, sourcePixelSize: source, revision: key.revision, itemID: entry.itemID))
}

private actor CoverageLog {
    private(set) var seen: [ThumbnailCoverage] = []
    func add(_ coverage: ThumbnailCoverage) { seen.append(coverage) }
}

// #161: the grid passes its tile to the loader and accepts the source-ratio edge, not only the 2× fallback.
@Test(.timeLimit(.minutes(2))) @MainActor func gridThumbnailAcceptsAspectEdgeAndRejectsOtherEdges() async {
    let snapshot = coverageSnapshot(count: 5)
    let tile = ThumbnailCoverage(width: 424, height: 296)
    // 0: 3:2 at 444; 1: portrait at 636; 2: orientation-6 upright 128×96 at its edge; 3: fallback; 4: neither.
    let sources = [CGSize(width: 600, height: 400), CGSize(width: 800, height: 1200), CGSize(width: 128, height: 96),
                   CGSize(width: 600, height: 400), CGSize(width: 600, height: 400)]
    let edges = [444, 636, tile.edge(sourceWidth: 128, sourceHeight: 96), 848, 500]
    let log = CoverageLog()
    let scheduler = GridThumbnailScheduler()
    scheduler.setSnapshot(snapshot)
    var failures: Set<Int> = []
    scheduler.onFailure = { failures.insert($0) }
    let indexByID = Dictionary(uniqueKeysWithValues: snapshot.navigationEntries.enumerated().map { ($1.itemID, $0) })
    scheduler.reconcile(visible: Set(0..<5), columns: 5, coverage: tile, loader: { entry, _, coverage, _ in
        await log.add(coverage)
        let index = indexByID[entry.itemID]!
        return coverageDecoded(entry, edge: edges[index], source: sources[index])
    })
    for index in 0..<5 { await scheduler.waitForTerminal(at: index) }
    let seen = await log.seen
    #expect(seen.count >= 5 && seen.allSatisfy { $0 == tile })
    for index in 0..<4 { #expect(scheduler.result(at: index)?.0.maximumPixelSize == edges[index], "index \(index)") }
    #expect(scheduler.result(at: 4) == nil)
    #expect(failures == [4])
    scheduler.stop()
}

@Test(.timeLimit(.minutes(2))) @MainActor func gridCellInstallsAspectEdgeWithinCeilingOnly() {
    _ = NSApplication.shared
    let entry = coverageSnapshot(count: 1).navigationEntries[0]
    let cell = GridPhotoItem()
    cell.configure(entry)
    cell.beginThumbnail(generation: 1, pixelEdge: 848)
    let over = coverageDecoded(entry, edge: 1025, source: CGSize(width: 2000, height: 100))
    #expect(!cell.installThumbnail(over.0, image: over.1, token: cell.thumbnailToken, generation: 1, pixelEdge: 848))
    let aspect = coverageDecoded(entry, edge: 444, source: CGSize(width: 600, height: 400))
    #expect(cell.installThumbnail(aspect.0, image: aspect.1, token: cell.thumbnailToken, generation: 1, pixelEdge: 848))
    #expect(cell.tileLayer?.contents != nil)
}
