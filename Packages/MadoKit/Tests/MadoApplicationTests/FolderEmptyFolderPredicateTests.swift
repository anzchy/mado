import Foundation
import Testing
import MadoCore
@testable import MadoApplication

/// File-private SplitMix64 with fixed seeds (no property-testing library in the package).
private struct EmptyFolderRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
}

@Test @MainActor func emptyFolderPredicateTrueOnlyAfterCompleteZeroEntryScan() async throws {
    let fixture = FolderScanFixture(), coordinator = fixture.coordinator, session = ViewerSession()
    session.folderScan = coordinator
    #expect(!coordinator.isEmptyFolder, "a: fresh fixture")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    #expect(!coordinator.isEmptyFolder, "b: reading")
    try await fixture.scanner.deliver([])
    #expect(!coordinator.isEmptyFolder && coordinator.isReadingFolder, "c: empty batch while reading")
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.isEmptyFolder, "d: complete, zero entries")
    #expect(session.isEmptyFolder, "d: session")
    coordinator.cancel()
    #expect(!coordinator.isEmptyFolder && !session.isEmptyFolder, "h: cancel after d")

    let recursive = FolderScanFixture()
    #expect(recursive.coordinator.setRecursiveEnabled(true) == nil)
    let recursiveTask = recursive.coordinator.begin(folder: recursive.folder, rootID: recursive.id)
    await recursive.scanner.waitForStart()
    #expect(await recursive.scanner.options(at: 0).recursive)
    await recursive.scanner.finish(); try await recursiveTask.value
    #expect(recursive.coordinator.isEmptyFolder, "e: recursive on, zero entries")

    let failing = FolderScanFixture()
    let failingTask = failing.coordinator.begin(folder: failing.folder, rootID: failing.id)
    await failing.scanner.waitForStart()
    await failing.scanner.finish(failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await failingTask.value }
    #expect(failing.coordinator.failure != nil && !failing.coordinator.isEmptyFolder, "f: failed scan")

    let input = FolderScanFixture()
    let inputTask = input.coordinator.begin(folder: input.folder, rootID: input.id,
        input: input.folder.appendingPathComponent("img2.png"))
    await input.scanner.waitForStart()
    #expect(!input.coordinator.isEmptyFolder, "g: input scan in flight")
    await input.scanner.finish(); try await inputTask.value
    #expect(input.coordinator.isEmptyFolder, "g: input-image scan of an empty folder (pinned)")

    let images = FolderScanFixture()
    let imagesTask = images.coordinator.begin(folder: images.folder, rootID: images.id)
    await images.scanner.waitForStart()
    try await images.scanner.deliver(["a.png"])
    await images.scanner.finish(); try await imagesTask.value
    #expect(!images.coordinator.isEmptyFolder, "i: one image")

    let refreshed = FolderScanFixture(), c = refreshed.coordinator
    let first = c.begin(folder: refreshed.folder, rootID: refreshed.id)
    await refreshed.scanner.waitForStart()
    await refreshed.scanner.finish(); try await first.value
    #expect(c.isEmptyFolder, "j: complete zero-entry scan")
    let failedRefresh = try #require(c.refresh())
    await refreshed.scanner.waitForStart(1)
    await refreshed.scanner.finish(1, failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await failedRefresh.value }
    #expect(c.failure != nil && !c.isEmptyFolder, "k: failed refresh")
    #expect(c.sourceSnapshot?.isComplete == true && c.sourceSnapshot?.entries.isEmpty == true, "k: source kept")
    let recovered = try #require(c.refresh())
    await refreshed.scanner.waitForStart(2)
    try await refreshed.scanner.deliver([], at: 2)
    await refreshed.scanner.finish(2); try await recovered.value
    #expect(c.failure == nil && c.isEmptyFolder, "l: recovered refresh")
}

