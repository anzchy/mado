import CoreGraphics
import Foundation
import Testing
import UniformTypeIdentifiers
import MadoCore
@testable import MadoApplication

// #694 P7-11 WI-2: Mado takes the thumbnail's one-shot hand-off record when the open arrives, and enters Annotate
// Mode on that file once it shows; the intent never carries over to another image.

@MainActor private final class Host694: AnnotateSaveHost {
    var hasImage = true
    func performCanvas(_ command: CommandID, from entry: CommandEntry) {}
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() {}
    func applyFocus(_ focus: FocusContext) {}
    func showInspector(_ visible: Bool) {}
    func presentGridItem(_ id: ItemID) {}
    func returnToGrid() {}
    func performAnnotatedCopySave(_ request: AnnotateSaveRequest) {}
}

/// Records the handoff calls; `take` reads and removes like the App Group store.
private final class Store694: CaptureAnnotateHandoffPort, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: CaptureAnnotateHandoffRecord?
    init(_ record: CaptureAnnotateHandoffRecord? = nil) { stored = record }
    var record: CaptureAnnotateHandoffRecord? { lock.withLock { stored } }
    func write(_ record: CaptureAnnotateHandoffRecord) { lock.withLock { stored = record } }
    func clear() { lock.withLock { stored = nil } }
    func take() -> CaptureAnnotateHandoffRecord? { lock.withLock { defer { stored = nil }; return stored } }
}

private let written694 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let capture694 = URL(fileURLWithPath: "/Users/u/Downloads/mado-20261113140532.png")

@MainActor private struct Viewer694 {
    let session: ViewerSession
    let host = Host694()
    let loadHost = LoadHost()
    static var keepAlive: [AnyObject] = []

    init() {
        session = ViewerSession(host: host)
        session.imageLoader.host = loadHost
        Self.keepAlive += [host, loadHost]
    }

    func open(_ url: URL, failing: Bool = false, slow: Bool = false) {
        session.openImage(url, maximumPixelSize: 512) {
            if failing { throw CocoaError(.fileReadCorruptFile) }
            if slow { try await Task.sleep(for: .seconds(60)) }
            return try await AccessImageSource.open(.fileGrant(url), access: LoadLeases(), pipeline: LoadPipeline())
        }
    }

    func settle() async { await session.imageLoader.loadTask?.value }
}

// MARK: - The hand-off record

@Test func issue694RecordMatchesTheOpenedFileOnce() {
    let store = Store694(CaptureAnnotateHandoffRecord(fileURL: capture694, createdAt: written694))
    #expect(CaptureAnnotateHandoff.consume(store, opened: [capture694], now: written694.addingTimeInterval(3)) == capture694)
    #expect(store.record == nil, "used once")
    #expect(CaptureAnnotateHandoff.consume(store, opened: [capture694], now: written694.addingTimeInterval(4)) == nil)
}

/// The freshness window, pinned on both sides; a record from the future (clock changed) is not honoured.
@Test func issue694StaleRecordIsIgnored() {
    let window = CaptureAnnotateHandoff.freshness
    #expect(window == 60)
    for (age, honoured) in [(0.0, true), (window, true), (window + 0.001, false), (window + 3600, false), (-1.0, false)] {
        let store = Store694(CaptureAnnotateHandoffRecord(fileURL: capture694, createdAt: written694))
        let target = CaptureAnnotateHandoff.consume(store, opened: [capture694], now: written694.addingTimeInterval(age))
        #expect((target != nil) == honoured, "age \(age)")
        #expect(store.record == nil, "age \(age): a matched or stale record is removed")
    }
}

