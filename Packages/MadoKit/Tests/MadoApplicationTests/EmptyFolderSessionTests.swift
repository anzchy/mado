import Foundation
import Testing
import MadoCore
@testable import MadoApplication

@Test(.timeLimit(.minutes(2))) @MainActor func sessionWithoutFolderSourceIsNotEmptyFolder() {
    #expect(!ViewerSession().isEmptyFolder)
}

/// Owner decision C (#137): an empty folder session reports `.emptyFolder`, not the generic `.empty`, but only while
/// nothing else is presented: an opening image or a reading scan wins.
@Test(.timeLimit(.minutes(2))) @MainActor func emptyFolderStatusOnlyWhileNothingElseIsPresented() async throws {
    let fixture = FolderScanFixture(), session = ViewerSession()
    session.folderScan = fixture.coordinator
    #expect(session.imageStatus == .empty, "no scan yet")
    let task = fixture.coordinator.begin(folder: fixture.folder, rootID: fixture.id)
    #expect(session.imageStatus == .readingFolder)
    await fixture.scanner.waitForStart()
    try await fixture.scanner.deliver([])
    await fixture.scanner.finish(); try await task.value
    #expect(session.isEmptyFolder && session.imageStatus == .emptyFolder)
    #expect(!session.isEnabled(.next) && !session.isEnabled(.previous))
    let other = fixture.folder.appendingPathComponent("elsewhere.png")
    session.openImage(other, maximumPixelSize: 1) { try await Task.sleep(for: .seconds(60)); throw CancellationError() }
    #expect(session.imageStatus == .loading("elsewhere.png"), "an opening image is shown, not page 22")
    session.closeImage()
    #expect(session.imageStatus == .emptyFolder)
}
