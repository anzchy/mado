import Foundation
import Testing
import MadoApplication

// #686 P7-10 CAP-02 fix round 1 (gpt M1 = opus L2): 在 Mado 中打开 clicked while a 存储 write is in flight waits for
// that write and then opens its file; if the write fails, nothing opens and the status line shows it. A second
// 在 Mado 中打开 while one is pending does nothing, so a double click opens once.

private struct Screen686Hold: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data() }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data() }
}

/// Holds each write until the test finishes it.
private actor HeldFiles686: CaptureFilePort {
    private(set) var written: [String] = []
    private(set) var writes = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Bool, Never>?
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        writes += 1
        started?.resume()
        started = nil
        let succeeds = await withCheckedContinuation { release = $0 }
        guard succeeds else { throw CocoaError(.fileWriteNoPermission) }
        written.append(named)
        return URL(fileURLWithPath: "/Captures").appendingPathComponent(named)
    }
    func waitUntilWriting() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(succeeding: Bool) {
        release?.resume(returning: succeeding)
        release = nil
    }
}

/// Holds the first open until the test finishes it, when `holding` is set; later opens return at once.
private actor HeldOpener686: CaptureOpenPort {
    private(set) var opened: [URL] = []
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    let holding: Bool
    init(holding: Bool) { self.holding = holding }
    func openInMado(_ url: URL) async throws {
        opened.append(url)
        guard holding, opened.count == 1 else { return }
        started?.resume()
        started = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilOpening() async {
        if release != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish() {
        release?.resume()
        release = nil
    }
}

private struct Clipboard686Hold: CaptureClipboardPort {
    func writePNG(_ png: Data) async -> Bool { true }
}

private struct Trash686Hold: CaptureTrashPort {
    func moveToTrash(_ url: URL) async throws {}
}

@MainActor private func heldModel(saved: Bool, files: HeldFiles686) -> CaptureThumbnailModel {
    let date = ISO8601DateFormatter().date(from: "2026-11-15T07:30:12Z")!
    let session = CaptureSession(screen: Screen686Hold(), files: files, now: { date },
                                 timeZone: TimeZone(secondsFromGMT: 0)!, folderDisplay: "~/Captures")
    let url = saved ? URL(fileURLWithPath: "/Captures/mado-20261115073000.png") : nil
    let state = CaptureThumbnailState(png: Data([1, 2, 3]), savedURL: url, clipboard: .copied,
                                      folderDisplay: "~/Captures")
    return CaptureThumbnailModel(state: state, session: session, clipboard: Clipboard686Hold(), trash: Trash686Hold())
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686OpenDuringSaveOpensOnceTheWriteFinishes() async throws {
    let files = HeldFiles686()
    let opener = HeldOpener686(holding: false)
    let model = heldModel(saved: false, files: files)
    let saving = Task { try await model.save() }
    await files.waitUntilWriting()
    let first = Task { try await model.openInMado(opener) }
    let second = Task { try await model.openInMado(opener) }
    for _ in 0..<3 { await Task.yield() }
    #expect(await opener.opened.isEmpty, "nothing opens before the write finishes")
    await files.finish(succeeding: true)
    try await saving.value
    try await first.value
    try await second.value
    let url = URL(fileURLWithPath: "/Captures/mado-20261115073012.png")
    #expect(await files.writes == 1)
    #expect(await files.written == ["mado-20261115073012.png"])
    #expect(await opener.opened == [url], "the queued open runs once")
    #expect(model.state.savedURL == url)
    #expect(model.isClosed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686OpenDuringFailedSaveDoesNotOpen() async throws {
    let files = HeldFiles686()
    let opener = HeldOpener686(holding: false)
    let model = heldModel(saved: false, files: files)
    let saving = Task { try await model.save() }
    await files.waitUntilWriting()
    let opening = Task { try await model.openInMado(opener) }
    await Task.yield()
    await files.finish(succeeding: false)
    await #expect(throws: CocoaError.self) { try await saving.value }
    await #expect(throws: CocoaError.self) { try await opening.value }
    #expect(await files.writes == 1)
    #expect(await opener.opened.isEmpty)
    #expect(model.state.status == .notSaved(clipboard: .copied, saveFailed: true))
    #expect(!model.isClosed)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue686DoubleClickOnOpenInMadoOpensOnce() async throws {
    let files = HeldFiles686()
    let opener = HeldOpener686(holding: true)
    let model = heldModel(saved: true, files: files)
    let first = Task { try await model.openInMado(opener) }
    await opener.waitUntilOpening()
    try await model.openInMado(opener)
    await opener.finish()
    try await first.value
    #expect(await opener.opened == [URL(fileURLWithPath: "/Captures/mado-20261115073000.png")])
    #expect(await files.writes == 0)
    #expect(model.isClosed)
}
