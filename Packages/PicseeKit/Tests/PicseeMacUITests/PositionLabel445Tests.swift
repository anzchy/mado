import AppKit
import Testing
import PicseeCore
@testable import PicseeApplication
@testable import PicseeMacUI

private actor Position445Scanner: FolderScanning {
    private var held = false
    private var fails = false
    private var ending: CheckedContinuation<Void, Never>?
    private var arrival: CheckedContinuation<Void, Never>?
    func configure(held: Bool, fails: Bool = false) { self.held = held; self.fails = fails }
    func scan(in folder: URL, root: ItemIdentityRoot, options: FolderScanOptions,
              emit: @Sendable ([FolderEntry]) async throws -> Void) async throws {
        var names = ["c.png", "a.png", "b.jpg"]
        if options.recursive { names.append("child/d.png") }
        try await emit(names.map { FolderEntry(url: folder.appendingPathComponent($0), root: root) })
        if held { await withCheckedContinuation { ending = $0; arrival?.resume(); arrival = nil } }
        try Task.checkCancellation()
        if fails { throw CocoaError(.fileReadUnknown) }
    }
    func entered() async {
        if ending == nil { await withCheckedContinuation { arrival = $0 } }
    }
    func finish() { ending?.resume(); ending = nil; held = false }
}

@MainActor private final class Position445Host: FolderScanHost {
    let scene: StatesScene
    let pipeline = StatesPipeline(), leases = StatesLeases()
    init(scene: StatesScene) { self.scene = scene }
    func openFolderImage(_ url: URL, rootID: AccessRootID) {
        scene.open(url, pipeline: pipeline, leases: leases)
    }
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws {}
}

@MainActor private final class Position445Scene {
    let scene = StatesScene(width: 1280)
    let scanner = Position445Scanner()
    let folder = URL(fileURLWithPath: "/position445")
    let root = AccessRootID()
    let host: Position445Host
    let scan: FolderScanCoordinator
    init() {
        host = Position445Host(scene: scene)
        scan = FolderScanCoordinator(access: StatesLeases(), scanner: scanner)
        scan.host = host
        scene.session.folderScan = scan
    }
    func open(_ name: String) async {
        await scene.open(folder.appendingPathComponent(name), pipeline: host.pipeline, leases: host.leases)?.value
    }
    func begin() async throws {
        try await scan.begin(folder: folder, rootID: root, input: folder.appendingPathComponent("b.jpg")).value
        await open("b.jpg")
    }
    func label() throws -> NSTextField {
        try #require(scene.chrome.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "chrome.filename" })
    }
    func expect(_ value: String) throws {
        scene.chrome.refresh(session: scene.session)
        let field = try label()
        #expect(field.stringValue == value)
        #expect(field.accessibilityValue() as? String == value)
    }
    func finish() { scan.end(); scene.window.close() }
}

@Test(.timeLimit(.minutes(2))) @MainActor
func position445UsesDisplayedMemberAndFollowsNavigationAndProjection() async throws {
    let test = Position445Scene()
    defer { test.finish() }
    try await test.begin()
    try test.expect("b.jpg  2 / 3")
    #expect(test.scan.move(.next))
    await test.scene.session.imageLoader.loadTask?.value
    try test.expect("c.png  3 / 3")
    #expect(test.scan.move(.previous))
    await test.scene.session.imageLoader.loadTask?.value
    try test.expect("b.jpg  2 / 3")
    #expect(test.scan.move(.previous))
    await test.scene.session.imageLoader.loadTask?.value
    try test.expect("a.png  1 / 3")
    #expect(test.scan.move(.previous))
    try test.expect("a.png  1 / 3")

    // Displayed identity is authoritative, even when a frozen preview navigates independently of this scan.
    await test.open("c.png")
    #expect(test.scan.currentURL?.lastPathComponent == "a.png")
    try test.expect("c.png  3 / 3")
    test.scan.setConditions(.init(direction: .descending))
    try test.expect("c.png  1 / 3")
    test.scan.setConditions(.init(selectedExtensions: ["png"]))
    try test.expect("c.png  2 / 2")
    test.scan.setConditions(.init(selectedExtensions: ["gif"]))
    try test.expect("c.png")
    test.scan.setConditions(.init())
    await test.open("b.jpg")
    let source = try #require(test.scan.sourceSnapshot)
    let identity = ItemIdentityRoot(id: test.root, url: test.folder)
    let added = FolderEntry(url: test.folder.appendingPathComponent("aa.png"), root: identity)
    test.scan.replaceSourceSnapshot(.init(version: source.version, entries: source.entries + [added], isComplete: true))
    try test.expect("b.jpg  3 / 4")
    test.scan.replaceSourceSnapshot(.init(version: source.version,
        entries: source.entries.filter { $0.url.lastPathComponent != "a.png" } + [added], isComplete: true))
    try test.expect("b.jpg  2 / 3")
    test.scan.replaceSourceSnapshot(.init(version: source.version,
        entries: source.entries.filter { $0.url.lastPathComponent == "c.png" }, isComplete: true))
    // A removed image can remain on canvas until the replacement opens, but cannot claim an old position.
    try test.expect("b.jpg")
    await test.open("c.png")
    try test.expect("c.png  1 / 1")
    await test.open("outside.png")
    try test.expect("outside.png")
    test.scene.session.closeImage()
    try test.expect("")
}

