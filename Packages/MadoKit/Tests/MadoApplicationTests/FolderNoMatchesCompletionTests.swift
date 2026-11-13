import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class NoMatchesHost: FolderScanHost {
    var opens: [URL] = []
    var clears = 0
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { }
    func clearFolderImageForNoMatches() { clears += 1 }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123ExcludedExplicitInputWaitsForLaterFilteredMatch() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(!coordinator.hasNoMatches)
    #expect(session.imageStatus == .readingFolder)
    #expect(host.clears == 0 && host.opens.isEmpty)

    try await fixture.scanner.deliver(["b.png"])
    #expect(coordinator.currentURL?.lastPathComponent == "b.png")
    #expect(host.opens.map(\.lastPathComponent) == ["b.png"])
    #expect(host.clears == 0)
    #expect(session.imageStatus != .noMatches && session.imageStatus != .readingFolder)
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.map(\.lastPathComponent) == ["b.png"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123FilteredPartialFailureOffersRetryAndRecovers() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(session.imageStatus == .readingFolder)
    await fixture.scanner.finish(failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await task.value }
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "A"))
    #expect(!coordinator.hasNoMatches)

    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    #expect(session.imageStatus == .readingFolder)
    try await fixture.scanner.deliver(["b.png"], at: 1)
    await fixture.scanner.finish(1); try await retry.value
    #expect(coordinator.currentURL?.lastPathComponent == "b.png")
    #expect(!coordinator.hasNoMatches && session.imageStatus != .folderScanFailed("Folder scan failed", "A"))
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123FirstEligibleBatchUsesTypeOrderAndLaterBatchKeepsCurrent() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("excluded.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["excluded.jpg"])
    coordinator.setConditions(.init(sort: .type, selectedExtensions: ["png", "gif"]))
    #expect(session.imageStatus == .readingFolder)
    try await fixture.scanner.deliver(["z.png", "b.gif"])
    #expect(coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["b.gif", "z.png"])
    #expect(coordinator.currentURL?.lastPathComponent == "b.gif")
    #expect(host.opens.map(\.lastPathComponent) == ["b.gif"])
    try await fixture.scanner.deliver(["a.gif", "c.png"])
    #expect(coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["a.gif", "b.gif", "c.png", "z.png"])
    #expect(coordinator.currentURL?.lastPathComponent == "b.gif")
    #expect(host.opens.map(\.lastPathComponent) == ["b.gif"])
    await fixture.scanner.finish(); try await task.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123FilteredFailureRetryWithoutMatchFinishesAsNoMatches() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    await fixture.scanner.finish(failing: true)
    await #expect(throws: FolderScanTestError.expected) { try await task.value }
    #expect(session.imageStatus == .folderScanFailed("Folder scan failed", "A"))

    let retry = try #require(coordinator.retry())
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["a.jpg"], at: 1)
    #expect(!coordinator.hasNoMatches && session.imageStatus == .readingFolder)
    await fixture.scanner.finish(1); try await retry.value
    #expect(coordinator.hasNoMatches && session.imageStatus == .noMatches)
    #expect(host.clears == 1 && coordinator.currentURL == nil)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123CancelWhileAwaitingMatchClearsNoMatchState() async throws {
    let fixture = FolderScanFixture(), session = ViewerSession()
    let coordinator = fixture.coordinator
    session.folderScan = coordinator
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(session.imageStatus == .readingFolder)
    coordinator.cancel()
    await fixture.scanner.finish(); try await task.value
    #expect(!coordinator.hasNoMatches && !coordinator.isAwaitingFilteredMatch)
    #expect(coordinator.snapshot == nil && coordinator.failureReason == nil)
    #expect(session.imageStatus != .noMatches && session.imageStatus != .readingFolder)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123EligibleExplicitInputRemainsCurrentUntilItsBatch() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let input = fixture.folder.appendingPathComponent("late.png")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["excluded.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(!coordinator.hasNoMatches && session.imageStatus != .noMatches)
    #expect(coordinator.currentURL == input && host.clears == 0 && host.opens.isEmpty)
    try await fixture.scanner.deliver(["late.png"])
    #expect(coordinator.currentURL == input && host.opens.isEmpty)
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.currentURL == input && host.clears == 0)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue127LateJPEGInputStaysCurrentWithJPGFilter() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let input = fixture.folder.appendingPathComponent("late.jpeg")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    coordinator.setConditions(.init(selectedExtensions: ["jpg"]))
    try await fixture.scanner.deliver(["other.jpg"])
    #expect(coordinator.currentURL == input)
    #expect(host.opens.isEmpty && host.clears == 0)
    #expect(!coordinator.hasNoMatches && session.imageStatus != .noMatches)
    try await fixture.scanner.deliver(["late.jpeg"])
    #expect(coordinator.currentURL == input && host.opens.isEmpty)
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.currentURL == input && !coordinator.hasNoMatches)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func issue123NoMatchIsFinalOnlyAfterScanCompletion(grid: Bool) async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let input = grid ? nil : fixture.folder.appendingPathComponent("a.jpg")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(!coordinator.hasNoMatches && session.imageStatus == .readingFolder)
    #expect(host.clears == 0)
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.hasNoMatches && session.imageStatus == .noMatches)
    #expect(host.clears == 1 && coordinator.currentURL == nil)
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func issue123SilentRefreshDefersNewNoMatchUntilReplacementIsComplete(hasLaterMatch: Bool) async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let initial = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await initial.value

    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(!coordinator.hasNoMatches && session.imageStatus == .readingFolder)
    #expect(host.clears == 0)
    try await fixture.scanner.deliver(hasLaterMatch ? ["b.png"] : ["a.jpg"], at: 1)
    #expect(host.clears == 0 && !coordinator.hasNoMatches)
    await fixture.scanner.finish(1); try await refresh.value
    if hasLaterMatch {
        #expect(!coordinator.hasNoMatches && coordinator.currentURL?.lastPathComponent == "b.png")
        #expect(host.opens.map(\.lastPathComponent) == ["b.png"] && host.clears == 0)
    } else {
        #expect(coordinator.hasNoMatches && session.imageStatus == .noMatches)
        #expect(host.clears == 1 && coordinator.currentURL == nil)
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123RefreshKeepsExistingNoMatchUntilNewMatchCompletes() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let initial = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await initial.value
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(coordinator.hasNoMatches && session.imageStatus == .noMatches && host.clears == 1)

    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    #expect(coordinator.hasNoMatches && session.imageStatus == .noMatches && host.clears == 1)
    try await fixture.scanner.deliver(["b.png"], at: 1)
    #expect(coordinator.hasNoMatches && host.opens.isEmpty)
    await fixture.scanner.finish(1); try await refresh.value
    #expect(!coordinator.hasNoMatches && coordinator.currentURL?.lastPathComponent == "b.png")
    #expect(host.opens.map(\.lastPathComponent) == ["b.png"] && host.clears == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123ChangedRefreshWithNoFilteredMatchClearsOnceAfterCompletion() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let initial = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await initial.value

    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    try await fixture.scanner.deliver(["c.jpg"], at: 1)
    #expect(!coordinator.hasNoMatches && host.clears == 0)
    await fixture.scanner.finish(1); try await refresh.value
    #expect(coordinator.hasNoMatches && session.imageStatus == .noMatches)
    #expect(coordinator.currentURL == nil && host.clears == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123EmptyFolderRefreshKeepsEmptyStateWhileScanning() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), session = ViewerSession()
    let coordinator = fixture.coordinator
    coordinator.host = host; session.folderScan = coordinator
    let initial = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    await fixture.scanner.finish(); try await initial.value
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(session.imageStatus == .emptyFolder && !coordinator.hasNoMatches)

    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    #expect(session.imageStatus == .emptyFolder && !coordinator.hasNoMatches)
    #expect(host.clears == 0)
    await fixture.scanner.finish(1); try await refresh.value
    #expect(session.imageStatus == .emptyFolder && host.clears == 0)
}

@Test(.timeLimit(.minutes(2))) @MainActor func issue123RefreshLosingPresentationAuthorityDoesNotClearHost() async throws {
    let fixture = FolderScanFixture(), host = NoMatchesHost(), coordinator = fixture.coordinator
    coordinator.host = host
    var allowed = true
    let initial = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"), canPresent: { allowed })
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await initial.value

    let refresh = try #require(coordinator.refresh())
    await fixture.scanner.waitForStart(1)
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    allowed = false
    try await fixture.scanner.deliver(["c.jpg"], at: 1)
    await fixture.scanner.finish(1); try await refresh.value
    #expect(host.clears == 0 && host.opens.isEmpty)
}
