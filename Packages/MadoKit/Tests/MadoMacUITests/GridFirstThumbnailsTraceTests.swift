import AppKit
import Testing
import MadoCore
import MadoApplication
@testable import MadoMacUI

// #146 (P3-08) AC-2 boundary: the GridFirstThumbnails interval runs from the display of a complete snapshot to the
// first moment every visible cell is terminal (thumbnail or failure). Folder open → complete Grid is FolderScan begin
// → this end, paired by generation (scripts/perf/p308-parse.mjs).

private let traceRootID = AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000001461")!)
private let traceFolder = URL(fileURLWithPath: "/tmp/mado-grid-first-thumbnails")

private func traceEntries(_ count: Int, prefix: String = "T") -> [FolderEntry] {
    let root = ItemIdentityRoot(id: traceRootID, url: traceFolder)
    return (0..<count).map { FolderEntry(url: traceFolder.appendingPathComponent(String(format: "\(prefix)%03d.jpg", $0)), root: root) }
}

private func traceSnapshot(_ entries: [FolderEntry], generation: UInt64, complete: Bool = true) -> FolderSnapshot {
    FolderSnapshot(version: .init(rootID: traceRootID, folder: traceFolder, generation: generation),
        entries: complete ? entries : [], isComplete: complete)
}

private func tracePixel() -> CGImage {
    let provider = CGDataProvider(data: Data([9, 9, 9, 255]) as CFData)!
    return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

private func traceResponse(_ entry: FolderEntry, edge: Int) -> (ImageDecodeRequest, DecodedImage) {
    let key = RenderKey(itemID: entry.itemID, revision: FileRevision(byteCount: 1461, modificationDate: nil), maximumPixelSize: edge)
    return (ImageDecodeRequest(fileURL: entry.url, maximumPixelSize: edge, renderKey: key),
            DecodedImage(image: tracePixel(), sourcePixelSize: CGSize(width: 1, height: 1), revision: key.revision, itemID: entry.itemID))
}

/// Holds each request until the test answers it with a thumbnail or a failure.
private actor HeldTraceLoads {
    private var held: [ItemID: [(FolderEntry, Int, CheckedContinuation<(ImageDecodeRequest, DecodedImage), any Error>)]] = [:]
    private var sourceChangedOnce: Set<ItemID> = []
    private(set) var calls: [ItemID: Int] = [:]
    func throwSourceChangedOnce(_ id: ItemID) { sourceChangedOnce.insert(id) }
    func load(_ entry: FolderEntry, edge: Int) async throws -> (ImageDecodeRequest, DecodedImage) {
        calls[entry.itemID, default: 0] += 1
        if sourceChangedOnce.remove(entry.itemID) != nil {
            throw ImageLoadError(.sourceChanged, itemID: entry.itemID)
        }
        return try await withCheckedThrowingContinuation { continuation in
            held[entry.itemID, default: []].append((entry, edge, continuation))
        }
    }
    var heldIDs: Set<ItemID> { Set(held.keys) }
    func release(_ id: ItemID) {
        for (entry, edge, continuation) in held.removeValue(forKey: id) ?? [] {
            continuation.resume(returning: traceResponse(entry, edge: edge))
        }
    }
    func fail(_ id: ItemID) {
        for request in held.removeValue(forKey: id) ?? [] {
            request.2.resume(throwing: ImageLoadError(.corruptImage, itemID: id))
        }
    }
    func releaseAll() { for id in Array(held.keys) { release(id) } }
}

@MainActor final class RecordingGridTrace: GridThumbnailTracing {
    enum Event: Equatable, CustomStringConvertible {
        case begin(UInt64, items: Int)
        case end(UInt64, GridFirstThumbnailsOutcome, visible: Int, shown: Int, failed: Int)
        var description: String {
            switch self {
            case let .begin(g, items): "begin(\(g), items \(items))"
            case let .end(g, outcome, visible, shown, failed): "end(\(g), \(outcome), v\(visible) s\(shown) f\(failed))"
            }
        }
    }
    var events: [Event] = []
    func firstThumbnailsBegin(generation: UInt64, items: Int) { events.append(.begin(generation, items: items)) }
    func firstThumbnailsEnd(generation: UInt64, outcome: GridFirstThumbnailsOutcome, visible: Int, shown: Int, failed: Int) {
        events.append(.end(generation, outcome, visible: visible, shown: shown, failed: failed))
    }
}

/// A grid in a window with an injected trace and held loader; `attach: false` keeps it out of any window.
@MainActor private final class TraceGrid {
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 700, height: 550))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 550), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let trace = RecordingGridTrace()
    let loads = HeldTraceLoads()
    let entries: [FolderEntry]
    init(count: Int = 80, attach: Bool = true) {
        _ = NSApplication.shared
        entries = traceEntries(count)
        window.isReleasedWhenClosed = false
        grid.thumbnailTrace = trace
        let loads = loads
        grid.thumbnailLoader = { entry, _, coverage, _ in try await loads.load(entry, edge: coverage.fallbackEdge) }
        if attach { self.attach() }
    }
    func attach() { window.contentView = grid; grid.layoutSubtreeIfNeeded() }
    func close() { grid.stopThumbnails(); window.close() }
    func show(generation: UInt64 = 1, active: Bool = true) {
        grid.display(traceSnapshot(entries, generation: generation), selectedItemID: nil)
        if active { grid.setThumbnailsActive(true) }
        grid.layoutSubtreeIfNeeded()
    }
    /// The same rule the grid uses: items whose layout frame meets the visible rect.
    var visible: [Int] {
        grid.collectionView.collectionViewLayout!.layoutAttributesForElements(in: grid.collectionView.visibleRect)
            .compactMap { $0.representedElementCategory == .item ? $0.indexPath?.item : nil }.sorted()
    }
    func id(_ index: Int) -> ItemID { entries[index].itemID }
    /// Answers whatever is parked for these cells until each is terminal; cancellable by the test's time limit.
    func release(_ indices: [Int]) async throws {
        try await waitUntil {
            var done = true
            for index in indices where !grid.thumbnailIsTerminal(at: index) {
                done = false
                await loads.release(id(index))
            }
            return done
        }
    }
    func fail(_ index: Int) async throws {
        try await waitUntil {
            if grid.thumbnailIsTerminal(at: index) { return true }
            await loads.fail(id(index))
            return false
        }
    }
    var ends: [RecordingGridTrace.Event] { trace.events.filter { if case .end = $0 { true } else { false } } }
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsEndsWhenEveryVisibleCellIsTerminal() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.show()
    let visible = fixture.visible
    try #require(visible.count >= 4 && visible.count < fixture.entries.count)
    #expect(fixture.trace.events == [.begin(1, items: 80)])
    try await fixture.release(Array(visible.dropLast()))
    #expect(fixture.ends.isEmpty, "ended before the last visible cell: \(fixture.trace.events)")
    try await fixture.release([visible.last!])
    #expect(fixture.trace.events == [.begin(1, items: 80),
        .end(1, .complete, visible: visible.count, shown: visible.count, failed: 0)], "\(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsCountsAVisibleFailure() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.show()
    let visible = fixture.visible
    try await fixture.fail(visible[1])
    try await fixture.release(visible.filter { $0 != visible[1] })
    #expect(fixture.ends == [.end(1, .complete, visible: visible.count, shown: visible.count - 1, failed: 1)], "\(fixture.trace.events)")
}

