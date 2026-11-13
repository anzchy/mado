import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private final class FolderViewTestHost: FolderScanHost {
    var opens: [URL] = []
    var cleared = 0
    func openFolderImage(_ url: URL, rootID: AccessRootID) { opens.append(url) }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { }
    func clearFolderImageForNoMatches() { cleared += 1 }
}

@Test(.timeLimit(.minutes(2)), arguments: [false, true])
@MainActor func folderViewSameExplicitInputRetryKeepsScanAndFilterAuthority(completed: Bool) async throws {
    let fixture = FolderScanFixture(), host = FolderViewTestHost(), coordinator = fixture.coordinator
    let accessIntent = AccessIntent(), operation = accessIntent.current
    let input = fixture.folder.appendingPathComponent("a.jpg")
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input,
        canPresent: { operation.isCurrent })
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.png"])
    if completed { await fixture.scanner.finish(); try await task.value }
    let request = AccessRequest.root(fixture.id, file: input)
    #expect(coordinator.preservesPresentationAuthorityForRetry(input, accessRequest: request))
    #expect(!coordinator.preservesPresentationAuthorityForRetry(fixture.folder.appendingPathComponent("other.jpg"), accessRequest: request))
    #expect(!coordinator.preservesPresentationAuthorityForRetry(input, accessRequest: .fileGrant(input)))
    if !coordinator.preservesPresentationAuthorityForRetry(input, accessRequest: request) {
        _ = accessIntent.begin() // ordinary native open would revoke the scan's captured operation
    }
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(host.opens.map(\.lastPathComponent) == ["b.png"])
    #expect(coordinator.currentURL?.lastPathComponent == "b.png")
    coordinator.setConditions(.init(selectedExtensions: ["tiff"]))
    #expect(coordinator.hasNoMatches == completed && host.cleared == (completed ? 1 : 0))
    coordinator.setConditions(.init())
    #expect(coordinator.currentURL?.lastPathComponent == (completed ? "a.jpg" : "b.png"))
    #expect(coordinator.move(.next))
    #expect(host.opens.last?.lastPathComponent == "b.png")
    if !completed { await fixture.scanner.finish(); try await task.value }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewFiltersNavigationAndRestoresSource() async throws {
    let fixture = FolderScanFixture(), host = FolderViewTestHost()
    let coordinator = fixture.coordinator
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img2.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img10.PNG", "img2.jpg", "img3.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.sourceSnapshot?.entries.count == 3)
    coordinator.setConditions(.init(sort: .name, direction: .descending, selectedExtensions: ["PNG"]))
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img10.PNG", "img3.png"])
    #expect(host.opens.map(\.lastPathComponent) == ["img10.PNG"])
    #expect(coordinator.currentURL?.lastPathComponent == "img10.PNG")
    #expect(coordinator.canMove(.next) == true)
    #expect(coordinator.move(.next))
    #expect(host.opens.map(\.lastPathComponent) == ["img10.PNG", "img3.png"])
    coordinator.setConditions(.init(selectedExtensions: ["tiff"]))
    #expect(coordinator.snapshot?.entries.isEmpty == true)
    #expect(coordinator.hasNoMatches)
    #expect(coordinator.canMove(.next) == false && coordinator.canMove(.previous) == false)
    #expect(host.cleared == 1)
    coordinator.setConditions(.init())
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img2.jpg", "img3.png", "img10.PNG"])
    #expect(coordinator.currentURL?.lastPathComponent == "img2.jpg")
    #expect(host.opens.map(\.lastPathComponent) == ["img10.PNG", "img3.png", "img2.jpg"])
    #expect(coordinator.sourceSnapshot?.entries.count == 3)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewOnlyWrapsCompleteMultiItemSnapshot() async throws {
    let fixture = FolderScanFixture(), host = FolderViewTestHost(), coordinator = fixture.coordinator
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.png"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png", "b.png"])
    #expect(coordinator.canMove(.previous, mayWrap: true) == true)
    #expect(coordinator.move(.previous, mayWrap: true))
    #expect(host.opens.isEmpty)
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.canMove(.previous, mayWrap: true) == true)
    #expect(coordinator.move(.previous, mayWrap: true))
    #expect(host.opens.map(\.lastPathComponent) == ["b.png"])
    #expect(coordinator.move(.next, mayWrap: true))
    #expect(host.opens.map(\.lastPathComponent) == ["b.png", "a.png"])
    let singleton = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("only.png"))
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["only.png"], at: 1)
    await fixture.scanner.finish(1); try await singleton.value
    #expect(coordinator.canMove(.next, mayWrap: true) == false && coordinator.canMove(.previous, mayWrap: true) == false)
    #expect(coordinator.move(.next, mayWrap: true))
    #expect(host.opens.map(\.lastPathComponent) == ["b.png", "a.png"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewLateBatchUsesLatestFilterAndNewFolderResetsConditions() async throws {
    let fixture = FolderScanFixture(), host = FolderViewTestHost(), coordinator = fixture.coordinator
    let session = ViewerSession()
    coordinator.host = host
    session.setFolderLoopEnabled(true)
    let old = coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    coordinator.setConditions(.init(selectedExtensions: ["PNG"]))
    #expect(!coordinator.hasNoMatches && host.cleared == 0)
    try await fixture.scanner.deliver(["b.PNG"])
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["b.PNG"])
    #expect(host.opens.map(\.lastPathComponent) == ["b.PNG"])
    let newFolder = fixture.root.appendingPathComponent("B")
    let newer = coordinator.begin(folder: newFolder, rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    #expect(coordinator.conditions == .init() && session.displayPreferences.loopThroughImages)
    try await fixture.scanner.deliver(["late.PNG"], at: 0)
    try await fixture.scanner.deliver(["img10.jpg", "img2.jpg"], at: 1)
    await fixture.scanner.finish(0); try await old.value
    await fixture.scanner.finish(1); try await newer.value
    #expect(coordinator.snapshot?.version.folder == newFolder)
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["img2.jpg", "img10.jpg"])
    #expect(host.opens.map(\.lastPathComponent) == ["b.PNG", "img2.jpg"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewSessionControlsRespectFrozenPreviewAndReportNoMatches() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: host)
    #expect(fixture.coordinator.availableExtensions.isEmpty)
    #expect(!session.hasFolderSource && session.folderAvailableExtensions.isEmpty)
    #expect(session.folderConditions == .init() && !session.folderLoopEnabled)
    session.setFolderConditions(.init(selectedExtensions: ["png"]))
    session.setFolderLoopEnabled(true)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.PNG"])
    await fixture.scanner.finish(); try await task.value
    #expect(session.hasFolderSource && session.folderAvailableExtensions == ["jpg", "png"])
    session.filePreviewSet = FilePreviewSet(files: [URL(fileURLWithPath: "/input/one.png"),
                                                    URL(fileURLWithPath: "/input/two.jpg")])
    session.setFolderConditions(.init(selectedExtensions: ["tiff"]))
    session.setFolderLoopEnabled(true)
    // #344 makes loop global even while the frozen file set keeps its own paging behavior.
    #expect(session.folderConditions == .init() && session.folderLoopEnabled)
    session.filePreviewSet = nil
    session.setFolderLoopEnabled(true)
    session.setFolderConditions(.init(selectedExtensions: ["tiff"]))
    #expect(session.folderLoopEnabled && session.folderConditions.selectedExtensions == ["tiff"])
    #expect(session.imageStatus == .noMatches)
    #expect(!session.isEnabled(.next) && !session.isEnabled(.previous))
    session.setFolderConditions(.init())
    #expect(session.imageStatus != .noMatches)
    #expect(fixture.coordinator.snapshot?.entries.count == 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewCompletedFolderWithExcludedEntriesClearsPriorPresentation() async throws {
    let fixture = FolderScanFixture(), host = FolderViewTestHost(), coordinator = fixture.coordinator
    coordinator.host = host
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    try await fixture.scanner.deliver(["excluded.jpg"])
    await fixture.scanner.finish(); try await task.value
    #expect(coordinator.hasNoMatches)
    #expect(host.cleared == 1 && !coordinator.isEmptyFolder && host.opens.isEmpty)
    coordinator.setConditions(.init(selectedExtensions: ["png"]))
    #expect(host.cleared == 1)
    coordinator.setConditions(.init())
    #expect(host.opens.map(\.lastPathComponent) == ["excluded.jpg"])

    let empty = coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    await fixture.scanner.finish(1); try await empty.value
    #expect(!coordinator.hasNoMatches)
    #expect(coordinator.isEmptyFolder && host.cleared == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewFilterExcludesExplicitInputBeforeItsBatchArrives() async throws {
    let fixture = FolderScanFixture(), host = FolderViewTestHost(), coordinator = fixture.coordinator
    coordinator.host = host
    let input = fixture.folder.appendingPathComponent("late.jpg")
    let task = coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: input)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["first.PNG"])
    #expect(coordinator.currentURL == input && host.opens.isEmpty)
    coordinator.setConditions(.init(selectedExtensions: ["pNg"]))
    #expect(coordinator.currentURL?.lastPathComponent == "first.PNG")
    #expect(host.opens.map(\.lastPathComponent) == ["first.PNG"])
    try await fixture.scanner.deliver(["late.jpg", "second.png"])
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["first.PNG", "second.png"])
    #expect(coordinator.currentURL?.lastPathComponent == "first.PNG")
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.map(\.lastPathComponent) == ["first.PNG"])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewNoMatchesDoesNotOverrideFrozenPreviewStatus() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg"])
    await fixture.scanner.finish(); try await task.value
    session.setFolderConditions(.init(selectedExtensions: ["png"]))
    #expect(session.imageStatus == .noMatches)

    session.filePreviewSet = FilePreviewSet(files: [URL(fileURLWithPath: "/input/one.png")])
    #expect(session.imageStatus != .noMatches)
    session.filePreviewSet = nil
    #expect(session.imageStatus == .noMatches)

    let id = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [id], sourceVersion: .init(1), scrollAnchor: id)
    session.select(id)
    #expect(CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.preview, from: .key, to: session))
    #expect(session.previewSet != nil && session.imageStatus != .noMatches)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewFilterReplacesAliasURLSharingEligibleIdentity() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let image = folder.appendingPathComponent("a.png")
    let alias = folder.appendingPathComponent("z-alias.jpg")
    try Data([1]).write(to: image)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: image)

    let rootID = AccessRootID(), host = FolderViewTestHost()
    let scanner = FolderScanControlledScanner()
    let coordinator = FolderScanCoordinator(access: FolderScanCountingLeases(root: folder), scanner: scanner)
    coordinator.host = host
    let task = coordinator.begin(folder: folder, rootID: rootID, input: alias)
    await scanner.waitForStart()
    try await scanner.deliver(["z-alias.jpg", "a.png"])
    await scanner.finish(); try await task.value
    #expect(coordinator.sourceSnapshot?.entries.count == 2)
    #expect(coordinator.sourceSnapshot?.navigationEntries.count == 1)
    #expect(coordinator.currentURL == alias)

    coordinator.setConditions(.init(selectedExtensions: ["PNG"]))
    #expect(coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["a.png"])
    #expect(coordinator.snapshot?.navigationEntries.map(\.url.lastPathComponent) == ["a.png"])
    #expect(coordinator.currentItemID == coordinator.snapshot?.entries.first?.itemID)
    #expect(coordinator.currentURL == image)
    #expect(host.opens == [image])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderViewFailedImageNextSkipsExcludedEntries() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession()
    host.hasImage = false; session.host = host; session.folderScan = fixture.coordinator
    fixture.coordinator.host = host
    let file = fixture.folder.appendingPathComponent("b.PNG")
    session.openImage(file, maximumPixelSize: 512) { throw ImageLoadError(.corruptImage) }
    await session.imageLoader.loadTask?.value
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: file)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.PNG", "c.jpg", "d.PNG"])
    await fixture.scanner.finish(); try await task.value
    session.setFolderConditions(.init(selectedExtensions: ["PNG"]))
    #expect(fixture.coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["b.PNG", "d.PNG"])
    #expect(session.imageStatus == .failed(.corruptImage, "b.PNG"))
    #expect(session.isEnabled(.next))
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.opens.map(\.0.lastPathComponent) == ["d.PNG"])
    session.cancelImageOpening()
}

