import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@MainActor private func filePreviewSession(_ files: [URL], at index: Int)
    -> (FolderScanFixture, FolderNavigationHost, ViewerSession) {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    session.filePreviewSet = FilePreviewSet(files: files)
    for _ in 0..<index { session.filePreviewSet?.move(forward: true) }
    return (fixture, host, session)
}

private func inputFiles(_ count: Int) -> [URL] {
    (0..<count).map { URL(fileURLWithPath: "/input-files/f\($0).png") }
}

@Test(.timeLimit(.minutes(2))) @MainActor func cancelReadingRestoresFilePreviewSetAndArrowNavigation() async throws {
    let files = inputFiles(3), router = CommandRouter()
    let (fixture, host, session) = filePreviewSession(files, at: 1)
    let token = session.inputNavigationIntent.current
    session.beginFolderEntry(shownImage: files[1], hasCompleteGrid: false)
    session.enterFolderGrid(items: [], sourceVersion: .init(0))
    let reading = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
    await fixture.scanner.waitForStart()
    #expect(session.filePreviewSet == nil, "the folder entry owns navigation while it reads")
    #expect(!token.isCurrent)
    #expect(!session.isEnabled(.next))

    #expect(session.cancelFolderEntry() == .viewer(files[1]))
    #expect(session.filePreviewSet?.members == files)
    #expect(session.filePreviewSet?.index == 1)
    #expect(session.mode == .viewing)
    #expect(!fixture.coordinator.isReadingFolder)
    #expect(!session.allowsFolderScanPresentation)
    #expect(router.route(.next, from: .key, to: session))
    #expect(host.inputOpens.last == files[2])
    #expect(session.filePreviewSet?.index == 2)
    #expect(!session.isEnabled(.next))
    #expect(router.route(.previous, from: .key, to: session))
    #expect(router.route(.previous, from: .key, to: session))
    #expect(host.inputOpens.suffix(2) == [files[1], files[0]])
    #expect(host.navigation.isEmpty)
    await fixture.scanner.finish(); try await reading.value
}

@Test(.timeLimit(.minutes(2))) @MainActor func cancelReadingRoundTripPreservesFilePreviewSetAtEveryIndex() {
    for count in 1...4 {
        for index in 0..<count {
            let files = inputFiles(count), host = FolderNavigationHost(), session = ViewerSession(host: host)
            session.filePreviewSet = FilePreviewSet(files: files)
            for _ in 0..<index { session.filePreviewSet?.move(forward: true) }
            session.beginFolderEntry(shownImage: files[index], hasCompleteGrid: false)
            session.enterFolderGrid(items: [], sourceVersion: .init(0))
            #expect(session.filePreviewSet == nil)
            #expect(session.cancelFolderEntry() == .viewer(files[index]))
            #expect(session.filePreviewSet?.members == files)
            #expect(session.filePreviewSet?.index == index, "count \(count) index \(index)")
            #expect(session.isEnabled(.next) == (index < count - 1))
            #expect(session.isEnabled(.previous) == (index > 0))
            _ = CommandRouter().route(.next, from: .key, to: session)
            #expect(host.inputOpens == (index < count - 1 ? [files[index + 1]] : []))
        }
    }
}

@Test(.timeLimit(.minutes(2))) @MainActor func completedFolderEntryDiscardsFilePreviewSet() {
    let files = inputFiles(3), host = FolderNavigationHost(), session = ViewerSession(host: host)
    host.canNavigate = false; host.hasImage = false
    session.filePreviewSet = FilePreviewSet(files: files)
    session.filePreviewSet?.move(forward: true)
    session.beginFolderEntry(shownImage: files[1], hasCompleteGrid: false)
    session.completeFolderEntry()
    #expect(session.cancelFolderEntry() == nil)
    #expect(session.filePreviewSet == nil)
    session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
    #expect(session.cancelFolderEntry() == .empty)
    #expect(session.filePreviewSet == nil)
    #expect(!session.isEnabled(.next))
}

@Test(.timeLimit(.minutes(2))) @MainActor func repeatedBeginKeepsFirstFilePreviewSet() {
    let files = inputFiles(3), host = FolderNavigationHost(), session = ViewerSession(host: host)
    session.filePreviewSet = FilePreviewSet(files: files)
    session.filePreviewSet?.move(forward: true)
    session.beginFolderEntry(shownImage: files[1], hasCompleteGrid: false)
    session.beginFolderEntry(shownImage: nil, hasCompleteGrid: false)
    #expect(session.filePreviewSet == nil)
    #expect(session.cancelFolderEntry() == .viewer(files[1]))
    #expect(session.filePreviewSet?.members == files)
    #expect(session.filePreviewSet?.index == 1)
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.inputOpens.last == files[2])
    #expect(session.cancelFolderEntry() == nil)
    #expect(session.filePreviewSet?.index == 2)
}

@Test(.timeLimit(.minutes(2))) @MainActor func cancelReadingWithIncompleteSourceFallsBackToNativeNavigation() async throws {
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let a = fixture.folder.appendingPathComponent("a.png")
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id, input: a)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png", "b.png", "c.png"])
    let visible = host.visible
    session.beginFolderEntry(shownImage: a, hasCompleteGrid: false)
    #expect(session.cancelFolderEntry() == .viewer(a))
    #expect(!fixture.coordinator.isReadingFolder)
    #expect(!session.hasFolderSource)
    #expect(fixture.coordinator.canMove(.next, currentURL: a) == nil)
    #expect(session.filePreviewSet == nil)
    try await fixture.scanner.deliver(["d.png"])
    await fixture.scanner.finish(); try await task.value
    #expect(!host.opens.contains { $0.0.lastPathComponent == "d.png" })
    #expect(host.visible == visible)
    #expect(fixture.coordinator.snapshot == nil)
    host.canNavigate = false
    #expect(!session.isEnabled(.next))
    host.canNavigate = true
    #expect(session.isEnabled(.next))
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.navigation == [.next])
    #expect(host.inputOpens.isEmpty)
}

@Test(.timeLimit(.minutes(2))) @MainActor func cancelReadingWithPriorCompleteFolderRestoresFilePreviewSet() async throws {
    let files = inputFiles(3)
    let fixture = FolderScanFixture(), host = FolderNavigationHost(), session = ViewerSession(host: host)
    session.folderScan = fixture.coordinator; fixture.coordinator.host = host
    let scan = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver(["a.png", "b.png"])
    await fixture.scanner.finish(); try await scan.value
    // Files dropped over a complete folder keep that folder as the background source.
    session.filePreviewSet = FilePreviewSet(files: files)
    session.filePreviewSet?.move(forward: true)
    session.beginFolderEntry(shownImage: files[1], hasCompleteGrid: false)
    session.enterFolderGrid(items: [], sourceVersion: .init(0))
    let reading = fixture.coordinator.begin(folder: fixture.root.appendingPathComponent("B"), rootID: fixture.id)
    await fixture.scanner.waitForStart(1)
    #expect(session.filePreviewSet == nil)
    let opens = host.opens.count
    #expect(session.cancelFolderEntry() == .viewer(files[1]))
    #expect(session.filePreviewSet?.members == files)
    #expect(session.filePreviewSet?.index == 1)
    #expect(session.hasFolderSource)
    #expect(!session.allowsFolderScanPresentation)
    #expect(host.opens.count == opens)
    #expect(CommandRouter().route(.next, from: .key, to: session))
    #expect(host.inputOpens.last == files[2])
    #expect(host.navigation.isEmpty)
    await fixture.scanner.finish(1); try await reading.value
}