/// Prefetch results arriving first must not count toward the visible set.
@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsIgnoresPrefetchResults() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.show()
    let visible = Set(fixture.visible)
    try await waitUntil { await fixture.loads.heldIDs.count > visible.count }
    let held = await fixture.loads.heldIDs
    let prefetch = fixture.entries.indices.filter { held.contains(fixture.id($0)) && !visible.contains($0) }
    try #require(!prefetch.isEmpty, "no prefetch cells were requested")
    try await fixture.release(prefetch)
    #expect(fixture.ends.isEmpty, "prefetch results ended the interval: \(fixture.trace.events)")
    try await fixture.release(visible.sorted())
    #expect(fixture.ends == [.end(1, .complete, visible: visible.count, shown: visible.count, failed: 0)])
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsRetryAfterSourceChangedIsNotAFailure() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    await fixture.loads.throwSourceChangedOnce(fixture.id(0))
    fixture.show()
    let visible = fixture.visible
    try await fixture.release(visible)
    #expect(await fixture.loads.calls[fixture.id(0)] == 2, "the scheduler did not retry once")
    #expect(fixture.ends == [.end(1, .complete, visible: visible.count, shown: visible.count, failed: 0)], "\(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsBeginsOnlyForACompleteSnapshot() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.grid.display(traceSnapshot(fixture.entries, generation: 0, complete: false), selectedItemID: nil)
    fixture.grid.setThumbnailsActive(true)
    #expect(fixture.trace.events.isEmpty, "an incomplete snapshot began an interval")
    fixture.grid.display(traceSnapshot([], generation: 3), selectedItemID: nil)
    #expect(fixture.trace.events == [.begin(3, items: 0), .end(3, .complete, visible: 0, shown: 0, failed: 0)],
            "an empty folder ends at once: \(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsNewGenerationSupersedesOnlyAPendingInterval() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.show(generation: 1)
    let visible = fixture.visible
    try await fixture.release([visible[0]])
    fixture.show(generation: 2)
    #expect(fixture.trace.events == [.begin(1, items: 80),
        .end(1, .superseded, visible: visible.count, shown: 1, failed: 0), .begin(2, items: 80)], "\(fixture.trace.events)")
    try await fixture.release(fixture.visible)
    #expect(fixture.ends.count == 2)
    // After a complete end, the next generation begins without ending the finished one again.
    fixture.show(generation: 3)
    #expect(fixture.trace.events.count == 5 && fixture.trace.events.last == .begin(3, items: 80), "\(fixture.trace.events)")
    #expect(fixture.ends.count == 2, "a finished interval ended twice: \(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsIgnoresRedisplayOfTheSameGeneration() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.show()
    var selection = BrowserSelection()
    selection.click(fixture.id(2), in: fixture.entries.map(\.itemID))
    fixture.grid.display(traceSnapshot(fixture.entries, generation: 1), selection: selection)
    fixture.grid.synchronizeSelection(selection)
    // A filename-search projection keeps the source generation.
    fixture.grid.display(traceSnapshot(Array(fixture.entries.prefix(30)), generation: 1), selection: selection)
    #expect(fixture.trace.events == [.begin(1, items: 80)], "\(fixture.trace.events)")
    try await fixture.release(fixture.visible)
    #expect(fixture.ends.count == 1)
    fixture.grid.restoreContentOffset(NSPoint(x: 0, y: 200))
    fixture.grid.layoutSubtreeIfNeeded()
    try await fixture.release(fixture.visible)
    fixture.grid.display(traceSnapshot(fixture.entries, generation: 1), selection: selection)
    #expect(fixture.trace.events.count == 2, "events after the end: \(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsStopsOnceWhenThumbnailsStop() async throws {
    for clear in [false, true] {
        let fixture = TraceGrid()
        defer { fixture.close() }
        fixture.show()
        let visible = fixture.visible
        if clear { fixture.grid.clearPresentation() } else { fixture.grid.setThumbnailsActive(false) }
        #expect(fixture.ends == [.end(1, .stopped, visible: visible.count, shown: 0, failed: 0)], "clear \(clear): \(fixture.trace.events)")
        await fixture.loads.releaseAll()
        // Returning (from a preview, or after the root comes back) re-displays the same generation and reactivates.
        fixture.show()
        try await fixture.release(fixture.visible)
        #expect(fixture.ends.count == (clear ? 2 : 1), "clear \(clear): \(fixture.trace.events)")
        let begins = fixture.trace.events.count - fixture.ends.count
        // A preview return is not a new folder open; a cleared presentation is.
        #expect(begins == (clear ? 2 : 1), "clear \(clear): \(fixture.trace.events)")
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsReadingResetsTheGeneration() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    fixture.show(generation: 4)
    try await fixture.release(fixture.visible)
    // A new read shows the Reading State (incomplete) and may complete with the same generation number.
    fixture.grid.display(traceSnapshot(fixture.entries, generation: 4, complete: false), selectedItemID: nil)
    fixture.show(generation: 4)
    #expect(fixture.trace.events.filter { $0 == .begin(4, items: 80) }.count == 2, "\(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsWaitsForAWindow() async throws {
    let fixture = TraceGrid(attach: false)
    defer { fixture.close() }
    fixture.show()
    #expect(fixture.trace.events == [.begin(1, items: 80)])
    #expect(await fixture.loads.heldIDs.isEmpty, "requests without a window")
    #expect(fixture.ends.isEmpty, "no window counted as an empty visible set: \(fixture.trace.events)")
    fixture.attach()
    fixture.grid.setThumbnailsActive(true)
    let visible = fixture.visible
    try #require(!visible.isEmpty)
    try await fixture.release(Array(visible.dropLast()))
    #expect(fixture.ends.isEmpty)
    try await fixture.release([visible.last!])
    #expect(fixture.ends == [.end(1, .complete, visible: visible.count, shown: visible.count, failed: 0)], "\(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsWaitsWhileHiddenOrInactive() async throws {
    let fixture = TraceGrid()
    defer { fixture.close() }
    // The Reading State flow: the complete snapshot is displayed while the grid is still hidden and inactive.
    fixture.grid.isHidden = true
    fixture.show(active: false)
    #expect(fixture.trace.events == [.begin(1, items: 80)], "\(fixture.trace.events)")
    fixture.grid.setThumbnailsActive(true)
    fixture.grid.layoutSubtreeIfNeeded()
    #expect(fixture.visible.isEmpty && fixture.ends.isEmpty, "a hidden grid has nothing visible, so it cannot finish")
    fixture.grid.isHidden = false
    fixture.grid.setThumbnailsActive(true)
    fixture.grid.layoutSubtreeIfNeeded()
    let visible = fixture.visible
    try #require(!visible.isEmpty)
    try await fixture.release(Array(visible.dropLast()))
    #expect(fixture.ends.isEmpty)
    try await fixture.release([visible.last!])
    #expect(fixture.trace.events == [.begin(1, items: 80),
        .end(1, .complete, visible: visible.count, shown: visible.count, failed: 0)], "\(fixture.trace.events)")
}

