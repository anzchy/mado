import Foundation
import Testing
import MadoApplication

// #686 P7-10 CAP-02 fix round 2 (gpt confirm M1): once 在 Mado 中打开 has succeeded and the thumbnail is closed, a
// later Open (a second click queued behind a fast first open) does nothing, so the file is launched once.

private struct Screen686After: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data() }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data() }
}

private actor Files686After: CaptureFilePort {
    private(set) var writes = 0
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        writes += 1
        return URL(fileURLWithPath: "/Captures").appendingPathComponent(named)
    }
}

private actor Opener686After: CaptureOpenPort {
    private(set) var opened: [URL] = []
    func openInMado(_ url: URL) async throws { opened.append(url) }
}

private struct Clipboard686After: CaptureClipboardPort {
    func writePNG(_ png: Data) async -> Bool { true }
}

private struct Trash686After: CaptureTrashPort {
    func moveToTrash(_ url: URL) async throws {}
}

@MainActor private func afterModel(saved: Bool, files: Files686After) -> CaptureThumbnailModel {
    let date = ISO8601DateFormatter().date(from: "2026-11-15T07:30:12Z")!
    let session = CaptureSession(screen: Screen686After(), files: files, now: { date },
                                 timeZone: TimeZone(secondsFromGMT: 0)!, folderDisplay: "~/Captures")
    let url = saved ? URL(fileURLWithPath: "/Captures/mado-20261115073000.png") : nil
    let state = CaptureThumbnailState(png: Data([1, 2, 3]), savedURL: url, clipboard: .copied,
                                      folderDisplay: "~/Captures")
    return CaptureThumbnailModel(state: state, session: session, clipboard: Clipboard686After(),
                                 trash: Trash686After())
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686OpenAfterASuccessfulOpenDoesNothing() async throws {
    for saved in [true, false] {
        let files = Files686After()
        let opener = Opener686After()
        let model = afterModel(saved: saved, files: files)
        try await model.openInMado(opener)
        #expect(model.isClosed)
        try await model.openInMado(opener)
        #expect(await opener.opened.count == 1, "saved=\(saved): the second Open launches nothing")
        #expect(await files.writes == (saved ? 0 : 1))
    }
}

/// Holds the write until the test finishes it.
private actor HeldFiles686After: CaptureFilePort {
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        started?.resume()
        started = nil
        await withCheckedContinuation { release = $0 }
        return URL(fileURLWithPath: "/Captures").appendingPathComponent(named)
    }
    func waitUntilWriting() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        release?.resume()
        release = nil
    }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686ThumbnailClosedDuringTheWriteOpensNothing() async throws {
    let files = HeldFiles686After()
    let opener = Opener686After()
    let date = ISO8601DateFormatter().date(from: "2026-11-15T07:30:12Z")!
    let session = CaptureSession(screen: Screen686After(), files: files, now: { date },
                                 timeZone: TimeZone(secondsFromGMT: 0)!, folderDisplay: "~/Captures")
    let state = CaptureThumbnailState(png: Data([1, 2, 3]), savedURL: nil, clipboard: .copied,
                                      folderDisplay: "~/Captures")
    let model = CaptureThumbnailModel(state: state, session: session, clipboard: Clipboard686After(),
                                      trash: Trash686After())
    let opening = Task { try await model.openInMado(opener) }
    await files.waitUntilWriting()
    model.close()
    await files.finish()
    try await opening.value
    #expect(await opener.opened.isEmpty, "the thumbnail was closed while its file was being written")
    #expect(model.state.savedURL == URL(fileURLWithPath: "/Captures/mado-20261115073012.png"))
}
