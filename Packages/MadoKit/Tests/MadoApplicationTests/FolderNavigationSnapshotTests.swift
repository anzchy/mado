import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor final class FolderNavigationHost: FolderScanHost, ViewerSessionNavigationHost, ViewerInputHost {
    var opens: [(URL, AccessRootID)] = []
    var inputOpens: [URL] = []
    var navigation: [NavigationDirection] = []
    var visible: URL?
    var onOpen: (() -> Void)?
    var hasImage = true
    var canNavigate = true
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws { }
    func openFolderImage(_ url: URL, rootID: AccessRootID) {
        visible = url; opens.append((url, rootID)); onOpen?()
    }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) { visible = url; inputOpens.append(url) }
    func showInputNotice(_ notice: ViewerInputNotice) { }
    func promptForInputFolder(_ folder: URL) { }
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func requestOpen() { }
    func applyFocus(_ focus: FocusContext) { }
    func showInspector(_ visible: Bool) { }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationEnabledTable() async throws {
    for complete in [false, true] {
        for position in 0...2 {
            let fixture = FolderScanFixture(), host = FolderNavigationHost()
            let session = ViewerSession(host: host)
            session.folderScan = fixture.coordinator; fixture.coordinator.host = host
            let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
                input: fixture.folder.appendingPathComponent("img\(position + 1).png"))
            await fixture.scanner.waitForStart()
            try await fixture.scanner.deliver(["img3.png", "img1.png", "img2.png"])
            if complete { await fixture.scanner.finish(); try await task.value }
            #expect(session.isEnabled(.previous) == (!complete || position != 0))
            #expect(session.isEnabled(.next) == (!complete || position != 2))
            if !complete { await fixture.scanner.finish(); try await task.value }
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationVisibleMoveSequence() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    let session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img2.png"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img3.png", "img1.png", "img2.png"])
    #expect(fixture.coordinator.move(.next))
    #expect(fixture.coordinator.move(.next))
    #expect(fixture.coordinator.canMove(.next) == true)
    #expect(host.opens.map(\.0.lastPathComponent) == ["img3.png"])
    await fixture.scanner.finish(); try await task.value
    for direction in [NavigationDirection.next, .previous, .previous, .previous] {
        #expect(fixture.coordinator.move(direction))
    }
    #expect(host.opens.map(\.0.lastPathComponent) == ["img3.png", "img2.png", "img1.png"])
    #expect(host.opens.map(\.1) == [fixture.id, fixture.id, fixture.id])
    #expect(fixture.coordinator.currentItemID == .rootRelative(rootID: fixture.id, relativePath: "A/img1.png"))
    #expect(fixture.coordinator.currentURL == fixture.folder.appendingPathComponent("img1.png"))
    #expect(fixture.coordinator.canMove(.previous) == false)
    #expect(host.navigation.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationEarlierInsertKeepsCurrentItemID() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img2.png"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img2.png", "img10.png"])
    let current = ItemID.rootRelative(rootID: fixture.id, relativePath: "A/img2.png")
    #expect(fixture.coordinator.currentItemID == current)
    try await fixture.scanner.deliver(["img1.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(fixture.coordinator.currentItemID == current)
    #expect(fixture.coordinator.move(.next))
    #expect(host.opens.map(\.0.lastPathComponent) == ["img10.png"])
}

@Test(.timeLimit(.minutes(2)), arguments: [NavigationDirection.next, .previous])
@MainActor func folderNavigationPendingOnce(direction: NavigationDirection) async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img2.png"), pending: direction)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver([direction == .next ? "img1.png" : "img3.png"])
    #expect(host.opens.isEmpty)
    try await fixture.scanner.deliver(["img2.png"])
    #expect(host.opens.isEmpty)
    try await fixture.scanner.deliver([direction == .next ? "img3.png" : "img1.png"])
    #expect(host.opens.map(\.0.lastPathComponent) == [direction == .next ? "img3.png" : "img1.png"])
    try await fixture.scanner.deliver([direction == .next ? "img4.png" : "img0.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.count == 1)
    let noNeighbor = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img2.png"), pending: direction)
    await fixture.scanner.waitForStart(1)
    try await fixture.scanner.deliver(["img2.png"], at: 1)
    await fixture.scanner.finish(1); try await noNeighbor.value
    #expect(host.opens.count == 1)
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationPrecedenceAndFallback() async throws {
    for source in ["file", "grid", "snapshot", "nonmember"] {
        let fixture = FolderScanFixture(), host = FolderNavigationHost()
        let session = ViewerSession(host: host), router = CommandRouter(implementedCommands: Set(CommandID.allCases))
        session.folderScan = fixture.coordinator; fixture.coordinator.host = host
        let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
            input: fixture.folder.appendingPathComponent(source == "nonmember" ? "missing.png" : "img1.png"))
        await fixture.scanner.waitForStart()
        try await fixture.scanner.deliver(["img1.png", "img2.png"])
        await fixture.scanner.finish(); try await task.value
        let a = ItemID.ephemeral(UUID()), b = ItemID.ephemeral(UUID())
        if source == "file" || source == "grid" {
            session.beginBrowsing(items: [a, b], sourceVersion: .init(1), scrollAnchor: a)
            session.select(a)
            #expect(router.route(.preview, from: .key, to: session))
        }
        let first = URL(fileURLWithPath: "/input/a.png"), second = URL(fileURLWithPath: "/input/b.png")
        if source == "file" { session.filePreviewSet = FilePreviewSet(files: [first, second]) }
        #expect(router.route(.next, from: .key, to: session))
        if source == "file" {
            #expect(host.inputOpens == [second])
            #expect(session.previewSet?.currentItemID == a)
            #expect(host.opens.isEmpty)
        } else if source == "grid" {
            #expect(session.previewSet?.currentItemID == b)
            #expect(host.opens.isEmpty)
        } else if source == "snapshot" {
            #expect(host.opens.map(\.0.lastPathComponent) == ["img2.png"])
            #expect(host.navigation.isEmpty)
        } else {
            #expect(host.navigation == [.next])
            #expect(host.opens.isEmpty)
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationFileGrantEndsSnapshot() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession()
    session.host = host; session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img1.png"), pending: .next)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png"])
    session.endFolderScan()
    let grant = URL(fileURLWithPath: "/outside/single.png")
    host.openInputImage(grant, accessRequest: .fileGrant(grant))
    try await fixture.scanner.deliver(["img2.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(fixture.coordinator.snapshot == nil)
    #expect(fixture.coordinator.currentItemID == nil)
    #expect(fixture.coordinator.currentURL == nil)
    #expect(host.visible == grant && host.opens.isEmpty)
    #expect(await fixture.access.balance == [1, 1])
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.navigation == [.next])
    session.folderScan = nil; session.endFolderScan(); session.cancelFolderReading()
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationReadingDisablesOldImageArrowsAndCancelForwards() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession()
    session.host = host; session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    #expect(!session.isEnabled(.previous) && !session.isEnabled(.next))
    await fixture.scanner.waitForStart()
    session.cancelFolderReading()
    try await fixture.scanner.deliver(["late.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(fixture.coordinator.snapshot == nil && !fixture.coordinator.isReadingFolder)
    #expect(host.opens.isEmpty)
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationCancelDuringPendingApply() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    fixture.coordinator.host = host; host.onOpen = { fixture.coordinator.cancel() }
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img1.png"), pending: .next)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png"])
    #expect(host.opens.map(\.0.lastPathComponent) == ["img2.png"])
    #expect(fixture.coordinator.snapshot == nil)
    #expect(await fixture.access.balance == [1, 0])
    try await fixture.scanner.deliver(["img3.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(host.opens.count == 1)
    #expect(await fixture.access.balance == [1, 1])
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationSupersededAccessIntentCannotAutoOpen() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), intent = AccessIntent()
    fixture.coordinator.host = host
    let a = intent.begin()
    host.onOpen = { _ = intent.begin() }
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img1.png"), pending: .next, canPresent: { a.isCurrent })
    await fixture.scanner.waitForStart()
    let b = intent.begin()
    try await fixture.scanner.deliver(["img1.png", "img2.png"])
    #expect(host.opens.isEmpty && b.isCurrent)
    #expect(fixture.coordinator.move(.next))
    #expect(host.opens.map(\.0.lastPathComponent) == ["img2.png"])
    #expect(!b.isCurrent)
    #expect(fixture.coordinator.move(.previous))
    #expect(host.opens.map(\.0.lastPathComponent) == ["img2.png", "img1.png"])
    await fixture.scanner.finish(); try await task.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func folderNavigationActualURLMismatchFallsThrough() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost()
    fixture.coordinator.host = host
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id,
        input: fixture.folder.appendingPathComponent("img1.png"))
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["img1.png", "img2.png"])
    await fixture.scanner.finish(); try await task.value
    let other = URL(fileURLWithPath: "/outside/other.png")
    #expect(fixture.coordinator.canMove(.next, currentURL: other) == nil)
    #expect(!fixture.coordinator.move(.next, currentURL: other))
    #expect(host.opens.isEmpty)
}