@Test(.timeLimit(.minutes(2))) @MainActor func p308FirstThumbnailsDefaultsToTheSignpostTrace() {
    _ = NSApplication.shared
    let grid = GridBrowserView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    #expect(grid.thumbnailTrace is SignpostGridThumbnailTrace)
    let trace = SignpostGridThumbnailTrace()
    trace.firstThumbnailsEnd(generation: 99, outcome: .complete, visible: 0, shown: 0, failed: 0)
    trace.firstThumbnailsBegin(generation: 7, items: 3)
    trace.firstThumbnailsEnd(generation: 7, outcome: .complete, visible: 1, shown: 1, failed: 0)
    trace.firstThumbnailsEnd(generation: 7, outcome: .complete, visible: 1, shown: 1, failed: 0)
}

/// The exact strings the parser reads, from the one table both sides use.
@Test(.timeLimit(.minutes(2))) func p308FirstThumbnailsMessagesMatchTheSharedTable() throws {
    let table = try p308SignpostMessages()
    #expect(GridFirstThumbnailsMessage.begin(generation: 7, items: 5000) == table["GridFirstThumbnails.begin"])
    #expect(GridFirstThumbnailsMessage.end(generation: 7, outcome: .complete, visible: 24, shown: 23, failed: 1)
            == table["GridFirstThumbnails.end"])
    #expect(GridFirstThumbnailsMessage.end(generation: 1, outcome: .superseded, visible: 0, shown: 0, failed: 0)
            == "outcome=superseded generation=1 visible=0 shown=0 failed=0")
}

/// `scripts/perf/fixtures/signpost-messages.json`, package section.
func p308SignpostMessages(source: String = #filePath) throws -> [String: String] {
    let root = URL(fileURLWithPath: source).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("scripts/perf/fixtures/signpost-messages.json"))
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(object["package"] as? [String: String])
}
