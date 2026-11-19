import Foundation
import Testing
import MadoApplication

// #694 P7-11 CAP-02 WI-1: 标注 on the Capture Thumbnail. It saves an unsaved Capture first (decision 3.5), leaves the
// one-shot Annotate hand-off record, then opens the file in Mado through the #686 path; it shares 在 Mado 中打开's
// guards, so one click pattern gives one write, one record and one open.

private struct Screen694: CaptureScreenPort {
    func captureCurrentDisplayPNG() async throws -> Data { Data() }
    func capturePNG(request: CaptureRequest) async throws -> Data { Data() }
}

private struct Clipboard694: CaptureClipboardPort {
    func writePNG(_ png: Data) async -> Bool { true }
}

private actor Trash694: CaptureTrashPort {
    private(set) var trashed: [URL] = []
    func moveToTrash(_ url: URL) async throws { trashed.append(url) }
}

/// Writes at once; `existing` names already in the folder (the #682 unique-name rule), `failing` refuses every write.
private actor Files694: CaptureFilePort {
    private(set) var written: [String] = []
    private(set) var attempts: [String] = []
    let existing: Set<String>
    let failing: Bool
    init(existing: Set<String> = [], failing: Bool = false) { self.existing = existing; self.failing = failing }
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        attempts.append(named)
        if failing { throw CocoaError(.fileWriteNoPermission) }
        if existing.contains(named) { throw CaptureFileError.alreadyExists }
        written.append(named)
        return URL(fileURLWithPath: "/Captures").appendingPathComponent(named)
    }
}

/// Holds each write until the test finishes it.
private actor HeldFiles694: CaptureFilePort {
    private(set) var written: [String] = []
    private(set) var writes = 0
    private var release: CheckedContinuation<Bool, Never>?
    var isWriting: Bool { release != nil }
    func writeNewPNG(_ data: Data, named: String) async throws -> URL {
        writes += 1
        let succeeds = await withCheckedContinuation { release = $0 }
        guard succeeds else { throw CocoaError(.fileWriteNoPermission) }
        written.append(named)
        return URL(fileURLWithPath: "/Captures").appendingPathComponent(named)
    }
    func finish(succeeding: Bool) {
        release?.resume(returning: succeeding)
        release = nil
    }
}

/// The App Group record store, recording every call in order.
final class Handoff694: CaptureAnnotateHandoffPort, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CaptureAnnotateHandoffRecord?
    private var log: [String] = []
    private var writes: [CaptureAnnotateHandoffRecord] = []
    var record: CaptureAnnotateHandoffRecord? { lock.withLock { stored } }
    var calls: [String] { lock.withLock { log } }
    var written: [CaptureAnnotateHandoffRecord] { lock.withLock { writes } }
    func write(_ record: CaptureAnnotateHandoffRecord) {
        lock.withLock { stored = record; writes.append(record); log.append("write") }
    }
    func clear() { lock.withLock { stored = nil; log.append("clear") } }
    func take() -> CaptureAnnotateHandoffRecord? {
        lock.withLock { defer { stored = nil }; log.append("take"); return stored }
    }
}

/// Records, at the moment of each open, which files had been written and which record the store held.
private actor Opener694: CaptureOpenPort {
    private(set) var opened: [URL] = []
    private(set) var writtenAtOpen: [[String]] = []
    private(set) var recordAtOpen: [CaptureAnnotateHandoffRecord?] = []
    let files: Files694?
    let handoff: Handoff694
    let failing: Bool
    init(files: Files694? = nil, handoff: Handoff694, failing: Bool = false) {
        self.files = files; self.handoff = handoff; self.failing = failing
    }
    func openInMado(_ url: URL) async throws {
        writtenAtOpen.append(await files?.written ?? [])
        recordAtOpen.append(handoff.record)
        if failing { throw CocoaError(.fileReadNoPermission) }
        opened.append(url)
    }
}

/// Holds the first open until the test finishes it; later opens return at once.
private actor HeldOpener694: CaptureOpenPort {
    private(set) var opened: [URL] = []
    private var release: CheckedContinuation<Void, Never>?
    var isOpening: Bool { release != nil }
    func openInMado(_ url: URL) async throws {
        opened.append(url)
        guard opened.count == 1 else { return }
        await withCheckedContinuation { release = $0 }
    }
    func finish() {
        release?.resume()
        release = nil
    }
}

/// Bounded wait: a hold that never starts records an issue instead of hanging the run.
@MainActor private func eventually694(_ what: String, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<5_000 {
        if await condition() { return true }
        await Task.yield()
    }
    Issue.record("never happened: \(what)")
    return false
}

private let captureDate694 = ISO8601DateFormatter().date(from: "2026-11-13T14:05:32Z")!
private let clickDate694 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let savedURL694 = URL(fileURLWithPath: "/Captures/mado-20261113140000.png")

