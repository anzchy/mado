import AppKit
import Testing
import MadoCore
@testable import MadoInfrastructure
@testable import MadoMacUI

/// Records every pin and unpin in arrival order; a key's count may never go below zero.
actor RecordingPinning: ImagePresentationPinning {
    private(set) var log: [(pin: Bool, key: RenderKey)] = []
    private(set) var counts: [RenderKey: Int] = [:]
    private(set) var wentNegative = false
    private var nextWaiterID = 0
    private var heldWaiters: [Int: (target: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    @discardableResult func pin(_ key: RenderKey, image: DecodedImage) -> Bool {
        log.append((true, key)); counts[key, default: 0] += 1
        notifyHeldWaiters()
        return true
    }
    func unpin(_ key: RenderKey) {
        log.append((false, key)); counts[key, default: 0] -= 1
        if counts[key]! < 0 { wentNegative = true }
        notifyHeldWaiters()
    }
    func pins(_ key: RenderKey) -> Int { log.filter { $0.pin && $0.key == key }.count }
    func unpins(_ key: RenderKey) -> Int { log.filter { !$0.pin && $0.key == key }.count }
    /// True when every unpin of the key follows a pin of it.
    func ordered(_ key: RenderKey) -> Bool {
        var held = 0
        for event in log where event.key == key {
            held += event.pin ? 1 : -1
            if held < 0 { return false }
        }
        return true
    }
    var held: Int { counts.values.reduce(0, +) }
    func waitUntilHeld(_ target: Int) async {
        if held == target { return }
        let id = nextWaiterID
        nextWaiterID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { heldWaiters[id] = (target, $0) }
        } onCancel: {
            Task { await self.cancelHeldWaiter(id) }
        }
    }
    private func notifyHeldWaiters() {
        let ready = heldWaiters.filter { $0.value.target == held }.map(\.key)
        for id in ready { heldWaiters.removeValue(forKey: id)?.continuation.resume() }
    }
    private func cancelHeldWaiter(_ id: Int) { heldWaiters.removeValue(forKey: id)?.continuation.resume() }
}

func pinningSnapshot(count: Int, folder: URL = URL(fileURLWithPath: "/tmp/grid-thumbnail-pinning"),
                     rootID: AccessRootID = AccessRootID(rawValue: UUID()), names: [String]? = nil) -> FolderSnapshot {
    let root = ItemIdentityRoot(id: rootID, url: folder)
    let files = names ?? (0..<count).map { String(format: "%04d.png", $0) }
    return FolderSnapshot(version: .init(rootID: rootID, folder: folder, generation: 1),
        entries: files.map { FolderEntry(url: folder.appendingPathComponent($0), root: root) }, isComplete: true)
}

private func pinningKey(_ entry: FolderEntry, edge: Int) -> RenderKey {
    RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 3, modificationDate: nil), maximumPixelSize: edge)
}

private let pinningLoader: GridThumbnailScheduler.Loader = { entry, _, coverage, _ in
    let key = pinningKey(entry, edge: coverage.fallbackEdge)
    let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return (ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: key.maximumPixelSize, renderKey: key),
            DecodedImage(image: context.makeImage()!, sourcePixelSize: CGSize(width: 1, height: 1), revision: key.revision, itemID: entry.itemID))
}

private let pinningTile = ThumbnailCoverage(width: 212, height: 212)

@MainActor private func loaded(_ scheduler: GridThumbnailScheduler, _ indices: ClosedRange<Int>) async {
    for index in indices { await scheduler.waitForTerminal(at: index) }
}

