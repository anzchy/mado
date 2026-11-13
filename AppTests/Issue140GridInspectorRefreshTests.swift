import AppKit
import Darwin
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class GridInspectorMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private actor CountingGridInspectorReader: InspectorMetadataReading {
    let base: WindowInspectorReader
    private var reads: [String: Int] = [:]
    init(base: WindowInspectorReader) { self.base = base }
    func read(_ url: URL, access: AccessRequest) async throws -> InspectorMetadata {
        reads[url.standardizedFileURL.path, default: 0] += 1
        Issue140Timing.mark("metadata actor read started")
        let metadata = try await base.read(url, access: access)
        Issue140Timing.mark("metadata actor read finished")
        return metadata
    }
    func count(for url: URL) -> Int { reads[url.standardizedFileURL.path, default: 0] }
}

@MainActor private func gridInspectorFixture(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/\(name)")
}

@MainActor private func gridInspectorMetadata(_ controller: CanvasWindowController) -> InspectorMetadata? {
    if case .known(let metadata) = controller.inspector.value { return metadata }
    return nil
}

private enum Issue140Timing {
    @TaskLocal static var begin: ContinuousClock.Instant?
    static func mark(_ stage: String) {
        guard let begin else { return }
        let elapsed = begin.duration(to: .now)
        let ms = elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000
        print("[i140] grid inspector +\(ms)ms \(stage)")
        fflush(stdout)
    }
}

@MainActor private func waitForGridInspector(_ stage: String, _ condition: () -> Bool) async throws {
    Issue140Timing.mark("waiting for \(stage)")
    var nextProgress = ContinuousClock.now + .seconds(10)
    try await waitUntil(between: {
        if ContinuousClock.now >= nextProgress {
            Issue140Timing.mark("still waiting for \(stage)")
            nextProgress += .seconds(10)
        }
    }) { condition() }
    Issue140Timing.mark("observed \(stage)")
}

@MainActor private func awaitIssue140Refresh(_ refresh: Task<Void, Error>, generation: UInt64) async throws {
    Issue140Timing.mark("waiting for unchanged refresh.value generation=\(generation)")
    let progress = Task {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { Issue140Timing.mark("still waiting for unchanged refresh.value generation=\(generation)") }
        }
    }
    defer { progress.cancel() }
    try await refresh.value
    Issue140Timing.mark("unchanged refresh.value returned generation=\(generation)")
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue140Combo136GridInspectorTracksRevisionsWithoutDuplicateReads() async throws {
    try await Issue140Timing.$begin.withValue(.now) {
        Issue140Timing.mark("test started")
        try await runIssue140Combo136GridInspectorTracksRevisionsWithoutDuplicateReads()
        Issue140Timing.mark("test finished")
    }
}

