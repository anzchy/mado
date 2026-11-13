import CryptoKit
import Foundation
import MadoApplication
import MadoCore
import Testing
@testable import MadoInfrastructure

private func p303Digest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        try Task.checkCancellation()
        hash.update(data: chunk)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private actor P303LeaseObservingPipeline: ImagePipeline {
    let pipeline = ImageIOPipeline()
    let scope: CountingScope
    private(set) var activeAtRequest = false
    private(set) var activeAtImage = false
    init(scope: CountingScope) { self.scope = scope }
    func request(for fileURL: URL, maximumPixelSize: Int) async throws -> ImageDecodeRequest {
        try await request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: nil)
    }
    func request(for fileURL: URL, maximumPixelSize: Int, identityRoot: ItemIdentityRoot?) async throws -> ImageDecodeRequest {
        let counts = scope.counts
        activeAtRequest = counts[0] > counts[1]
        return try await pipeline.request(for: fileURL, maximumPixelSize: maximumPixelSize, identityRoot: identityRoot)
    }
    func image(for request: ImageDecodeRequest) async throws -> DecodedImage {
        let counts = scope.counts
        activeAtImage = counts[0] > counts[1]
        return try await pipeline.image(for: request)
    }
}

@Test(.timeLimit(.minutes(2))) func p303SameSizeSameTimeReplacementNeedsDurableContentEvidence() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let timestamp = Date(timeIntervalSince1970: 1_000_000)
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: file)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    let oldRevision = try FileRevisionReader.read(file)
    let oldDigest = try p303Digest(file)
    try Data(contentsOf: fixture("orientation-2.tiff")).write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: timestamp], ofItemAtPath: file.path)
    let newRevision = try FileRevisionReader.read(file)
    let newDigest = try p303Digest(file)
    #expect(oldRevision.byteCount == newRevision.byteCount)
    #expect(oldRevision.modificationDate == newRevision.modificationDate)
    #expect(oldRevision.resourceIdentifier != newRevision.resourceIdentifier)
    #expect(oldDigest != newDigest)
    let item = ItemID.rootRelative(rootID: AccessRootID(), relativePath: "image.tiff")
    #expect(RenderKey(itemID: item, revision: oldRevision, maximumPixelSize: 128).persistentEncoding == nil)
    #expect(RenderKey(itemID: item, revision: newRevision, maximumPixelSize: 128).persistentEncoding == nil)
}

@Test(.timeLimit(.minutes(2))) func p303PublicPipelineHasNoAccessLeaseParameter() async throws {
    let file = fixture("coordinate-grid.png")
    let root = ItemIdentityRoot(id: AccessRootID(), url: file.deletingLastPathComponent())
    let pipeline = ImageIOPipeline()
    // This is an architectural probe: the public route accepts a caller-supplied root
    // and can deliver pixels without AccessImageSource or an AccessLeasing instance.
    let request = try await pipeline.request(for: file, maximumPixelSize: 32, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    #expect(decoded.image.width == 32)
    #expect(request.renderKey?.itemID == .rootRelative(rootID: root.id, relativePath: file.lastPathComponent))
}

@Test(.timeLimit(.minutes(2))) func p303AccessImageSourceLeasesBeforeRealPipelineRequest() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.png")
    try FileManager.default.copyItem(at: fixture("coordinate-grid.png"), to: file)
    let scope = CountingScope()
    let access = try FileAccess(scope: scope, bookmarks: FakeBookmarks(),
                                store: BookmarkStore(url: folder.appendingPathComponent("roots.json")), buildSHA: "p303")
    let root = try await access.grant(folder: folder)
    let pipeline = P303LeaseObservingPipeline(scope: scope)
    let source = try await AccessImageSource.open(.root(root, file: file), access: access, pipeline: pipeline)
    let (_, image) = try await source.image(maximumPixelSize: 32)
    #expect(image.image.width == 32)
    #expect(await pipeline.activeAtRequest)
    #expect(await pipeline.activeAtImage)
    await source.close()
    let counts = scope.counts
    #expect(counts[0] == counts[1])
}