@MainActor private func model694(saved: Bool, files: any CaptureFilePort, trash: Trash694 = Trash694())
    -> CaptureThumbnailModel {
    let session = CaptureSession(screen: Screen694(), files: files, now: { captureDate694 },
                                 timeZone: TimeZone(secondsFromGMT: 0)!, folderDisplay: "~/Captures")
    let state = CaptureThumbnailState(png: Data([1, 2, 3]), savedURL: saved ? savedURL694 : nil, clipboard: .copied,
                                      folderDisplay: "~/Captures")
    return CaptureThumbnailModel(state: state, session: session, clipboard: Clipboard694(), trash: trash)
}

@Test func issue694ThumbnailActionsIncludeAnnotateInDesignOrder() {
    // capture-thumbnail.html:19-20 and :125: 标注 sits between 拷贝 and 在 Mado 中打开 in both cases.
    let unsaved = CaptureThumbnailState(png: Data(), savedURL: nil, clipboard: .copied, folderDisplay: "~/Downloads")
    let saved = CaptureThumbnailState(png: Data(), savedURL: savedURL694, clipboard: .copied, folderDisplay: "~/Downloads")
    #expect(unsaved.actions == [.save, .copy, .annotate, .openInMado])
    #expect(saved.actions == [.copy, .annotate, .openInMado, .moveToTrash])
    #expect(CaptureThumbnailAction.annotate.rawValue == "annotate")
}

/// AC-3: with saving off the Capture is written to the Capture Folder by `CaptureSession.save` exactly once, under the
/// #682 unique name, before the record is left and before the open.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateSaveOffWritesThenOpens() async throws {
    let files = Files694(existing: ["mado-20261113140532.png"])
    let handoff = Handoff694()
    let opener = Opener694(files: files, handoff: handoff)
    let model = model694(saved: false, files: files)
    try await model.annotateInMado(opener, handoff: handoff, now: { clickDate694 })
    let expected = URL(fileURLWithPath: "/Captures/mado-20261113140532-2.png")
    #expect(await files.attempts == ["mado-20261113140532.png", "mado-20261113140532-2.png"])
    #expect(await files.written == ["mado-20261113140532-2.png"])
    #expect(await opener.opened == [expected])
    #expect(await opener.writtenAtOpen == [["mado-20261113140532-2.png"]], "the file existed when Mado was asked to open it")
    #expect(await opener.recordAtOpen == [CaptureAnnotateHandoffRecord(fileURL: expected, createdAt: clickDate694)],
            "the record named the file before the open")
    #expect(handoff.calls == ["write"])
    #expect(model.state.savedURL == expected)
    #expect(model.isClosed)
    #expect(!model.isOpeningInMado)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateOpensSavedFileOnceWithRecord() async throws {
    let files = Files694()
    let handoff = Handoff694()
    let opener = Opener694(files: files, handoff: handoff)
    let model = model694(saved: true, files: files)
    try await model.annotateInMado(opener, handoff: handoff, now: { clickDate694 })
    #expect(await files.attempts.isEmpty)
    #expect(await opener.opened == [savedURL694])
    #expect(handoff.written == [CaptureAnnotateHandoffRecord(fileURL: savedURL694, createdAt: clickDate694)])
    #expect(handoff.record == handoff.written.first, "a successful open leaves the record for Mado")
    #expect(model.isClosed)
}

/// 在 Mado 中打开 leaves no record, so Mado opens that file for viewing only.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694OpenInMadoLeavesNoRecord() async throws {
    let handoff = Handoff694()
    let opener = Opener694(handoff: handoff)
    let model = model694(saved: true, files: Files694())
    try await model.openInMado(opener)
    #expect(await opener.opened == [savedURL694])
    #expect(handoff.calls.isEmpty)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateSaveFailureDoesNotOpen() async throws {
    let files = Files694(failing: true)
    let handoff = Handoff694()
    let opener = Opener694(files: files, handoff: handoff)
    let model = model694(saved: false, files: files)
    await #expect(throws: (any Error).self) { try await model.annotateInMado(opener, handoff: handoff) }
    #expect(await opener.opened.isEmpty)
    #expect(await opener.recordAtOpen.isEmpty)
    #expect(handoff.calls.isEmpty, "no record without a file")
    #expect(model.state.saveFailed)
    #expect(model.state.actions == [.save, .copy, .annotate, .openInMado], "存储 and 标注 stay offered")
    #expect(!model.isClosed)
    #expect(!model.isOpeningInMado)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateOpenFailureClearsRecord() async throws {
    let handoff = Handoff694()
    let opener = Opener694(handoff: handoff, failing: true)
    let model = model694(saved: true, files: Files694())
    await #expect(throws: (any Error).self) { try await model.annotateInMado(opener, handoff: handoff) }
    #expect(await opener.recordAtOpen.count == 1)
    #expect(handoff.calls == ["write", "clear"])
    #expect(handoff.record == nil, "a failed open leaves nothing for a later open to pick up")
    #expect(!model.isClosed, "the thumbnail stays")
    #expect(!model.isOpeningInMado)
}

