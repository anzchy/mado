import Foundation
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

@MainActor @Test func inputAdmissionRealFixtureProbeKinds() async throws {
    let scope = CountingScope()
    let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: store) }
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(), store: BookmarkStore(url: store), buildSHA: "input-test")
    let pipeline = ImageIOPipeline(), intent = AccessIntent()
    let admission = ViewerInputAdmission(access: access, pipeline: pipeline, maximumPixelSize: 64, rootCovering: { _ in nil })
    for name in ["not-an-image.jpg", "unsupported-container.zip"] {
        let url = fixture(name), bytes = try Data(contentsOf: url)
        #expect(await admission.probe(url, operation: intent.begin()) == .unsupported)
        await #expect(performing: {
            try await pipeline.request(for: url, maximumPixelSize: 64)
        }, throws: loadError(.unsupportedFormat))
        #expect(try Data(contentsOf: url) == bytes)
    }
    for name in ["corrupt.png", "truncated.png"] {
        let url = fixture(name)
        #expect(await admission.probe(url, operation: intent.begin()) == .open(.fileGrant(url)))
        do {
            let request = try await pipeline.request(for: url, maximumPixelSize: 64)
            await #expect(performing: { try await pipeline.image(for: request) }, throws: loadError(.corruptImage))
            print("inputFixture \(name) header=success decode=corruptImage")
        } catch {
            #expect((error as? ImageLoadError)?.kind == .corruptImage)
            print("inputFixture \(name) header=corruptImage")
        }
    }
    let valid = fixture("alpha-gradient.png")
    #expect(await admission.probe(valid, operation: intent.begin()) == .open(.fileGrant(valid)))
    let request = try await pipeline.request(for: valid, maximumPixelSize: 64)
    #expect(request.renderKey != nil)
    #expect(request.identityRoot == nil)
    #expect(scope.counts == [5, 5])
    #expect(await access.records().isEmpty == true)
}

import Darwin
@testable import MadoApplication

private final class InputReplacementScope: SecurityScope, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    private var drained: CheckedContinuation<Void, Never>?
    func isReadable(_ url: URL) -> Bool { false }
    func start(_ url: URL) -> Bool { lock.withLock { starts += 1 }; return true }
    func stop(_ url: URL) {
        let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
            stops += 1
            if starts == stops { let waiting = drained; drained = nil; return waiting }
            return nil
        }
        waiter?.resume()
    }
    var counts: [Int] { lock.withLock { [starts, stops] } }
    func waitForBalance() async {
        await withCheckedContinuation { continuation in
            let balanced = lock.withLock {
                if starts == stops { return true }
                drained = continuation
                return false
            }
            if balanced { continuation.resume() }
        }
    }
}

@MainActor private final class InputReplacementHost: ViewerInputHost, ViewerImageHost, ViewerSessionNavigationHost {
    let session = ViewerSession()
    let access: FileAccess
    let pipeline = ImageIOPipeline()
    let root: AccessRootID?
    var images: [DecodedImage] = []
    var retry: ViewerRetryIntent?
    var notices: [ViewerInputNotice] = []
    var prompts: [URL] = []
    var navigation: [NavigationDirection] = []
    var hasImage = false
    var failures: [String] = []
    var canNavigate = true
    init(access: FileAccess, root: AccessRootID?) {
        self.access = access; self.root = root
        session.host = self; session.imageLoader.host = self
    }
    func openInputImage(_ url: URL, accessRequest: AccessRequest?) {
        retry = ViewerRetryIntent(fileURL: url, accessRequest: accessRequest)
        let request = accessRequest ?? root.map { .root($0, file: url) } ?? .fileGrant(url)
        let access = access, pipeline = pipeline
        session.openImage(url, maximumPixelSize: 640) { try await AccessImageSource.open(request, access: access, pipeline: pipeline) }
    }
    func showInputNotice(_ notice: ViewerInputNotice) { notices.append(notice) }
    func promptForInputFolder(_ folder: URL) { prompts.append(folder) }
    func beginImageOpening() { hasImage = false }
    func installImage(_ image: DecodedImage, fileURL: URL) { hasImage = true; images.append(image) }
    func imageLoadFailed(_ error: any Error) { hasImage = false; failures.append(String(describing: error)) }
    func navigate(_ direction: NavigationDirection) { navigation.append(direction) }
    func performCanvas(_ command: CommandID, from entry: CommandEntry) { }
    func performCanvasZoom(_ command: CommandID, from entry: CommandEntry) -> Double? { nil }
    func requestOpen() { }
    func applyFocus(_ focus: FocusContext) { }
    func showInspector(_ visible: Bool) { }
}