@Suite(.timeLimit(.minutes(2))) @MainActor struct GridThumbnailPinningTests {
    // 3.1, 3.2: each held result is pinned once, unpinned once when it leaves, and nothing stays pinned after stop.
    @Test func gridPinsHeldResultsAndUnpinsThemOnScrollAndStop() async {
        let snapshot = pinningSnapshot(count: 20), fake = RecordingPinning()
        let scheduler = GridThumbnailScheduler()
        scheduler.pinning = fake
        scheduler.setSnapshot(snapshot)
        scheduler.reconcile(visible: [0, 1], columns: 1, coverage: pinningTile, loader: pinningLoader)
        await loaded(scheduler, 0...3)
        await scheduler.settlePins()
        let keys = snapshot.navigationEntries.map { pinningKey($0, edge: pinningTile.fallbackEdge) }
        for index in 0...3 { #expect(await fake.pins(keys[index]) == 1, "pin \(index)") }
        scheduler.reconcile(visible: [10], columns: 1, coverage: pinningTile, loader: pinningLoader)
        await loaded(scheduler, 8...12)
        await scheduler.settlePins()
        for index in 0...3 {
            #expect(await fake.unpins(keys[index]) == 1, "unpin \(index)")
            #expect(await fake.ordered(keys[index]))
        }
        for index in 8...12 { #expect(await fake.counts[keys[index]] == 1, "held \(index)") }
        #expect(await fake.held == 5)
        scheduler.stop()
        await scheduler.settlePins()
        #expect(await fake.held == 0)
        #expect(await !fake.wentNegative)
    }

    // 3.3: a folder change or a new tile size releases every held result once.
    @Test func gridUnpinsOnFolderAndTileChanges() async {
        let fake = RecordingPinning(), scheduler = GridThumbnailScheduler()
        scheduler.pinning = fake
        scheduler.setSnapshot(pinningSnapshot(count: 4))
        scheduler.reconcile(visible: [0, 1], columns: 2, coverage: pinningTile, loader: pinningLoader)
        await loaded(scheduler, 0...3)
        await scheduler.settlePins()
        #expect(await fake.held == 4)
        let bigger = ThumbnailCoverage(width: 300, height: 300)
        scheduler.reconcile(visible: [0, 1], columns: 2, coverage: bigger, loader: pinningLoader)
        await loaded(scheduler, 0...3)
        await scheduler.settlePins()
        #expect(await fake.held == 4)
        #expect(await fake.log.filter { !$0.pin }.count == 4)
        scheduler.setSnapshot(pinningSnapshot(count: 4))
        await scheduler.settlePins()
        #expect(await fake.held == 0)
        #expect(await !fake.wentNegative)
    }

    // 3.4: a scheduler released while holding results unpins them.
    @Test func gridUnpinsWhenTheSchedulerGoesAway() async throws {
        let fake = RecordingPinning()
        do {
            let scheduler = GridThumbnailScheduler()
            scheduler.pinning = fake
            scheduler.setSnapshot(pinningSnapshot(count: 3))
            scheduler.reconcile(visible: [0, 1, 2], columns: 3, coverage: pinningTile, loader: pinningLoader)
            await loaded(scheduler, 0...2)
            await scheduler.settlePins()
            #expect(await fake.held == 3)
        }
        try await waitUntil { await fake.held == 0 }
        #expect(await fake.held == 0)
        #expect(await !fake.wentNegative)
    }

    // 3.7: results accepted and dropped in quick succession never unpin before their pin.
    @Test func gridPinOrderSurvivesRapidScrolling() async {
        let snapshot = pinningSnapshot(count: 60), fake = RecordingPinning()
        let scheduler = GridThumbnailScheduler()
        scheduler.pinning = fake
        scheduler.setSnapshot(snapshot)
        for step in 0..<100 {
            let first = (step * 7) % 55
            scheduler.reconcile(visible: [first], columns: 1, coverage: pinningTile, loader: pinningLoader)
            if step % 3 == 0 { await scheduler.waitForTerminal(at: first) }
        }
        scheduler.stop()
        await scheduler.settlePins()
        #expect(await fake.held == 0)
        #expect(await !fake.wentNegative)
        #expect(await fake.log.contains { $0.pin })
    }
}

/// Real pipeline: two windows (schedulers) on one cache, real pixels in a temporary folder.
@Suite(.timeLimit(.minutes(2))) @MainActor struct GridSharedBudgetTests {
    static func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TestAssets/synthetic/\(name)")
    }
    static func folder(copies: Int) throws -> (URL, [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = (0..<copies).map { String(format: "%02d.png", $0) }
        for name in names { try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: folder.appendingPathComponent(name)) }
        return (folder, names)
    }
    static func loader(_ pipeline: ImageIOPipeline, root: ItemIdentityRoot) -> GridThumbnailScheduler.Loader {
        { entry, _, coverage, priority in
            let prepared = try await pipeline.request(for: entry.url, covering: coverage, identityRoot: root)
            let image = try await pipeline.image(for: ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: prepared.maximumPixelSize,
                renderKey: prepared.renderKey, priority: priority, identityRoot: root))
            return (prepared, image)
        }
    }

    // 3.5, 3.5b: overlapping windows; closing A releases exactly A's exclusive share and keeps the shared result.
    @Test func closingOneWindowReleasesOnlyItsExclusiveShare() async throws {
        let (folder, names) = try Self.folder(copies: 12)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rootID = AccessRootID(rawValue: UUID()), root = ItemIdentityRoot(id: rootID, url: folder)
        let snapshot = pinningSnapshot(count: names.count, folder: folder, rootID: rootID, names: names)
        let pipeline = ImageIOPipeline()
        let budget = try #require(pipeline.cache.budget)
        let tile = ThumbnailCoverage(width: 16, height: 12)
        let a = GridThumbnailScheduler(), b = GridThumbnailScheduler()
        for window in [a, b] { window.pinning = pipeline; window.setSnapshot(snapshot) }
        a.reconcile(visible: [0], columns: 1, coverage: tile, loader: Self.loader(pipeline, root: root))
        b.reconcile(visible: [4], columns: 1, coverage: tile, loader: Self.loader(pipeline, root: root))
        await loaded(a, 0...2); await loaded(b, 2...6)
        await a.settlePins(); await b.settlePins()
        let results = (0...6).map { (a.result(at: $0) ?? b.result(at: $0))! }
        let bytes = results.map { $0.1.image.bytesPerRow * $0.1.image.height }
        #expect(budget.usage.pinned == bytes.reduce(0, +))
        let shared = try #require(results[2].0.renderKey)
        #expect(await pipeline.cache.pinCount(for: shared) == 2)
        a.stop()
        await a.settlePins()
        #expect(budget.usage.pinned == bytes[2...6].reduce(0, +))
        #expect(await pipeline.cache.pinCount(for: shared) == 1)
        #expect(b.result(at: 2)?.1.image === results[2].1.image)
        b.stop()
        await b.settlePins()
        #expect(budget.usage.pinned == 0)
    }

    // 3.6, 3.6b: a request both windows share completes for B after A closes, and nothing A requested stays pinned.
    @Test func closingOneWindowKeepsTheOtherWindowsSharedRequest() async throws {
        let (folder, names) = try Self.folder(copies: 1)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rootID = AccessRootID(rawValue: UUID()), root = ItemIdentityRoot(id: rootID, url: folder)
        let snapshot = pinningSnapshot(count: 1, folder: folder, rootID: rootID, names: names)
        let gate = GatedDecoder()
        defer { gate.open() }
        let pipeline = ImageIOPipeline(decoder: gate)
        let a = GridThumbnailScheduler(), b = GridThumbnailScheduler()
        for window in [a, b] { window.pinning = pipeline; window.setSnapshot(snapshot) }
        var starts = gate.started.makeAsyncIterator()
        a.reconcile(visible: [0], columns: 1, coverage: pinningTile, loader: Self.loader(pipeline, root: root))
        _ = await starts.next()
        b.reconcile(visible: [0], columns: 1, coverage: pinningTile, loader: Self.loader(pipeline, root: root))
        a.stop()
        gate.open()
        await b.waitForTerminal(at: 0)
        await a.settlePins(); await b.settlePins()
        let key = try #require(b.result(at: 0)?.0.renderKey)
        #expect(await pipeline.cache.pinCount(for: key) == 1)
        b.stop()
        await b.settlePins()
        #expect(await pipeline.cache.pinCount(for: key) == 0)
        #expect(try #require(pipeline.cache.budget).usage.pinned == 0)
    }
}