@Test(.timeLimit(.minutes(2))) @MainActor
func position445KeepsHonestReadingFailureAndRecursiveRescanLabels() async throws {
    let test = Position445Scene(), started = StartedTasks()
    try await withAsyncTeardown { @MainActor in
        await test.open("b.jpg")
        await test.scanner.configure(held: true)
        let first = started.track(test.scan.begin(folder: test.folder, rootID: test.root,
            input: test.folder.appendingPathComponent("b.jpg")))
        await test.scanner.entered()
        try test.expect("b.jpg · Reading…")
        await test.scanner.finish(); try await first.value
        try test.expect("b.jpg  2 / 3")
        await test.scanner.configure(held: true)
        let recursive = try #require(test.scan.setRecursiveEnabled(true))
        started.track(recursive)
        await test.scanner.entered()
        try test.expect("b.jpg · Reading…")
        await test.scanner.finish(); try await recursive.value
        try test.expect("b.jpg  2 / 4")
        await test.scanner.configure(held: true, fails: true)
        let failed = started.track(test.scan.begin(folder: test.folder, rootID: test.root,
            input: test.folder.appendingPathComponent("b.jpg")))
        await test.scanner.entered()
        try test.expect("b.jpg · Reading…")
        await test.scanner.finish()
        await #expect(throws: CocoaError.self) { try await failed.value }
        try test.expect("b.jpg")
        test.scan.end()
        try test.expect("b.jpg")
        test.scene.session.folderScan = nil
        try test.expect("b.jpg")
    } teardown: {
        test.scan.end(); started.cancelAll()
        await started.awaitAll { await test.scanner.finish() }
        test.scene.window.close()
    }
}

@Test @MainActor func position445Page14TextAXAndMeasuredPodWidth() throws {
    let scene = StatesScene(width: 1280)
    defer { scene.window.close() }
    let field = try #require(scene.chrome.groups.flatMap(\.subviews).compactMap { $0 as? NSTextField }
        .first { $0.accessibilityIdentifier() == "chrome.filename" })
    for language in ["en", "zh-Hans"] {
        let fraction = String(format: "%lld / %lld", locale: Locale(identifier: language), Int64(2), Int64(12))
        scene.chrome.refresh(filename: "DSC_0342.jpg", position: fraction)
        #expect(field.stringValue == "DSC_0342.jpg  2 / 12")
        #expect(field.accessibilityValue() as? String == "DSC_0342.jpg  2 / 12")
        // Actual Chromium page14 (1280×800), pinned HTML; log i445-pin.log.
        #expect(abs(scene.chrome.groups[1].frame.width - 225.03125) <= 1)
        #expect(scene.chrome.groups[1].frame.height == 38)
        #expect(scene.chrome.groups[0].frame.width == 104)
        #expect(scene.chrome.groups[2].frame.width == 174)
    }
    scene.chrome.refresh(filename: "长图片名称—é.png", position: "1 / 1")
    #expect(field.stringValue == "长图片名称—é.png  1 / 1")
    #expect(field.accessibilityValue() as? String == "长图片名称—é.png  1 / 1")
    scene.chrome.refresh(filename: "standalone.png")
    #expect(field.stringValue == "standalone.png")
}