@Test @MainActor func inputAtomicReplacementPreservesFileGrantAndRootMembers() async throws {
    for scoped in [false, true] {
        let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tree) }
        let a = tree.appendingPathComponent("A.png"), b = tree.appendingPathComponent("B.png"), c = tree.appendingPathComponent("C.png")
        try FileManager.default.copyItem(at: fixture("landscape-3x2.png"), to: a)
        try FileManager.default.copyItem(at: fixture("alpha-gradient.png"), to: b)
        try FileManager.default.copyItem(at: fixture("checkerboard-1px.png"), to: c)
        let scope = InputReplacementScope()
        let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
            store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "input-replace")
        let root: AccessRootID? = scoped ? try await access.grant(folder: tree) : nil
        let host = InputReplacementHost(access: access, root: root), intent = AccessIntent()
        let admission = ViewerInputAdmission(access: access, pipeline: host.pipeline, maximumPixelSize: 640, rootCovering: { _ in root })
        await host.session.openInput([c, b, a], operation: intent.begin(), admission: admission, host: host)
        await host.session.imageLoader.loadTask?.value
        #expect(CommandRouter().route(.next, from: .key, to: host.session))
        await host.session.imageLoader.loadTask?.value
        let before = try #require(host.session.imageLoader.presented?.key)
        let beforeImage = try #require(host.images.last)
        let beforeData = try #require(beforeImage.image.dataProvider?.data) as Data
        #expect(host.session.filePreviewSet?.members == [a, b, c])
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(beforeImage.sourcePixelSize == CGSize(width: 256, height: 128))
        #expect(beforeImage.image.width == 256 && beforeImage.image.height == 128)
        if let root { #expect(before.itemID == .rootRelative(rootID: root, relativePath: "B.png")) }
        let replacement = tree.appendingPathComponent("replacement.png")
        let newBytes = try Data(contentsOf: fixture("portrait-2x3.png"))
        try newBytes.write(to: replacement)
        #expect(Darwin.rename(replacement.path, b.path) == 0)
        #expect(!FileManager.default.fileExists(atPath: replacement.path))
        #expect(try Data(contentsOf: b) == newBytes)
        host.retry?.reopen { host.openInputImage($0, accessRequest: $1) }
        await host.session.imageLoader.loadTask?.value
        let after = try #require(host.session.imageLoader.presented?.key)
        let afterImage = try #require(host.images.last)
        let afterData = try #require(afterImage.image.dataProvider?.data) as Data
        #expect(host.session.imageStatus == .showing)
        #expect(host.session.filePreviewSet?.members == [a, b, c])
        #expect(host.session.filePreviewSet?.members.count == 3)
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(after.itemID == before.itemID)
        #expect(after.revision != before.revision)
        #expect(after != before)
        #expect(afterImage.itemID == beforeImage.itemID)
        #expect(afterImage.revision == after.revision)
        #expect(afterImage.sourcePixelSize == CGSize(width: 400, height: 600))
        #expect(afterImage.image.width == 400 && afterImage.image.height == 600)
        #expect(afterData != beforeData)
        #expect(host.retry?.fileURL == b)
        #expect(host.retry?.accessRequest == nil)
        #expect(CommandRouter().route(.previous, from: .button, to: host.session))
        await host.session.imageLoader.loadTask?.value
        #expect(CommandRouter().route(.next, from: .menu, to: host.session))
        await host.session.imageLoader.loadTask?.value
        #expect(host.session.filePreviewSet?.members == [a, b, c])
        #expect(host.session.filePreviewSet?.index == 1)
        #expect(host.session.imageLoader.presented?.key == after)
        #expect(host.images.last?.sourcePixelSize == CGSize(width: 400, height: 600))
        #expect(host.notices.isEmpty && host.prompts.isEmpty && host.navigation.isEmpty)
        host.session.endFilePreviewSet(); host.session.closeImage()
        await scope.waitForBalance()
        #expect(host.session.filePreviewSet == nil)
        #expect(scope.counts[0] == scope.counts[1])
        #expect(scope.counts[0] > 0)
        #expect(await access.records().count == (scoped ? 1 : 0))
    }
}