@Test @MainActor func emptyFolderExclusiveWithReadingNoMatchesAndFailureAcrossTransitions() async throws {
    let pool = ["a.png", "b.jpg", "c.heic"]
    let filters: [Set<String>?] = [nil, ["png"], ["jpg"], ["heic"]]
    var random = EmptyFolderRandom(seed: 0x137)
    var failedRefreshReached = 0
    for sequence in 0..<60 {
        let fixture = FolderScanFixture(), c = fixture.coordinator
        var calls = 0
        var open: (index: Int, task: Task<Void, any Error>)?
        func names() -> [String] { Array(pool.shuffled(using: &random).prefix(random.below(4))) }
        func check(_ label: String, quiescent: Bool) {
            let empty = c.isEmptyFolder
            if empty {
                #expect(!c.isReadingFolder && c.failure == nil && !c.hasNoMatches, "\(label): exclusive")
                #expect(c.sourceSnapshot?.isComplete == true && c.sourceSnapshot?.entries.isEmpty == true, "\(label): implication")
            }
            if c.isReadingFolder { #expect(c.failure == nil && !c.hasNoMatches && !empty, "\(label): reading exclusive") }
            if quiescent, c.sourceSnapshot?.isComplete == true, c.sourceSnapshot?.entries.isEmpty == true,
               c.failure == nil, !c.isReadingFolder {
                #expect(empty, "\(label): converse")
            }
            if c.failure != nil, c.sourceSnapshot?.isComplete == true { failedRefreshReached += 1 }
        }
        func settleOpen(failing: Bool, _ label: String) async throws {
            guard let pending = open else { return }
            open = nil
            if !failing { try? await fixture.scanner.deliver(names(), at: pending.index) }
            await fixture.scanner.finish(pending.index, failing: failing)
            _ = try? await pending.task.value
            check("\(label) settled", quiescent: true)
        }
        for step in 0..<(1 + random.below(8)) {
            let label = "seed 0x137 sequence \(sequence) op \(step)"
            let op = random.below(6)
            if open != nil, op != 2 { try await settleOpen(failing: false, label) }
            switch op {
            case 0:
                let task = c.begin(folder: fixture.folder, rootID: fixture.id)
                let index = calls; calls += 1
                await fixture.scanner.waitForStart(index)
                check("\(label) begin mid-scan", quiescent: false)
                try await fixture.scanner.deliver(names(), at: index)
                await fixture.scanner.finish(index)
                _ = try? await task.value
                check("\(label) begin", quiescent: true)
            case 1:
                guard let task = c.refresh() else { check("\(label) refresh skipped", quiescent: true); continue }
                let index = calls; calls += 1
                await fixture.scanner.waitForStart(index)
                check("\(label) refresh in flight", quiescent: false)
                if random.below(2) == 0 { open = (index, task); continue }
                try await fixture.scanner.deliver(names(), at: index)
                await fixture.scanner.finish(index)
                _ = try? await task.value
                check("\(label) refresh", quiescent: true)
            case 2:
                if open != nil { try await settleOpen(failing: true, "\(label) failInFlight"); continue }
                let task = c.begin(folder: fixture.folder, rootID: fixture.id)
                let index = calls; calls += 1
                await fixture.scanner.waitForStart(index)
                try await fixture.scanner.deliver(names(), at: index)
                await fixture.scanner.finish(index, failing: true)
                _ = try? await task.value
                check("\(label) failInFlight begin", quiescent: true)
            case 3, 4:
                c.setConditions(.init(selectedExtensions: filters[random.below(filters.count)]))
                check("\(label) setConditions", quiescent: open == nil)
            default:
                c.cancel()
                check("\(label) cancel", quiescent: true)
            }
        }
        try await settleOpen(failing: false, "seed 0x137 sequence \(sequence) end")
    }
    #expect(failedRefreshReached > 0, "the generator reached a failed refresh over a complete source")
}

@Test @MainActor func filterNeverProducesEmptyFolderState() async throws {
    let extensions = ["png", "jpg", "heic", "gif"]
    var random = EmptyFolderRandom(seed: 0x22)
    for sample in 0..<80 {
        let names = (0..<random.below(7)).map { "f\($0).\(extensions[random.below(extensions.count)])" }
        let filter: Set<String>? = random.below(4) == 0 ? nil : Set(extensions.filter { _ in random.below(2) == 0 })
        let fixture = FolderScanFixture(), c = fixture.coordinator
        let task = c.begin(folder: fixture.folder, rootID: fixture.id)
        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(names)
        await fixture.scanner.finish(); try await task.value
        let label = "seed 0x22 sample \(sample) names \(names) filter \(String(describing: filter))"
        let unfiltered = (c.isEmptyFolder, c.hasNoMatches)
        #expect(unfiltered.0 == names.isEmpty, "\(label): unfiltered")
        c.setConditions(.init(selectedExtensions: filter))
        #expect(c.isEmptyFolder == unfiltered.0, "\(label): filter is irrelevant")
        if names.isEmpty { #expect(!c.hasNoMatches, "\(label): empty source never no-matches") }
        let excludesAll = filter.map { filter in names.allSatisfy { !filter.contains(($0 as NSString).pathExtension) } } ?? false
        if !names.isEmpty, excludesAll { #expect(c.hasNoMatches && !c.isEmptyFolder, "\(label): AC-3 no matches") }
        c.setConditions(.init())
        #expect(c.isEmptyFolder == unfiltered.0 && c.hasNoMatches == unfiltered.1, "\(label): round trip")
    }
}

@Test @MainActor func watchedRefreshTogglesEmptyFolder() async throws {
    let fixture = FolderScanFixture(), c = fixture.coordinator
    let task = c.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(!c.isEmptyFolder, "1: one image")
    for (index, names) in [[], ["b.png"], []].enumerated() {
        let before = c.isEmptyFolder
        let refresh = try #require(c.refresh())
        await fixture.scanner.waitForStart(index + 1)
        #expect(c.isEmptyFolder == before, "refresh \(index + 2) in flight holds the previous value")
        try await fixture.scanner.deliver(names, at: index + 1)
        await fixture.scanner.finish(index + 1); try await refresh.value
        #expect(c.isEmptyFolder == names.isEmpty, "refresh \(index + 2) to \(names)")
    }
}

@Test @MainActor func recursiveRescanFromEmptyFolderCancelRestoresEmptyFolder() async throws {
    let fixture = FolderScanFixture(), session = ViewerSession()
    session.folderScan = fixture.coordinator
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(); try await task.value
    let generation = try #require(fixture.coordinator.sourceSnapshot?.version.generation)
    session.beginBrowsing(items: [], sourceVersion: .init(generation), scrollAnchor: nil)
    #expect(session.isEmptyFolder)
    let rescan = try #require(session.setFolderRecursiveEnabled(true))
    await fixture.scanner.waitForStart(1)
    #expect(fixture.coordinator.isReadingFolder && !session.isEmptyFolder)
    #expect(session.imageStatus == .readingFolder)
    #expect(session.cancelFolderEntry() == .grid)
    #expect(session.isEmptyFolder && !session.folderRecursiveEnabled)
    #expect(fixture.coordinator.sourceSnapshot?.isComplete == true && fixture.coordinator.sourceSnapshot?.entries.isEmpty == true)
    await fixture.scanner.finish(1)
    _ = try? await rescan.value
    #expect(session.isEmptyFolder, "the late completion is ignored")
}
