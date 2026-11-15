import Foundation
import Testing
import MadoApplication

// #684 P7-10 CAP-02: Capture Thumbnail output policy, lifetime and actions.

private struct OneScreen: CaptureScreenPort {
    let png: Data
    func captureCurrentDisplayPNG() async throws -> Data { png }
    func capturePNG(request: CaptureRequest) async throws -> Data { png }
}

private actor RecordingFiles: CaptureFilePort {
    private(set) var files: [String: Data] = [:]
    var failing = false
    func writeNewPNG(_ data: Data, named: String) throws -> URL {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        guard files[named] == nil else { throw CaptureFileError.alreadyExists }
        files[named] = data
        return URL(fileURLWithPath: "/Downloads").appendingPathComponent(named)
    }
    func setFailing(_ value: Bool) { failing = value }
}

private actor RecordingClipboard: CaptureClipboardPort {
    private(set) var writes: [Data] = []
    let succeeds: Bool
    init(succeeds: Bool = true) { self.succeeds = succeeds }
    func writePNG(_ png: Data) -> Bool {
        writes.append(png)
        return succeeds
    }
}

private actor RecordingTrash: CaptureTrashPort {
    private(set) var trashed: [URL] = []
    func moveToTrash(_ url: URL) throws { trashed.append(url) }
}

private let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1])
private let fixedDate = ISO8601DateFormatter().date(from: "2026-11-14T07:30:12Z")!

private func makeSession(_ files: RecordingFiles) -> CaptureSession {
    CaptureSession(screen: OneScreen(png: png), files: files, now: { fixedDate },
                   timeZone: TimeZone(secondsFromGMT: 0)!, folderDisplay: "~/Downloads")
}

@Test(.timeLimit(.minutes(2))) func issue684DefaultPolicyCopiesAndSaves() {
    #expect(CaptureOutputPolicy.standard == CaptureOutputPolicy(savesToFolder: true, copiesToClipboard: true))
}

@Test(.timeLimit(.minutes(2)), arguments: [(true, true), (true, false), (false, true), (false, false)])
func issue684OutputPolicyFourCombinations(save: Bool, copy: Bool) async throws {
    let files = RecordingFiles()
    let clipboard = RecordingClipboard()
    let state = try await makeSession(files).capture(
        request: nil, policy: CaptureOutputPolicy(savesToFolder: save, copiesToClipboard: copy), clipboard: clipboard)
    let written = await files.files
    let writes = await clipboard.writes
    #expect(state.png == png)
    #expect(written == (save ? ["mado-20261114073012.png": png] : [:]))
    #expect(writes == (copy ? [png] : []))
    #expect(state.clipboard == (copy ? .copied : .notCopied))
    #expect(state.saveFailed == false)
    if save {
        let url = URL(fileURLWithPath: "/Downloads/mado-20261114073012.png")
        #expect(state.savedURL == url)
        #expect(state.actions == [.copy, .moveToTrash])
        #expect(state.dragPayload == .file(url))
        #expect(state.status == .saved(folder: "~/Downloads", clipboard: copy ? .copied : .notCopied))
    } else {
        #expect(state.savedURL == nil)
        #expect(state.actions == [.save, .copy])
        #expect(state.dragPayload == .png(png))
        #expect(state.status == .notSaved(clipboard: copy ? .copied : .notCopied, saveFailed: false))
    }
}

@Test(.timeLimit(.minutes(2))) func issue684CopyFailureStillSaves() async throws {
    let files = RecordingFiles()
    let state = try await makeSession(files).capture(request: nil, policy: .standard,
                                                     clipboard: RecordingClipboard(succeeds: false))
    #expect(await files.files.count == 1)
    #expect(state.clipboard == .copyFailed)
    #expect(state.status == .saved(folder: "~/Downloads", clipboard: .copyFailed))
    #expect(state.actions == [.copy, .moveToTrash])
}

@Test(.timeLimit(.minutes(2))) func issue684WriteFailureStillGivesThumbnail() async throws {
    let files = RecordingFiles()
    await files.setFailing(true)
    let clipboard = RecordingClipboard()
    let state = try await makeSession(files).capture(request: nil, policy: .standard, clipboard: clipboard)
    #expect(state.savedURL == nil)
    #expect(state.saveFailed)
    #expect(state.actions == [.save, .copy])
    #expect(state.status == .notSaved(clipboard: .copied, saveFailed: true))
    #expect(await clipboard.writes == [png])
}

@Test(.timeLimit(.minutes(2))) func issue684SaveReusesNamingRule() async throws {
    let files = RecordingFiles()
    let session = makeSession(files)
    let first = try await session.save(png)
    let second = try await session.save(png)
    #expect(first.lastPathComponent == "mado-20261114073012.png")
    #expect(second.lastPathComponent == "mado-20261114073012-2.png")
    #expect(session.folderDisplay == "~/Downloads")
}