@MainActor private func runIssue140Combo136GridInspectorTracksRevisionsWithoutDuplicateReads() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let selected = base.appendingPathComponent("03-selected.png")
    let neighbour = base.appendingPathComponent("04-neighbour.png")
    let replacement = base.appendingPathComponent(".replacement.png")
    let renamed = base.appendingPathComponent("03-renamed.png")
    let portrait = try Data(contentsOf: gridInspectorFixture("portrait-2x3.png"))
    let landscape = try Data(contentsOf: gridInspectorFixture("landscape-3x2.png"))
    #expect(portrait.count > landscape.count)
    try portrait.write(to: selected)
    try landscape.write(to: neighbour)
    let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
    try fm.setAttributes([.modificationDate: fixedDate], ofItemAtPath: selected.path)

    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-combo136")
    Issue140Timing.mark("waiting for root grant")
    let root = try await access.grant(folder: base)
    Issue140Timing.mark("root grant finished")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let servicesTask = Task<AccessServices, Error> { services }
    let pipeline = ImageIOPipeline()
    let reader = CountingGridInspectorReader(base: WindowInspectorReader(services: servicesTask, pipeline: pipeline))
    let controller = CanvasWindowController(pipeline: pipeline,
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: servicesTask,
        motionPolicy: MotionPolicy(source: GridInspectorMotionSource()), inspectorReader: reader)
    let window = try #require(controller.window)
    defer { window.close() }
    controller.browseRecoveredFolder(base, rootID: root)
    try await waitForGridInspector("initial scan and grid ready") {
        controller.session.folderScan?.sourceSnapshot?.isComplete == true && controller.gridSearchAvailable
    }
    let initialSnapshot = try #require(controller.session.folderScan?.sourceSnapshot)
    #expect(initialSnapshot.isComplete)
    let initial = try #require(initialSnapshot.entries.first(where: { $0.url.lastPathComponent == selected.lastPathComponent }))
    controller.session.focus(initial.itemID)
    #expect(controller.route(.inspector, from: .key))
    try await waitForGridInspector("initial metadata") { gridInspectorMetadata(controller)?.pixelWidth != nil }
    let initialMetadata = try #require(gridInspectorMetadata(controller))
    #expect(initialMetadata.pixelWidth != initialMetadata.pixelHeight)
    #expect(controller.inspector.name == selected.lastPathComponent)
    #expect(controller.gridSearchAvailable)
    Issue140Timing.mark("waiting for initial read count")
    let initialReads = await reader.count(for: selected)
    Issue140Timing.mark("initial read count returned")
    #expect(initialReads == 1)

    // The replacement changes only the file resource: URL, ItemID, byte size and mtime stay fixed.
    var paddedLandscape = landscape
    paddedLandscape.append(Data(repeating: 0, count: portrait.count - landscape.count))
    try paddedLandscape.write(to: replacement)
    let originalDate = try #require(initial.modificationDate)
    try fm.setAttributes([.modificationDate: originalDate], ofItemAtPath: replacement.path)
    let replaceResult = replacement.path.withCString { from in
        selected.path.withCString { to in Darwin.rename(from, to) }
    }
    #expect(replaceResult == 0)
    Issue140Timing.mark("reconciling after atomic replacement")
    services.watch.reconcileAll()
    try await waitForGridInspector("atomic replacement revision") {
        controller.session.folderScan?.sourceSnapshot?.entries.first(where: { $0.url.lastPathComponent == selected.lastPathComponent })?
            .resourceIdentifier != initial.resourceIdentifier &&
        controller.session.folderScan?.sourceSnapshot?.version.generation != initialSnapshot.version.generation
    }
    let atomic = try #require(controller.session.folderScan?.sourceSnapshot?.entries.first(where: { $0.url.lastPathComponent == selected.lastPathComponent }))
    #expect(atomic.itemID == initial.itemID)
    #expect(atomic.fileSize == initial.fileSize)
    #expect(atomic.modificationDate == initial.modificationDate)
    #expect(atomic.resourceIdentifier != initial.resourceIdentifier)
    try await waitForGridInspector("atomic replacement metadata") {
        guard let metadata = gridInspectorMetadata(controller), let width = metadata.pixelWidth else { return false }
        return width != initialMetadata.pixelWidth
    }
    let atomicMetadata = try #require(gridInspectorMetadata(controller))
    #expect(atomicMetadata.pixelWidth != initialMetadata.pixelWidth)
    #expect(atomicMetadata.pixelHeight != initialMetadata.pixelHeight)
    #expect(controller.inspector.name == selected.lastPathComponent)
    #expect(controller.session.selection.currentItemID == initial.itemID)
    #expect(controller.gridSearchAvailable)
    Issue140Timing.mark("waiting for atomic read count")
    #expect(await reader.count(for: selected) == initialReads + 1)
    Issue140Timing.mark("atomic read count returned")

    // A completed refresh and a change to another file preserve the selected revision and read count.
    Issue140Timing.mark("waiting for stable read count")
    let stableReads = await reader.count(for: selected)
    Issue140Timing.mark("stable read count returned")
    // A refresh that finds the same entries keeps the source snapshot and its generation, so nothing on the
    // snapshot shows it finished (#277). Await this stage's own refresh task instead; a late watch hint that
    // starts a newer refresh cancels it, so repeat until the awaited one is still the latest when it returns.
    let scan = try #require(controller.session.folderScan)
    var unchangedRefresh: UInt64
    repeat {
        Issue140Timing.mark("starting unchanged refresh")
        let refresh = try #require(scan.refresh())
        unchangedRefresh = scan.generation
        try await awaitIssue140Refresh(refresh, generation: unchangedRefresh)
    } while scan.generation != unchangedRefresh && !Task.isCancelled
    controller.applyObservedGridSnapshot(try #require(controller.session.folderScan?.snapshot))
    #expect(gridInspectorMetadata(controller)?.pixelWidth == atomicMetadata.pixelWidth)
    Issue140Timing.mark("waiting for unchanged read count")
    #expect(await reader.count(for: selected) == stableReads)
    Issue140Timing.mark("unchanged read count returned")
    let stableGeneration = try #require(controller.session.folderScan?.sourceSnapshot?.version.generation)
    let anotherNeighbour = base.appendingPathComponent(".neighbour-replacement.png")
    try portrait.write(to: anotherNeighbour)
    let neighbourReplace = anotherNeighbour.path.withCString { from in
        neighbour.path.withCString { to in Darwin.rename(from, to) }
    }
    #expect(neighbourReplace == 0)
    Issue140Timing.mark("reconciling after neighbour replacement")
    services.watch.reconcileAll()
    try await waitForGridInspector("neighbour replacement generation") {
        (controller.session.folderScan?.sourceSnapshot?.version.generation ?? 0) > stableGeneration
    }
    controller.applyObservedGridSnapshot(try #require(controller.session.folderScan?.snapshot))
    #expect(gridInspectorMetadata(controller)?.pixelWidth == atomicMetadata.pixelWidth)
    #expect(controller.inspector.name == selected.lastPathComponent)
    Issue140Timing.mark("waiting for neighbour read count")
    #expect(await reader.count(for: selected) == stableReads)
    Issue140Timing.mark("neighbour read count returned")

    // Write in place: the resource stays, while size and date change with the visible dimensions.
    let beforeInPlace = try #require(controller.session.folderScan?.sourceSnapshot?.entries.first(where: { $0.url.lastPathComponent == selected.lastPathComponent }))
    let handle = try FileHandle(forWritingTo: selected)
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: portrait + Data(repeating: 0, count: 16))
    try handle.close()
    try fm.setAttributes([.modificationDate: originalDate.addingTimeInterval(60)], ofItemAtPath: selected.path)
    let beforeInPlaceGeneration = try #require(controller.session.folderScan?.sourceSnapshot?.version.generation)
    Issue140Timing.mark("reconciling after in-place write")
    services.watch.reconcileAll()
    try await waitForGridInspector("in-place write revision") {
        (controller.session.folderScan?.sourceSnapshot?.version.generation ?? 0) > beforeInPlaceGeneration &&
        controller.session.folderScan?.sourceSnapshot?.entries.first(where: { $0.url.lastPathComponent == selected.lastPathComponent })?.fileSize != beforeInPlace.fileSize
    }
    let inPlace = try #require(controller.session.folderScan?.sourceSnapshot?.entries.first(where: { $0.url.lastPathComponent == selected.lastPathComponent }))
    #expect(inPlace.itemID == initial.itemID)
    #expect(inPlace.resourceIdentifier == beforeInPlace.resourceIdentifier)
    #expect(inPlace.fileSize != beforeInPlace.fileSize)
    #expect(inPlace.modificationDate != beforeInPlace.modificationDate)
    try await waitForGridInspector("in-place write metadata") { gridInspectorMetadata(controller)?.pixelWidth == initialMetadata.pixelWidth }
    let inPlaceMetadata = try #require(gridInspectorMetadata(controller))
    #expect(inPlaceMetadata.pixelWidth == initialMetadata.pixelWidth)
    #expect(inPlaceMetadata.pixelHeight == initialMetadata.pixelHeight)
    Issue140Timing.mark("waiting for in-place read count")
    #expect(await reader.count(for: selected) == stableReads + 1)
    Issue140Timing.mark("in-place read count returned")

    try fm.moveItem(at: selected, to: renamed)
    Issue140Timing.mark("reconciling after rename")
    services.watch.reconcileAll()
    try await waitForGridInspector("renamed inspector title and metadata") {
        controller.inspector.name == renamed.lastPathComponent &&
        gridInspectorMetadata(controller)?.pixelWidth == initialMetadata.pixelWidth
    }
    #expect(controller.inspector.name == renamed.lastPathComponent)
    #expect(gridInspectorMetadata(controller)?.pixelWidth == initialMetadata.pixelWidth)
    #expect(controller.session.selection.currentItemID == initial.itemID)
    #expect(controller.gridSearchAvailable)

    try fm.removeItem(at: renamed)
    Issue140Timing.mark("reconciling after selected deletion")
    services.watch.reconcileAll()
    try await waitForGridInspector("successor inspector title") { controller.inspector.name == neighbour.lastPathComponent }
    #expect(controller.inspector.name == neighbour.lastPathComponent)
    try await waitForGridInspector("successor metadata") {
        gridInspectorMetadata(controller)?.pixelWidth == initialMetadata.pixelWidth &&
        gridInspectorMetadata(controller)?.pixelHeight == initialMetadata.pixelHeight &&
        gridInspectorMetadata(controller)?.byteSize == Int64(portrait.count)
    }
    let successorMetadata = try #require(gridInspectorMetadata(controller))
    #expect(successorMetadata.pixelWidth == initialMetadata.pixelWidth)
    #expect(successorMetadata.pixelHeight == initialMetadata.pixelHeight)
    #expect(successorMetadata.byteSize == Int64(portrait.count))
    #expect(successorMetadata.byteSize != inPlaceMetadata.byteSize)
    #expect(controller.session.selection.currentItemID != initial.itemID)
    #expect(controller.gridSearchAvailable)
    try fm.removeItem(at: neighbour)
    Issue140Timing.mark("reconciling after final deletion")
    services.watch.reconcileAll()
    try await waitForGridInspector("empty inspector") { controller.inspector.name == nil }
    #expect(controller.inspector.name == nil)
    #expect(controller.inspector.value == .unknown)
    #expect(controller.gridShellVisible, "the emptied folder stays in the grid shell; page 22 disables its search")
    #expect(controller.session.inspectorFocus.isVisible)
}
