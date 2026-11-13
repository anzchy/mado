import AppKit
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure
import MadoMacUI

@MainActor private final class Issue573Motion: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

private final class Issue573DenyTarget: SecurityScope, @unchecked Sendable {
    let target: URL
    var denyEnabled = true
    init(target: URL) { self.target = target }
    func start(_ url: URL) -> Bool { !denyEnabled || url != target }
    func isReadable(_ url: URL) -> Bool { !denyEnabled || url != target }
    func stop(_ url: URL) { }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue573DeniedSymlinkTargetShowsChooseFileRecovery() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let tree = fm.temporaryDirectory.appendingPathComponent("issue573-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: tree, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tree) }
    let target = tree.appendingPathComponent("image.png")
    let link = tree.appendingPathComponent("link.png")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try fm.copyItem(at: fixture, to: target)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    let access = try FileAccess(scope: Issue573DenyTarget(target: target), bookmarks: SystemSecurityScope(),
        store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "issue573")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: tree.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue573Motion()))
    let window = try #require(controller.window)
    defer { window.close() }

    controller.openInput([link])
    try await waitUntil("input should settle or show choose-file recovery") {
        window.attachedSheet != nil || controller.session.imageLoader.phase == .settled
    }

    #expect(controller.session.imageLoader.presented == nil)
    let sheet = try #require(window.attachedSheet)
    func labels(_ view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap(labels)
    }
    #expect(labels(try #require(sheet.contentView)).contains(String(localized: "Choose this image again to reconnect access.")))
    #expect(await access.records().isEmpty)
}

@MainActor private func issue573DeniedSetFixture(deniedFirst: Bool) throws -> (URL, URL, URL, URL, FileAccess, CanvasWindowController, NSWindow, Issue573DenyTarget) {
    _ = NSApplication.shared
    let fm = FileManager.default
    let tree = fm.temporaryDirectory.appendingPathComponent("issue573-set-\(UUID())", isDirectory: true)
    try fm.createDirectory(at: tree, withIntermediateDirectories: true)
    let target = tree.appendingPathComponent(deniedFirst ? "a-denied.png" : "z-denied.png")
    let link = tree.appendingPathComponent("linked.png")
    let plain = tree.appendingPathComponent("plain.png")
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    try fm.copyItem(at: fixture, to: target)
    try fm.copyItem(at: fixture, to: plain)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    let scope = Issue573DenyTarget(target: target)
    let access = try FileAccess(scope: scope, bookmarks: SystemSecurityScope(),
        store: BookmarkStore(url: tree.appendingPathComponent("roots.json")), buildSHA: "issue573-set")
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: tree.appendingPathComponent("recent.json")),
        browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let controller = CanvasWindowController(pipeline: ImageIOPipeline(),
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: Issue573Motion()))
    return (tree, target, link, plain, access, controller, try #require(controller.window), scope)
}

@MainActor private func issue573SheetLabels(_ view: NSView) -> [String] {
    let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
    return own + view.subviews.flatMap(issue573SheetLabels)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue573MixedDropDeniedFirstLinkOffersChooseFile() async throws {
    let (tree, _, link, plain, access, controller, window, _) = try issue573DeniedSetFixture(deniedFirst: true)
    defer { window.close(); try? FileManager.default.removeItem(at: tree) }
    controller.openInput([link, plain])
    try await waitUntil("mixed drop should show access recovery") { window.attachedSheet != nil }
    #expect(controller.session.imageLoader.presented == nil)
    #expect(issue573SheetLabels(try #require(window.attachedSheet?.contentView))
        .contains(String(localized: "Choose this image again to reconnect access.")))
    #expect(await access.records().isEmpty)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue573NavigatingFromPlainOntoDeniedLinkOffersChooseFile() async throws {
    let (tree, _, link, plain, access, controller, window, _) = try issue573DeniedSetFixture(deniedFirst: false)
    defer { window.close(); try? FileManager.default.removeItem(at: tree) }
    controller.openInput([plain, link])
    try await waitUntil("plain set member should display") {
        controller.session.filePreviewSet?.current == plain && controller.session.imageLoader.presented != nil
    }
    #expect(CommandRouter().route(.next, from: .key, to: controller.session))
    try await waitUntil("denied link member should show access recovery") { window.attachedSheet != nil }
    #expect(issue573SheetLabels(try #require(window.attachedSheet?.contentView))
        .contains(String(localized: "Choose this image again to reconnect access.")))
    #expect(await access.records().isEmpty)
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue573NilSetMemberHasProvisionalGrantBeforeLoaderRuns() throws {
    let (tree, target, _, _, _, controller, window, _) = try issue573DeniedSetFixture(deniedFirst: true)
    defer { window.close(); try? FileManager.default.removeItem(at: tree) }
    controller.openInputImage(target, accessRequest: nil)
    let provisional = Mirror(reflecting: controller).children
        .first { $0.label == "standaloneGrantURL" }?.value as? URL
    #expect(provisional == target)
}

