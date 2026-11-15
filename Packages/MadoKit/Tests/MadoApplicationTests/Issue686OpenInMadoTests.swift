import Foundation
import Testing
import MadoApplication

// #686 P7-10 CAP-02: 在 Mado 中打开 on the Capture Thumbnail. Order from the pinned
// design/prototypes/picsee-browser/states/capture-thumbnail.html:19-20 (拷贝, 标注, 在 Mado 中打开, 识别文字, 移到废纸篓;
// save off: 存储 first, no 移到废纸篓). 标注 (#694) and 识别文字 (#687) are not shown yet.

private struct Screen686: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data() }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data() }
}

private actor Files686: CaptureFilePort {
    private(set) var written: [String] = []
    var failing = false
    func writeNewPNG(_ data: Data, named: String) throws -> URL {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        written.append(named)
        return URL(fileURLWithPath: "/Captures").appendingPathComponent(named)
    }
    func setFailing(_ value: Bool) { failing = value }
}

private actor Clipboard686: CaptureClipboardPort {
    func writePNG(_ png: Data) -> Bool { true }
}

private actor Trash686: CaptureTrashPort {
    func moveToTrash(_ url: URL) throws {}
}

private actor Opener686: CaptureOpenPort {
    private(set) var opened: [URL] = []
    private(set) var filesAtOpen: [[String]] = []
    let files: Files686
    var failing = false
    init(files: Files686) { self.files = files }
    func openInMado(_ url: URL) async throws {
        filesAtOpen.append(await files.written)
        if failing { throw CocoaError(.fileReadNoPermission) }
        opened.append(url)
    }
    func setFailing(_ value: Bool) { failing = value }
}

private let png686 = Data([137, 80, 78, 71, 13, 10, 26, 10, 6])
private let date686 = ISO8601DateFormatter().date(from: "2026-11-15T07:30:12Z")!

@MainActor private func model686(saved: Bool, files: Files686) -> CaptureThumbnailModel {
    let session = CaptureSession(screen: Screen686(), files: files, now: { date686 },
                                 timeZone: TimeZone(secondsFromGMT: 0)!, folderDisplay: "~/Captures")
    let url = saved ? URL(fileURLWithPath: "/Captures/mado-20261115073000.png") : nil
    let state = CaptureThumbnailState(png: png686, savedURL: url, clipboard: .copied, folderDisplay: "~/Captures")
    return CaptureThumbnailModel(state: state, session: session, clipboard: Clipboard686(), trash: Trash686())
}

@Test(.timeLimit(.minutes(2))) func issue686SavedActionsFollowTheDesignOrder() {
    let saved = CaptureThumbnailState(png: png686, savedURL: URL(fileURLWithPath: "/Captures/a.png"), clipboard: .copied,
                                      folderDisplay: "~/Captures")
    let unsaved = CaptureThumbnailState(png: png686, savedURL: nil, clipboard: .copied, folderDisplay: "~/Captures")
    #expect(saved.actions == [.copy, .openInMado, .moveToTrash])
    #expect(unsaved.actions == [.save, .copy, .openInMado])
    #expect(CaptureThumbnailAction.openInMado.rawValue == "openInMado")
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686OpenSavedCaptureOpensItsFileAndCloses() async throws {
    let files = Files686()
    let opener = Opener686(files: files)
    let model = model686(saved: true, files: files)
    try await model.openInMado(opener)
    #expect(await opener.opened == [URL(fileURLWithPath: "/Captures/mado-20261115073000.png")])
    #expect(await files.written.isEmpty, "a saved Capture is not written again")
    #expect(model.isClosed)
}

/// Decision 3.5: with saving off, 在 Mado 中打开 first saves the Capture to the Capture Folder (the 存储 path,
/// one file, #682 naming), then opens that file.
@MainActor @Test(.timeLimit(.minutes(2))) func issue686OpenUnsavedCaptureSavesOnceThenOpens() async throws {
    let files = Files686()
    let opener = Opener686(files: files)
    let model = model686(saved: false, files: files)
    try await model.openInMado(opener)
    let url = URL(fileURLWithPath: "/Captures/mado-20261115073012.png")
    #expect(await files.written == ["mado-20261115073012.png"])
    #expect(await opener.filesAtOpen == [["mado-20261115073012.png"]], "written before it is opened")
    #expect(await opener.opened == [url])
    #expect(model.state.savedURL == url)
    #expect(model.isClosed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686SaveFailureDoesNotOpen() async throws {
    let files = Files686()
    await files.setFailing(true)
    let opener = Opener686(files: files)
    let model = model686(saved: false, files: files)
    await #expect(throws: CocoaError.self) { try await model.openInMado(opener) }
    #expect(await opener.opened.isEmpty)
    #expect(await opener.filesAtOpen.isEmpty)
    #expect(model.state.saveFailed)
    #expect(model.state.status == .notSaved(clipboard: .copied, saveFailed: true))
    #expect(!model.isClosed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686OpenFailureKeepsTheThumbnail() async throws {
    let files = Files686()
    let opener = Opener686(files: files)
    await opener.setFailing(true)
    let model = model686(saved: true, files: files)
    await #expect(throws: CocoaError.self) { try await model.openInMado(opener) }
    #expect(!model.isClosed)
    #expect(model.state.savedURL != nil)
}

/// The helper is embedded at Mado.app/Contents/Library/LoginItems (project.yml); Mado is the enclosing app, found from
/// the helper's own location, never by bundle id.
@Test(.timeLimit(.minutes(2))) func issue686MadoAppIsTheBundleEnclosingTheHelper() {
    let helper = URL(fileURLWithPath: "/Applications/Mado.app/Contents/Library/LoginItems/MadoCaptureHelper.app",
                     isDirectory: true)
    #expect(CaptureMadoLocation.madoApp(containingHelper: helper)?.path == "/Applications/Mado.app")
    let build = URL(fileURLWithPath: "/tmp/dd/Build/Products/Debug/Mado copy.app/Contents/Library/LoginItems/H.app/")
    #expect(CaptureMadoLocation.madoApp(containingHelper: build)?.path == "/tmp/dd/Build/Products/Debug/Mado copy.app")
    for loose in ["/Applications/MadoCaptureHelper.app", "/Applications/Mado.app/Contents/Library/Other/H.app",
                  "/Applications/Mado.app/Contents/Helpers/LoginItems/H.app", "/Apps/Mado/Contents/Library/LoginItems/H.app",
                  "/Applications/Mado.app/Contents/Library/LoginItems/H"] {
        #expect(CaptureMadoLocation.madoApp(containingHelper: URL(fileURLWithPath: loose)) == nil, "\(loose)")
    }
}