/// Two 标注 clicks, or 存储 then 标注, while the write is in flight: one file, one record, one open.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateDoubleClickOpensOnce() async throws {
    for saveFirst in [false, true] {
        let files = HeldFiles694()
        let handoff = Handoff694()
        let opener = Opener694(handoff: handoff)
        let model = model694(saved: false, files: files)
        let first = Task { @MainActor in
            if saveFirst { try await model.save() } else { try await model.annotateInMado(opener, handoff: handoff) }
        }
        guard await eventually694("write in flight", { await files.isWriting }) else { return }
        let second = Task { @MainActor in try await model.annotateInMado(opener, handoff: handoff) }
        let third = Task { @MainActor in try await model.annotateInMado(opener, handoff: handoff) }
        for _ in 0..<50 { await Task.yield() }
        #expect(model.isOpeningInMado)
        await files.finish(succeeding: true)
        try await first.value
        try await second.value
        try await third.value
        #expect(await files.writes == 1)
        #expect(await opener.opened == [URL(fileURLWithPath: "/Captures/mado-20261113140532.png")])
        #expect(handoff.written.count == 1)
        #expect(model.isClosed)
    }
}

/// 标注 then 在 Mado 中打开 (and the reverse) while the first open is pending: one open in total, and the first
/// click decides whether Mado annotates.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694AnnotateAndOpenShareOneOpen() async throws {
    for annotateFirst in [true, false] {
        let handoff = Handoff694()
        let opener = HeldOpener694()
        let model = model694(saved: true, files: Files694())
        let first = Task { @MainActor in
            if annotateFirst { try await model.annotateInMado(opener, handoff: handoff) }
            else { try await model.openInMado(opener) }
        }
        guard await eventually694("open in flight", { await opener.isOpening }) else { return }
        #expect(model.isOpeningInMado)
        if annotateFirst { try await model.openInMado(opener) }
        else { try await model.annotateInMado(opener, handoff: handoff) }
        await opener.finish()
        try await first.value
        #expect(await opener.opened == [savedURL694])
        #expect(handoff.written.count == (annotateFirst ? 1 : 0))
        #expect(model.isClosed)
    }
}

/// AC-4: 移到废纸篓 while an open is pending does nothing, so Mado is never handed a file just moved to the Trash.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694TrashIgnoredWhileOpenPending() async throws {
    let trash = Trash694()
    let handoff = Handoff694()
    let opener = HeldOpener694()
    let model = model694(saved: true, files: Files694(), trash: trash)
    let pending = Task { @MainActor in try await model.annotateInMado(opener, handoff: handoff) }
    guard await eventually694("open in flight", { await opener.isOpening }) else { return }
    try await model.moveToTrash()
    #expect(await trash.trashed.isEmpty)
    #expect(!model.isClosed)
    await opener.finish()
    try await pending.value
    #expect(model.isClosed)
    // Without a pending open, 移到废纸篓 still works.
    let idle = model694(saved: true, files: Files694(), trash: trash)
    try await idle.moveToTrash()
    #expect(await trash.trashed == [savedURL694])
}

/// A new Capture replaces the thumbnail while 标注's write is in flight: the file stays, nothing opens and no record
/// is left behind.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694ReplacedThumbnailLeavesNoRecord() async throws {
    let files = HeldFiles694()
    let handoff = Handoff694()
    let opener = Opener694(handoff: handoff)
    let model = model694(saved: false, files: files)
    let pending = Task { @MainActor in try await model.annotateInMado(opener, handoff: handoff) }
    guard await eventually694("write in flight", { await files.isWriting }) else { return }
    model.close()
    await files.finish(succeeding: true)
    try await pending.value
    #expect(await files.written == ["mado-20261113140532.png"])
    #expect(await opener.opened.isEmpty)
    #expect(handoff.calls.isEmpty)
}

/// The record compares resolved paths, so a Capture Folder reached through a symlink names the same file on both sides.
@Test func issue694RecordResolvesSymlinks() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("issue694-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let file = real.appendingPathComponent("mado-20261113140532.png")
    try Data([1]).write(to: file)
    let viaLink = CaptureAnnotateHandoffRecord(fileURL: link.appendingPathComponent("./mado-20261113140532.png"),
                                               createdAt: clickDate694)
    let direct = CaptureAnnotateHandoffRecord(fileURL: file, createdAt: clickDate694)
    #expect(viaLink == direct)
    #expect(!viaLink.path.contains("/link/"))
    #expect(!viaLink.path.contains("/./"))
}