/// Another open (a Finder double-click, a second Mado open) never annotates; a fresh record for another file is left for
/// its own open, which Launch Services delivers next.
@Test func issue694RecordForOtherFileIsIgnored() {
    let record = CaptureAnnotateHandoffRecord(fileURL: capture694, createdAt: written694)
    let other = URL(fileURLWithPath: "/Users/u/Pictures/trip.png")
    let store = Store694(record)
    #expect(CaptureAnnotateHandoff.consume(store, opened: [other], now: written694.addingTimeInterval(1)) == nil)
    #expect(store.record == record)
    #expect(CaptureAnnotateHandoff.consume(store, opened: [capture694, other], now: written694.addingTimeInterval(1)) == nil,
            "several files at once are a Preview Set, not the Capture")
    #expect(CaptureAnnotateHandoff.consume(store, opened: [], now: written694.addingTimeInterval(1)) == nil)
    #expect(CaptureAnnotateHandoff.consume(store, opened: [capture694], now: written694.addingTimeInterval(2)) == capture694)
    #expect(CaptureAnnotateHandoff.consume(Store694(), opened: [capture694], now: written694) == nil, "no record, no annotate")
}

@Test func issue694RecordMatchesThroughSymlink() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("issue694-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let real = base.appendingPathComponent("Captures")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = base.appendingPathComponent("Linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let file = real.appendingPathComponent("mado-20261113140532.png")
    try Data([1]).write(to: file)
    let opened = link.appendingPathComponent("mado-20261113140532.png")
    let store = Store694(CaptureAnnotateHandoffRecord(fileURL: file, createdAt: written694))
    #expect(CaptureAnnotateHandoff.consume(store, opened: [opened], now: written694) == opened)
}

// MARK: - The decision

@Test func issue694DecisionTable() {
    let a = "/c/a.png", b = "/c/b.png", c = "/c/c.png"
    func decide(_ shown: String?, _ status: ViewerImageStatus, canEnter: Bool = true, baseline: String? = b,
                seen: Bool = false) -> (AnnotateOnShowDecision, Bool) {
        var intent = AnnotateOnShowIntent(path: a, baseline: baseline)
        if seen { intent.seen = true }
        let decision = intent.decide(shown: shown, status: status, canEnter: canEnter)
        return (decision, intent.seen)
    }
    // The intent's file.
    #expect(decide(a, .showing) == (.enter, true))
    #expect(decide(a, .detailLimited) == (.enter, true))
    #expect(decide(a, .showing, canEnter: false) == (.wait, true), "shown but not admitted yet (focus, sheet)")
    #expect(decide(a, .loading("a.png")) == (.wait, true))
    #expect(decide(a, .readingFolder) == (.wait, true))
    #expect(decide(a, .failed(.corruptImage, "a.png")).0 == .drop)
    #expect(decide(a, .failed(.access, "a.png")).0 == .drop)
    #expect(decide(a, .empty).0 == .drop, "cancelled")
    // Before the open reaches the loader: the image already on screen (or none) does not count.
    #expect(decide(b, .showing).0 == .wait)
    #expect(decide(nil, .empty, baseline: nil).0 == .wait)
    #expect(decide(b, .showing, baseline: nil).0 == .drop, "cold launch: any other image is another open")
    #expect(decide(c, .loading("c.png")).0 == .drop, "another image")
    // After the intent's file was loaded, anything else drops it.
    #expect(decide(b, .showing, seen: true).0 == .drop)
    #expect(decide(nil, .empty, seen: true).0 == .drop)
}

// MARK: - The session

@MainActor @Test(.timeLimit(.minutes(2))) func issue694ViewerSessionEntersAnnotateWhenIntentImageShows() async {
    // Cold: nothing on screen.
    let cold = Viewer694()
    cold.session.requestAnnotateOnShow(capture694)
    #expect(cold.session.annotateOnShow?.path == CaptureAnnotateHandoff.resolvedPath(capture694))
    #expect(!cold.session.applyAnnotateOnShow())
    cold.open(capture694)
    await cold.settle()
    #expect(cold.session.imageStatus == .showing)
    #expect(cold.session.applyAnnotateOnShow())
    #expect(cold.session.isAnnotating)
    #expect(cold.session.annotateMode?.fileURL == capture694)
    #expect(cold.session.annotateOnShow == nil, "used up")

    // Warm: another image shows while the Capture is opened.
    let warm = Viewer694()
    let other = URL(fileURLWithPath: "/Users/u/Pictures/trip.png")
    warm.open(other)
    await warm.settle()
    warm.session.requestAnnotateOnShow(capture694)
    #expect(warm.session.annotateOnShow?.baseline == CaptureAnnotateHandoff.resolvedPath(other))
    #expect(!warm.session.applyAnnotateOnShow())
    #expect(warm.session.annotateOnShow != nil, "the old image is not another open")
    warm.open(capture694)
    await warm.settle()
    #expect(warm.session.applyAnnotateOnShow())
    #expect(warm.session.annotateMode?.fileURL == capture694)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694IntentDroppedOnOtherOpen() async {
    let viewer = Viewer694()
    viewer.session.requestAnnotateOnShow(capture694)
    let other = URL(fileURLWithPath: "/Users/u/Pictures/trip.png")
    viewer.open(other)
    await viewer.settle()
    #expect(!viewer.session.applyAnnotateOnShow())
    #expect(viewer.session.annotateOnShow == nil)
    #expect(!viewer.session.isAnnotating)
    // The Capture opened later, without a new intent, is only viewed.
    viewer.open(capture694)
    await viewer.settle()
    #expect(!viewer.session.applyAnnotateOnShow())
    #expect(!viewer.session.isAnnotating)
}

