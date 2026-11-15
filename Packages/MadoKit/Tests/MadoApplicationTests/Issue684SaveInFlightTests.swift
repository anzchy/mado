import Foundation
import Testing
import MadoApplication

// #684 P7-10 CAP-02 fix round 1 (gpt M2 = opus M3): a double click on 存储 must write one file, not two.

private struct FixedScreen: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data([1]) }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data([1]) }
}

/// Holds every write until `open()`, so two Saves overlap; writes after `open()` go straight through.
private actor GatedFiles: CaptureFilePort {
    private(set) var files: [String: Data] = [:]
    private(set) var calls = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        calls += 1
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        guard files[named] == nil else { throw CaptureFileError.alreadyExists }
        files[named] = data
        return URL(fileURLWithPath: "/Downloads").appendingPathComponent(named)
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

private actor NoClipboard: CaptureClipboardPort {
    func writePNG(_ png: Data) -> Bool { true }
}

private actor TrashLog: CaptureTrashPort {
    private(set) var trashed: [URL] = []
    func moveToTrash(_ url: URL) throws { trashed.append(url) }
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue684ConcurrentSavesWriteOneFile() async throws {
    let files = GatedFiles()
    let trash = TrashLog()
    let session = CaptureSession(screen: FixedScreen(), files: files,
                                 now: { ISO8601DateFormatter().date(from: "2026-11-14T07:30:12Z")! },
                                 timeZone: TimeZone(secondsFromGMT: 0)!)
    let state = CaptureThumbnailState(png: Data([1]), savedURL: nil, clipboard: .copied, folderDisplay: "~/Downloads")
    let model = CaptureThumbnailModel(state: state, session: session, clipboard: NoClipboard(), trash: trash)
    let first = Task { @MainActor in try await model.save() }
    for _ in 0..<10_000 where await files.calls == 0 { await Task.yield() }
    #expect(await files.calls == 1)
    let second = Task { @MainActor in try await model.save() }
    for _ in 0..<200 { await Task.yield() }
    await files.open()
    try await first.value
    try await second.value
    let written = await files.files
    #expect(written.count == 1, "two Saves wrote \(written.keys.sorted())")
    #expect(await files.calls == 1)
    let url = try #require(model.state.savedURL)
    #expect(written.keys.sorted() == [url.lastPathComponent])
    try await model.moveToTrash()
    #expect(await trash.trashed == [url])
    #expect(model.isClosed)
}