/// Holds every decode until `open()`; reports each start.
final class GatedDecoder: ImageDecoding, @unchecked Sendable {
    let started: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let lock = NSCondition()
    private var isOpen = false
    init() { (started, signal) = AsyncStream.makeStream() }
    func open() { lock.lock(); isOpen = true; lock.broadcast(); lock.unlock() }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        signal.yield(())
        lock.lock(); while !isOpen { lock.wait() }; lock.unlock()
        return try ImageIODecoder().decode(request)
    }
}

// The view hands its pinning to its scheduler: loaded cells are pinned, stopping releases them.
// AppKit layout and main-actor delivery may queue behind the concurrent package suite on CI.
@Test(.timeLimit(.minutes(3))) @MainActor func gridViewPinsLoadedThumbnailsUntilStopped() async throws {
    _ = NSApplication.shared
    let snapshot = pinningSnapshot(count: 3), fake = RecordingPinning()
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: grid.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = grid
    grid.thumbnailPinning = fake
    #expect(grid.thumbnailPinning != nil)
    grid.thumbnailPrefetchResumption = GatedResumption()
    #expect(grid.thumbnailPrefetchResumption != nil)
    grid.thumbnailLoader = pinningLoader
    grid.display(snapshot, selectedItemID: nil)
    window.layoutIfNeeded()
    grid.layoutSubtreeIfNeeded()
    grid.setThumbnailsActive(true)
    for index in 0..<3 { await grid.waitForThumbnail(at: index) }
    await fake.waitUntilHeld(3)
    #expect(await fake.held == 3)
    grid.stopThumbnails()
    await fake.waitUntilHeld(0)
    #expect(await fake.held == 0)
    #expect(await !fake.wentNegative)
}