@MainActor private func issue695NavigateToDeniedMember(_ controller: CanvasWindowController,
    window: NSWindow, plain: URL, denied: URL) async throws {
    controller.openInput([plain, denied])
    try await waitUntil("plain preview-set member should display") {
        controller.session.filePreviewSet?.current == plain && controller.session.imageLoader.presented != nil
    }
    #expect(CommandRouter().route(.next, from: .key, to: controller.session))
    try await waitUntil("denied preview-set member should request recovery") { window.attachedSheet != nil }
    #expect(issue573SheetLabels(try #require(window.attachedSheet?.contentView))
        .contains(String(localized: "Choose this image again to reconnect access.")))
}

@MainActor private func issue695ChooseFile(_ controller: CanvasWindowController, window: NSWindow,
    target: URL, scope: Issue573DenyTarget) async throws {
    let alert = try #require(window.attachedSheet)
    window.endSheet(alert, returnCode: .alertFirstButtonReturn)
    try await waitUntil("Choose File panel should appear") { window.attachedSheet is NSOpenPanel }
    let panel = try #require(window.attachedSheet as? NSOpenPanel)
    scope.denyEnabled = false // The newly chosen file is now accessible to the test scope.
    controller.completeFileReconnection(target, original: target)
    try await waitUntil("chosen image should display") {
        controller.session.imageLoader.presented?.fileURL.standardizedFileURL == target.standardizedFileURL
    }
    window.endSheet(panel, returnCode: .cancel)
    try await waitUntil("Choose File panel should close") { window.attachedSheet == nil }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue695ChooseDeniedLinkTargetKeepsMultiFileSet() async throws {
    let (tree, target, link, plain, _, controller, window, scope) = try issue573DeniedSetFixture(deniedFirst: false)
    defer { window.close(); try? FileManager.default.removeItem(at: tree) }
    try await issue695NavigateToDeniedMember(controller, window: window, plain: plain, denied: link)
    try await issue695ChooseFile(controller, window: window, target: target, scope: scope)
    let setKept = controller.session.filePreviewSet != nil
    #expect(setKept, "#695 Choose File must keep the multi-file preview set")
    guard setKept else { return }
    let navigated = CommandRouter().route(.previous, from: .key, to: controller.session)
    #expect(navigated,
        "#695 previous navigation must reach the plain member after Choose File")
    guard navigated else { return }
    try await waitUntil("plain member should display after Choose File") {
        controller.session.imageLoader.presented?.fileURL.standardizedFileURL == plain.standardizedFileURL
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue695ChooseDeniedPlainTargetKeepsMultiFileSet() async throws {
    let (tree, target, _, plain, _, controller, window, scope) = try issue573DeniedSetFixture(deniedFirst: false)
    defer { window.close(); try? FileManager.default.removeItem(at: tree) }
    try await issue695NavigateToDeniedMember(controller, window: window, plain: plain, denied: target)
    try await issue695ChooseFile(controller, window: window, target: target, scope: scope)
    let setKept = controller.session.filePreviewSet != nil
    #expect(setKept, "#695 Choose File must keep the multi-file preview set for a plain file")
    guard setKept else { return }
    let navigated = CommandRouter().route(.previous, from: .key, to: controller.session)
    #expect(navigated,
        "#695 previous navigation must reach the plain member after plain-file recovery")
    guard navigated else { return }
    try await waitUntil("plain member should display after plain-file recovery") {
        controller.session.imageLoader.presented?.fileURL.standardizedFileURL == plain.standardizedFileURL
    }
}

@Test(.timeLimit(.minutes(3))) @MainActor func issue695CancelRecoveryKeepsSetAndPreviousImage() async throws {
    let (tree, _, link, plain, _, controller, window, _) = try issue573DeniedSetFixture(deniedFirst: false)
    defer { window.close(); try? FileManager.default.removeItem(at: tree) }
    try await issue695NavigateToDeniedMember(controller, window: window, plain: plain, denied: link)
    let alert = try #require(window.attachedSheet)
    window.endSheet(alert, returnCode: .alertSecondButtonReturn)
    try await waitUntil("recovery alert should close") { window.attachedSheet == nil }
    let setKept = controller.session.filePreviewSet != nil
    #expect(setKept, "#695 Cancel must keep the multi-file preview set")
    guard setKept else { return }
    let navigated = CommandRouter().route(.previous, from: .key, to: controller.session)
    #expect(navigated,
        "#695 previous navigation must reach the plain member after Cancel")
    guard navigated else { return }
    try await waitUntil("previous image should display after Cancel") {
        controller.session.imageLoader.presented?.fileURL.standardizedFileURL == plain.standardizedFileURL
    }
}