@Test(.timeLimit(.minutes(2))) func issue684LifetimeExpiresAfterFiveSeconds() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    let lifetime = CaptureThumbnailLifetime(shownAt: start)
    #expect(CaptureThumbnailLifetime.visibleSeconds == 5)
    #expect(lifetime.deadline == start.addingTimeInterval(5))
    #expect(!lifetime.isExpired(at: start.addingTimeInterval(4.9)))
    #expect(lifetime.isExpired(at: start.addingTimeInterval(5)))
}

@Test(.timeLimit(.minutes(2))) func issue684LifetimeHoverKeepsAndExitRestarts() {
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    var lifetime = CaptureThumbnailLifetime(shownAt: start)
    lifetime.pointerEntered()
    #expect(lifetime.deadline == nil)
    #expect(!lifetime.isExpired(at: start.addingTimeInterval(60)))
    lifetime.pointerExited(at: start.addingTimeInterval(60))
    #expect(!lifetime.isExpired(at: start.addingTimeInterval(64.9)))
    #expect(lifetime.isExpired(at: start.addingTimeInterval(65)))
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ModelSaveThenTrash() async throws {
    let files = RecordingFiles()
    let session = makeSession(files)
    let trash = RecordingTrash()
    let state = CaptureThumbnailState(png: png, savedURL: nil, clipboard: .copied, folderDisplay: "~/Downloads")
    let model = CaptureThumbnailModel(state: state, session: session, clipboard: RecordingClipboard(), trash: trash)
    try await model.save()
    let url = URL(fileURLWithPath: "/Downloads/mado-20261114073012.png")
    #expect(model.state.savedURL == url)
    #expect(model.state.actions == [.copy, .moveToTrash])
    #expect(model.state.status == .saved(folder: "~/Downloads", clipboard: .copied))
    #expect(model.state.dragPayload == .file(url))
    try await model.save()  // already saved: no second file
    #expect(await files.files.count == 1)
    try await model.moveToTrash()
    #expect(await trash.trashed == [url])
    #expect(model.isClosed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ModelTrashWithoutFileDoesNothing() async throws {
    let trash = RecordingTrash()
    let state = CaptureThumbnailState(png: png, savedURL: nil, clipboard: .copied, folderDisplay: "~/Downloads")
    let model = CaptureThumbnailModel(state: state, session: makeSession(RecordingFiles()),
                                      clipboard: RecordingClipboard(), trash: trash)
    try await model.moveToTrash()
    #expect(await trash.trashed.isEmpty)
    #expect(!model.isClosed)
    model.close()
    #expect(model.isClosed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ModelCopyUpdatesClipboardState() async {
    let clipboard = RecordingClipboard()
    let state = CaptureThumbnailState(png: png, savedURL: nil, clipboard: .notCopied, folderDisplay: "~/Downloads")
    let model = CaptureThumbnailModel(state: state, session: makeSession(RecordingFiles()),
                                      clipboard: clipboard, trash: RecordingTrash())
    await model.copy()
    #expect(await clipboard.writes == [png])
    #expect(model.state.status == .notSaved(clipboard: .copied, saveFailed: false))
    let failing = CaptureThumbnailModel(state: state, session: makeSession(RecordingFiles()),
                                        clipboard: RecordingClipboard(succeeds: false), trash: RecordingTrash())
    await failing.copy()
    #expect(failing.state.clipboard == .copyFailed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ModelSaveFailureKeepsSaveAction() async throws {
    let files = RecordingFiles()
    await files.setFailing(true)
    let state = CaptureThumbnailState(png: png, savedURL: nil, clipboard: .notCopied, folderDisplay: "~/Downloads")
    let model = CaptureThumbnailModel(state: state, session: makeSession(files),
                                      clipboard: RecordingClipboard(), trash: RecordingTrash())
    await #expect(throws: CocoaError.self) { try await model.save() }
    #expect(model.state.savedURL == nil)
    #expect(model.state.saveFailed)
    #expect(model.state.actions == [.save, .copy])
    await files.setFailing(false)
    try await model.save()
    #expect(!model.state.saveFailed)
}

@Test(.timeLimit(.minutes(2))) func issue684CaptureModulesHaveNoPermanentDelete() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let folders = ["Sources/MadoApplication/Capture", "Sources/MadoInfrastructure/Capture"]
    var scanned = 0
    for folder in folders {
        let directory = root.appendingPathComponent(folder)
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name.hasSuffix(".swift") {
            let text = try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!text.contains("removeItem"), "\(folder)/\(name)")
            #expect(!text.contains("unlink("), "\(folder)/\(name)")
            scanned += 1
        }
    }
    #expect(scanned >= 5)
}