/// The Capture starts loading, then another image is opened before it shows: only the intent's file may enter, and
/// the other image stays plain.
@MainActor @Test(.timeLimit(.minutes(2))) func issue694StaleLoadCannotEnterAnnotate() async {
    let viewer = Viewer694()
    viewer.session.requestAnnotateOnShow(capture694)
    viewer.open(capture694, slow: true)
    #expect(viewer.session.annotateOnShowDecision(canEnter: true) == .wait)
    #expect(viewer.session.annotateOnShow?.seen == true)
    let other = URL(fileURLWithPath: "/Users/u/Pictures/trip.png")
    viewer.open(other)
    await viewer.settle()
    #expect(viewer.session.imageStatus == .showing)
    #expect(!viewer.session.applyAnnotateOnShow())
    #expect(viewer.session.annotateOnShow == nil)
    #expect(!viewer.session.isAnnotating)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694LoadFailureDropsIntent() async {
    let viewer = Viewer694()
    viewer.session.requestAnnotateOnShow(capture694)
    viewer.open(capture694, failing: true)
    await viewer.settle()
    #expect(viewer.session.annotateOnShowDecision(canEnter: true) == .drop)
    #expect(viewer.session.annotateOnShow == nil)
    #expect(!viewer.session.isAnnotating)
}

@MainActor @Test(.timeLimit(.minutes(2))) func issue694DropAndReplaceIntent() async {
    let viewer = Viewer694()
    viewer.session.requestAnnotateOnShow(capture694)
    viewer.session.dropAnnotateOnShow()
    #expect(viewer.session.annotateOnShow == nil)
    viewer.open(capture694)
    await viewer.settle()
    #expect(!viewer.session.applyAnnotateOnShow())
    #expect(!viewer.session.isAnnotating)
    // A new request replaces the old one.
    let first = URL(fileURLWithPath: "/Users/u/Downloads/one.png")
    viewer.session.requestAnnotateOnShow(first)
    viewer.session.requestAnnotateOnShow(capture694)
    #expect(viewer.session.annotateOnShow?.path == CaptureAnnotateHandoff.resolvedPath(capture694))
    #expect(viewer.session.applyAnnotateOnShow(), "the Capture already shows")
}

/// AC-5: ⌘S on a Capture plans `<capture name>-annotated.png` next to it, `-annotated-2` after that; a Capture
/// with the #682 collision suffix keeps it in the stem.
@Test func issue694CaptureNameGetsAnnotatedSuffix() {
    let writable: Set = [UTType.png]
    #expect(AnnotatedCopyPlan.name(for: "mado-20261113140532.png", existing: ["mado-20261113140532.png"],
                                   writableTypes: writable).name == "mado-20261113140532-annotated.png")
    #expect(AnnotatedCopyPlan.name(for: "mado-20261113140532.png",
                                   existing: ["mado-20261113140532.png", "mado-20261113140532-annotated.png"],
                                   writableTypes: writable).name == "mado-20261113140532-annotated-2.png")
    #expect(AnnotatedCopyPlan.name(for: "mado-20261113140532-2.png", existing: [], writableTypes: writable).name
            == "mado-20261113140532-2-annotated.png")
}