@Test @MainActor func inputAtomicReplacementRejectsCompletePNGChunksWithoutEndMarker() async throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let complete = try Data(contentsOf: fixture("alpha-gradient.png"))
    let ending = Array(complete.suffix(12))
    #expect(Array(ending[4..<8]) == [73, 69, 78, 68])
    let file = tree.appendingPathComponent("complete-chunks-no-iend.png")
    try complete.dropLast(12).write(to: file)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "input-end-marker")
    let pipeline = ImageIOPipeline()
    await #expect(performing: {
        try await access.withLease(.fileGrant(file)) { _ in
            try await pipeline.request(for: file, maximumPixelSize: 64)
        }
    }, throws: loadError(.corruptImage))
    #expect(scope.counts == [1, 1])
    #expect(try Data(contentsOf: file) == complete.dropLast(12))
}

@Test @MainActor func issue73ReadableDropSessionOpensEmptyThenReplacesAndRejectsZIP() async throws {
    let tree = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tree) }
    let a = tree.appendingPathComponent("fresh-A.png"), b = tree.appendingPathComponent("fresh-B.png")
    let zip = tree.appendingPathComponent("unsupported-container.zip")
    try FileManager.default.copyItem(at: fixture("alpha-gradient.png"), to: a)
    try FileManager.default.copyItem(at: fixture("portrait-2x3.png"), to: b)
    try FileManager.default.copyItem(at: fixture("unsupported-container.zip"), to: zip)
    let originalA = try Data(contentsOf: a), originalB = try Data(contentsOf: b)
    let scope = Issue73Scope()
    for file in [a, b, zip] { scope.configure(file, start: false, readable: true) }
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
        store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "issue73-session")
    let host = InputReplacementHost(access: access, root: nil), intent = AccessIntent()
    let admission = ViewerInputAdmission(access: access, pipeline: host.pipeline,
        maximumPixelSize: 640, rootCovering: { await access.rootCovering($0) })
    #expect(host.session.imageLoader.presented == nil)
    await host.session.openInput([a], operation: intent.begin(), admission: admission, host: host)
    await host.session.imageLoader.loadTask?.value
    #expect(host.session.imageStatus == .showing)
    #expect(host.hasImage && host.failures.isEmpty && host.notices.isEmpty)
    let first = try #require(host.session.imageLoader.presented?.key)
    let firstImage = try #require(host.images.last)
    let firstPixels = try #require(firstImage.image.dataProvider?.data) as Data
    #expect(firstImage.sourcePixelSize == CGSize(width: 256, height: 128))
    #expect(firstImage.itemID == first.itemID)
    #expect(host.retry?.accessRequest == .fileGrant(a))
    await host.session.openInput([b], operation: intent.begin(), admission: admission, host: host)
    await host.session.imageLoader.loadTask?.value
    let second = try #require(host.session.imageLoader.presented?.key)
    let secondImage = try #require(host.images.last)
    let secondPixels = try #require(secondImage.image.dataProvider?.data) as Data
    #expect(host.session.imageStatus == .showing)
    #expect(host.hasImage && host.failures.isEmpty && host.notices.isEmpty)
    #expect(second.itemID != first.itemID)
    #expect(secondImage.itemID == second.itemID)
    #expect(secondImage.sourcePixelSize == CGSize(width: 400, height: 600))
    #expect(secondPixels != firstPixels)
    #expect(host.retry?.accessRequest == .fileGrant(b))
    let countBeforeZIP = host.images.count
    await host.session.openInput([zip], operation: intent.begin(), admission: admission, host: host)
    await host.session.imageLoader.loadTask?.value
    #expect(host.notices == [.rejected])
    #expect(host.session.imageLoader.presented?.key == second)
    #expect(host.images.count == countBeforeZIP)
    #expect(host.images.last?.itemID == secondImage.itemID)
    #expect(host.session.imageStatus == .showing && host.hasImage)
    #expect(host.failures.isEmpty && host.prompts.isEmpty)
    #expect(host.session.filePreviewSet == nil)
    host.session.closeImage()
    #expect(host.session.imageLoader.presented == nil)
    #expect(await access.records().isEmpty)
    #expect(try Data(contentsOf: a) == originalA && Data(contentsOf: b) == originalB)
    #expect(scope.counts(a)[0] > 0 && scope.counts(a)[1] == 0)
    #expect(scope.counts(b)[0] > 0 && scope.counts(b)[1] == 0)
    #expect(scope.counts(zip) == [0, 0])
}