// #345 replaces the former no-loop limitation; sort/filter controls still cannot change frozen membership/order.
@Test(.timeLimit(.minutes(2))) @MainActor func folderViewControlsPreserveFrozenOrderAndShareLoopPreference() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("a.jpg"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.jpg", "b.PNG", "c.png"])
    await fixture.scanner.finish(); try await task.value
    session.setFolderConditions(.init(sort: .name, direction: .descending, selectedExtensions: ["png"]))
    session.setFolderLoopEnabled(true)
    #expect(fixture.coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["c.png", "b.PNG"])
    let folderOpens = host.opens.count

    let first = URL(fileURLWithPath: "/input/two.png"), second = URL(fileURLWithPath: "/input/one.jpg")
    session.filePreviewSet = FilePreviewSet(files: [first, second])
    #expect(session.isEnabled(.next))
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.inputOpens == [second] && session.filePreviewSet?.current == second)
    #expect(session.isEnabled(.next) && session.isEnabled(.previous))
    session.filePreviewSet = nil

    let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID())
    session.beginBrowsing(items: [a, b], sourceVersion: .init(1), scrollAnchor: a)
    session.select(a)
    #expect(CommandRouter(implementedCommands: Set(CommandID.allCases)).route(.preview, from: .key, to: session))
    #expect(session.previewSet?.currentItemID == a)
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(session.previewSet?.currentItemID == b)
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(session.previewSet?.currentItemID == a)
    #expect(CommandRouter().route(.previous, from: .key, to: session))
    #expect(session.previewSet?.currentItemID == b)
    #expect(host.opens.count == folderOpens)
    #expect(fixture.coordinator.snapshot?.entries.map(\.url.lastPathComponent) == ["c.png", "b.PNG"])
}
