import AppKit
import Foundation
import ImageIO
import Testing
import MadoCore
import MadoApplication
import MadoMacUI
@testable import MadoInfrastructure

@MainActor private final class InspectorBudgetMotionSource: ReduceMotionSource {
    var reduceMotion = false
    var onChange: (@MainActor () -> Void)?
}

/// Only holds the old Inspector's external synchronous decode; grid requests still use real ImageIO.
private final class InspectorBudgetDecoder: ImageDecoding, @unchecked Sendable {
    private let condition = NSCondition()
    private var armed = false
    private var released = false
    private var held: ImageDecodeRequest?
    var heldRequest: ImageDecodeRequest? { condition.withLock { held } }
    func arm() { condition.withLock { armed = true } }
    func release() { condition.withLock { released = true; condition.broadcast() } }
    func decode(_ request: ImageDecodeRequest) throws -> DecodedImage {
        condition.lock()
        if armed, request.fileURL.lastPathComponent == "01-old.png", request.maximumPixelSize == 240 {
            held = request
            condition.broadcast()
            while !released { condition.wait() }
        }
        condition.unlock()
        return try ImageIODecoder().decode(request)
    }
}

@MainActor private func inspectorBudgetGrid(_ view: NSView?) -> GridBrowserView? {
    guard let view else { return nil }
    if let grid = view as? GridBrowserView { return grid }
    for child in view.subviews { if let grid = inspectorBudgetGrid(child) { return grid } }
    return nil
}

@MainActor private func inspectorBudgetMetadata(_ controller: CanvasWindowController) -> InspectorMetadata? {
    if case .known(let value) = controller.inspector.value { return value }
    return nil
}

private func inspectorBudgetPreview(_ metadata: InspectorMetadata) throws -> CGImage {
    let data = try #require(metadata.thumbnailData)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

@Test(.timeLimit(.minutes(3))) @MainActor
func issue194ControllerInspectorSharesBudgetAcrossGridResizeAndRejectsLateOldThumbnail() async throws {
    _ = NSApplication.shared
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = base.appendingPathComponent("photos")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic")
    try Data(contentsOf: fixtures.appendingPathComponent("portrait-2x3.png"))
        .write(to: folder.appendingPathComponent("01-old.png"))
    let landscape = try Data(contentsOf: fixtures.appendingPathComponent("landscape-3x2.png"))
    for index in 2...12 { try landscape.write(to: folder.appendingPathComponent(String(format: "%02d-new.png", index))) }
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue194")
    let root = try await access.grant(folder: folder)
    let services = AccessServices(files: access,
        recent: RecentFolderStore(url: base.appendingPathComponent("recent.json")), browser: FolderBrowser(),
        watch: WatchHub(access: access, source: FSEventSource(), scheduler: DispatchWatchScheduler()))
    let decoder = InspectorBudgetDecoder()
    defer { decoder.release() }
    let pipeline = ImageIOPipeline(decoder: decoder)
    let budget = try #require(pipeline.cache.budget)
    let controller = CanvasWindowController(pipeline: pipeline,
        preferencesStore: InMemoryDisplayPreferencesStore(), accessServices: Task { services },
        motionPolicy: MotionPolicy(source: InspectorBudgetMotionSource()))
    let window = try #require(controller.window)
    defer { window.close() }
    window.setContentSize(NSSize(width: 1280, height: 800))
    controller.browseRecoveredFolder(folder, rootID: root)
    try await waitUntil {
        window.contentView?.layoutSubtreeIfNeeded()
        return controller.session.folderScan?.snapshot?.isComplete == true && controller.gridSearchAvailable
    }
    let snapshot = try #require(controller.session.folderScan?.snapshot)
    let old = try #require(snapshot.entries.first { $0.url.lastPathComponent == "01-old.png" })
    let new = try #require(snapshot.entries.first { $0.url.lastPathComponent == "02-new.png" })
    let grid = try #require(inspectorBudgetGrid(window.contentView))
    grid.layoutSubtreeIfNeeded()
    try await waitUntil { budget.usage.pinned > 0 }
    #expect(budget.usage.pinned > 0, "the grid owns shared-budget thumbnail pins before Inspector opens")
    grid.activate(currentItemID: old.itemID)
    let wideWidth = grid.bounds.width
    decoder.arm()
    #expect(controller.route(.inspector, from: .key))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(grid.bounds.width < wideWidth)
    try await waitUntil { decoder.heldRequest != nil || inspectorBudgetMetadata(controller) != nil }
    let held = try #require(decoder.heldRequest, "the default Inspector reader must request through the shared pipeline")
    #expect(held.maximumPixelSize == 240 && held.priority == .visible)
    let oldKey = try #require(held.renderKey)
    #expect(budget.usage.reserved > 0)

    grid.activate(currentItemID: new.itemID)
    #expect(controller.inspector.name == new.url.lastPathComponent)
    // Close widens the grid and cancels the current read; reopening starts a fresh generation.
    #expect(controller.route(.inspector, from: .key))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(grid.bounds.width == wideWidth)
    #expect(controller.inspector.value == .unknown)
    #expect(controller.route(.inspector, from: .key))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(grid.bounds.width < wideWidth)
    try await waitUntil { inspectorBudgetMetadata(controller)?.thumbnailData != nil }
    let current = try #require(inspectorBudgetMetadata(controller))
    let preview = try inspectorBudgetPreview(current)
    #expect(current.pixelWidth == 600 && current.pixelHeight == 400)
    #expect(preview.width == 240 && preview.height == 160)
    #expect(controller.inspector.name == new.url.lastPathComponent)
    #expect(budget.usage.reserved > 0, "cancelled synchronous old work stays charged until it really returns")
    decoder.release()
    try await waitUntil { await pipeline.admission.activity().running == 0 }
    try await waitUntil { await pipeline.cache.pendingCount() == 0 }
    #expect(inspectorBudgetMetadata(controller) == current)
    #expect(controller.inspector.name == new.url.lastPathComponent)
    #expect(await pipeline.cache.image(for: oldKey) == nil, "cancelled old Inspector decode must not publish cache pixels")
    #expect(await pipeline.cache.pinCount(for: oldKey) == 0)
    #expect(budget.usage.reserved == 0)

    #expect(controller.route(.inspector, from: .key))
    grid.stopThumbnails()
    window.close()
    try await waitUntil { budget.usage.pinned == 0 && budget.usage.reserved == 0 }
    #expect(budget.usage.pinned == 0)
    #expect(await pipeline.admission.activity().waiting == 0)
    #expect(await pipeline.admission.activity().running == 0)
}
