import Foundation
import Testing
import MadoCore
import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func identityScopeSharesRootResolverAcrossRequests() async throws {
    let file = fixture("coordinate-grid.png")
    let root = ItemIdentityRoot(id: AccessRootID(), url: file.deletingLastPathComponent())
    let pipeline = ImageIOPipeline()
    let first = try await pipeline.request(for: file, maximumPixelSize: 512, identityRoot: root)
    let second = try await pipeline.request(for: file, maximumPixelSize: 512, identityRoot: root)
    #expect(first.renderKey?.itemID == .rootRelative(rootID: root.id, relativePath: "coordinate-grid.png"))
    #expect(first.renderKey == second.renderKey)
    let image = try await pipeline.image(for: first)
    #expect(image.itemID == first.renderKey?.itemID)
    let grant = try await pipeline.request(for: file, maximumPixelSize: 512)
    #expect(grant.renderKey?.itemID != first.renderKey?.itemID)
}

@testable import MadoApplication

private actor ScopeLeaseProbe: AccessLeasing {
    let root: ItemIdentityRoot
    var acquired: [AccessLease] = [], released: [AccessLease] = []
    var events: [String] = [], active: Set<AccessLease> = []
    var observedCounts: [Int] = []
    private var drained: CheckedContinuation<Void, Never>?
    init(_ root: ItemIdentityRoot) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease {
        let lease: AccessLease
        switch request {
        case .root(let id, _): lease = AccessLease(url: root.url, rootID: id)
        case .fileGrant(let file): lease = AccessLease(url: file, rootID: nil)
        }
        events.append("acquire"); acquired.append(lease); active.insert(lease)
        return lease
    }
    func release(_ lease: AccessLease) {
        events.append("release"); released.append(lease); active.remove(lease)
        if active.isEmpty { drained?.resume(); drained = nil }
    }
    func note(_ event: String) { events.append(event); observedCounts.append(active.count) }
    func waitUntilReleased() async {
        if active.isEmpty { return }
        await withCheckedContinuation { drained = $0 }
    }
}
private struct ScopePipelineProbe: ImagePipeline {
    let pipeline: ImageIOPipeline, access: ScopeLeaseProbe
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: nil)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        await access.note("request")
        return try await pipeline.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        await access.note("image")
        return try await pipeline.image(for: request)
    }
}
@MainActor @Test(.timeLimit(.minutes(2))) func identityScopeSessionsUseLeaseRootAndAcquireBeforePipeline() async {
    let file = fixture("alpha-gradient.png")
    let root = ItemIdentityRoot(id: AccessRootID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000041")!), url: file.deletingLastPathComponent())
    let access = ScopeLeaseProbe(root), pipeline = ImageIOPipeline()
    let probe = ScopePipelineProbe(pipeline: pipeline, access: access)
    let a = ViewerSession(), b = ViewerSession(), grant = ViewerSession()
    a.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.root(root.id, file: file), access: access, pipeline: probe) }
    await a.imageLoader.loadTask?.value
    #expect(await access.events == ["acquire", "acquire", "request", "image", "release", "acquire", "request", "image", "release"])
    b.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.root(root.id, file: file), access: access, pipeline: probe) }
    await b.imageLoader.loadTask?.value
    #expect(a.imageLoader.presented?.key.itemID == .rootRelative(rootID: root.id, relativePath: "alpha-gradient.png"))
    #expect(a.imageLoader.presented?.key.itemID == b.imageLoader.presented?.key.itemID)
    #expect(a.imageLoader.presented?.key.itemID.stableEncoding == "id1:root:00000000-0000-0000-0000-000000000041:YWxwaGEtZ3JhZGllbnQucG5n")
    grant.openImage(file, maximumPixelSize: 512) { try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: probe) }
    await grant.imageLoader.loadTask?.value
    #expect(grant.imageLoader.presented?.key.itemID != a.imageLoader.presented?.key.itemID)
    #expect(await access.observedCounts.allSatisfy { $0 >= 2 })
    a.closeImage(); b.closeImage(); grant.closeImage()
    await access.waitUntilReleased()
    let acquired = await access.acquired, released = await access.released
    #expect(acquired.count == 9 && released.count == 9)
    for lease in acquired { #expect(released.filter { $0 == lease }.count == 1) }
}
@Test(.timeLimit(.minutes(2))) func identityScopeRenameAssociationIsSharedAndRootLocationsCanChange() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let a = folder.appendingPathComponent("a.png"), b = folder.appendingPathComponent("b.png")
    try FileManager.default.copyItem(at: fixture("alpha-gradient.png"), to: a)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder), pipeline = ImageIOPipeline()
    let first = try await pipeline.request(for: a, maximumPixelSize: 512, identityRoot: root)
    try FileManager.default.moveItem(at: a, to: b)
    let renamed = try await pipeline.request(for: b, maximumPixelSize: 512,
        identityRoot: ItemIdentityRoot(id: root.id, url: folder))
    #expect(first.renderKey?.itemID == renamed.renderKey?.itemID)
    let movedRoot = ItemIdentityRoot(id: root.id, url: folder.deletingLastPathComponent())
    let moved = try await pipeline.request(for: b, maximumPixelSize: 512, identityRoot: movedRoot)
    #expect(moved.renderKey?.itemID == .rootRelative(rootID: root.id, relativePath: folder.lastPathComponent + "/b.png"))
}