@Test @MainActor func position445RealPreviewSetMovementUsesTheDisplayedURL() async throws {
    let test = Position445Scene()
    defer { test.finish() }
    try await test.begin()
    let snapshot = try #require(test.scan.snapshot)
    let first = try #require(snapshot.navigationEntries.first)
    let previewHost = Position445PreviewHost(scene: test.scene, entries: snapshot.navigationEntries)
    test.scene.session.host = previewHost
    test.scene.session.enterFolderGrid(items: snapshot.navigationEntries.map(\.itemID), sourceVersion: .init(1))
    test.scene.session.focus(first.itemID)
    let router = CommandRouter()
    _ = router.route(.enter, from: .key, to: test.scene.session)
    await test.scene.session.imageLoader.loadTask?.value
    try test.expect("a.png  1 / 3")
    _ = router.route(.next, from: .key, to: test.scene.session)
    await test.scene.session.imageLoader.loadTask?.value
    try test.expect("b.jpg  2 / 3")
    _ = router.route(.next, from: .key, to: test.scene.session)
    await test.scene.session.imageLoader.loadTask?.value
    #expect(test.scan.currentURL?.lastPathComponent == "b.jpg")
    try test.expect("c.png  3 / 3")
    _ = router.route(.previous, from: .key, to: test.scene.session)
    await test.scene.session.imageLoader.loadTask?.value
    try test.expect("b.jpg  2 / 3")
}

@MainActor private final class Position445PreviewHost: ViewerSessionHost {
    let scene: StatesScene
    let entries: [FolderEntry]
    let pipeline = StatesPipeline(), leases = StatesLeases()
    init(scene: StatesScene, entries: [FolderEntry]) { self.scene = scene; self.entries = entries }
    var hasImage: Bool { scene.host.hasImage }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { scene.host.performCanvas(command, from: entry) }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { scene.host.performCanvasZoom(command, from: entry) }
    func requestOpen() { scene.host.requestOpen() }
    func applyFocus(_ focus: FocusContext) { scene.host.applyFocus(focus) }
    func showInspector(_ visible: Bool) { scene.host.showInspector(visible) }
    func returnToGrid() {}
    func presentGridItem(_ id: ItemID) {
        if let entry = entries.first(where: { $0.itemID == id }) {
            scene.open(entry.url, pipeline: pipeline, leases: leases)
        }
    }
}

@Test @MainActor func position445Page27OriginalSizeKeepsThePositionLabel() async throws {
    let test = Position445Scene()
    defer { test.finish() }
    let design = try PinnedDesign.page("original-size")
    #expect(try design.length(".viewer-file-label", "gap", viewport: 1280) == 12)
    try await test.begin()
    _ = CommandRouter().route(.actualPixels, from: .button, to: test.scene.session)
    #expect(test.scene.session.zoomMode == .actualPixels)
    try test.expect("b.jpg  2 / 3")
}

@Test @MainActor func position445Fix1SelectedPreviewUsesSetOrderAndIndependentCount() async throws {
    let test = Position445Scene()
    defer { test.finish() }
    try await test.begin()
    let source = try #require(test.scan.sourceSnapshot)
    let root = ItemIdentityRoot(id: test.root, url: test.folder)
    let entries = (1...12).map {
        FolderEntry(url: test.folder.appendingPathComponent(String(format: "image-%02d.png", $0)), root: root)
    }
    test.scan.replaceSourceSnapshot(.init(version: source.version, entries: entries, isComplete: true))
    let ordered = try #require(test.scan.snapshot).navigationEntries
    let previewHost = Position445PreviewHost(scene: test.scene, entries: ordered)
    let session = test.scene.session
    session.host = previewHost
    session.enterFolderGrid(items: ordered.map(\.itemID), sourceVersion: .init(1))
    session.select(ordered[9].itemID)
    session.select(ordered[1].itemID, modifier: .command)
    session.select(ordered[5].itemID, modifier: .command)
    session.focus(ordered[1].itemID)
    let router = CommandRouter()
    _ = router.route(.enter, from: .key, to: session)
    await session.imageLoader.loadTask?.value
    #expect(session.previewSet?.itemIDs == [ordered[1].itemID, ordered[5].itemID, ordered[9].itemID])
    #expect(session.imageLoader.fileURL == ordered[1].url)
    try test.expect("image-02.png  1 / 3")
    for (command, index, fraction) in [(CommandID.next, 5, "2 / 3"), (.next, 9, "3 / 3"), (.previous, 5, "2 / 3")] {
        _ = router.route(command, from: .key, to: session)
        await session.imageLoader.loadTask?.value
        #expect(session.imageLoader.fileURL == ordered[index].url)
        try test.expect("\(ordered[index].url.lastPathComponent)  \(fraction)")
    }
    // The set independently knows both membership and count, even without a folder coordinator.
    session.folderScan = nil
    try test.expect("image-06.png  2 / 3")
    session.closeImage()
    #expect(session.previewSet != nil)
    try test.expect("")
}
