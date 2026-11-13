import Foundation
import Testing
import MadoCore
import MadoInfrastructure

@Test(.timeLimit(.minutes(2))) func identityAdmissionAliasesShareOneDecodeAndRenameKeepsItem() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let resolver = FileItemIdentityResolver(root: tree.scope)
    let decoder = DecodeCounter()
    let executor = ControlledExecutor()
    let admission = DecodeAdmission(configuration: DecodeConfiguration(workers: 2, budget: 8), executor: executor, decoder: decoder)
    let revision = FileRevision(byteCount: 5, modificationDate: nil)
    let itemA = try await resolver.identity(for: tree.file)
    let itemB = try await resolver.identity(for: tree.root.appendingPathComponent("a/../b.png"))
    let keyA = await admission.key(for: itemA, revision: revision, maximumPixelSize: 1)
    let keyB = await admission.key(for: itemB, revision: revision, maximumPixelSize: 1)
    #expect(keyA.itemID == itemA)
    #expect(keyA == keyB)
    let a = await admission.subscribe(ImageDecodeRequest(fileURL: tree.file, maximumPixelSize: 1), key: keyA, cost: 4, heavy: false, priority: .current)
    let b = await admission.subscribe(ImageDecodeRequest(fileURL: tree.root.appendingPathComponent("a/../b.png"), maximumPixelSize: 1), key: keyB, cost: 4, heavy: false, priority: .current)
    #expect(executor.count == 1)
    executor.runFirst()
    // Drain a non-deduplicating RED as well, so both subscribers always terminate.
    if executor.count > 0 { executor.runFirst() }
    #expect(try await a.value().image.width == 1)
    #expect(try await b.value().image.width == 1)
    #expect(decoder.count == 1)
    let renamed = tree.root.appendingPathComponent("renamed.png")
    try FileManager.default.moveItem(at: tree.file, to: renamed)
    let item = try await resolver.identity(for: renamed)
    let next = await admission.key(for: item, revision: revision, maximumPixelSize: 1)
    #expect(next.itemID == keyA.itemID)
}

@Test(.timeLimit(.minutes(2))) func identityAtomicReplacementKeepsItemAndChangesRevisionEvenAtSameSizeAndTime() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    let time = Date(timeIntervalSince1970: 1_000_000)
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: tree.file)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: tree.file.path)
    let pipeline = ImageIOPipeline(identityResolver: FileItemIdentityResolver(root: tree.scope))
    let before = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128).renderKey)
    try Data(contentsOf: fixture("orientation-2.tiff")).write(to: tree.file, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: tree.file.path)
    let after = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128).renderKey)
    #expect(before.itemID == .rootRelative(rootID: tree.id, relativePath: "b.png"))
    #expect(after.itemID == before.itemID)
    #expect(after.revision.byteCount == before.revision.byteCount)
    #expect(after.revision.modificationDate == before.revision.modificationDate)
    #expect(before.revision.resourceIdentifier != nil)
    #expect(after.revision != before.revision)
    #expect(after != before)
    #expect(after.stableEncoding != before.stableEncoding)
    let fresh = ImageIOPipeline(identityResolver: FileItemIdentityResolver(root: tree.scope))
    let request = try await fresh.request(for: tree.file, maximumPixelSize: 128)
    #expect(request.renderKey == after)
    let decoded = try await fresh.image(for: request)
    #expect(decoded.itemID == after.itemID)
    #expect(decoded.revision == after.revision)
    let renamed = tree.root.appendingPathComponent("renamed.tiff")
    try FileManager.default.moveItem(at: tree.file, to: renamed)
    #expect(try await fresh.request(for: renamed, maximumPixelSize: 128).renderKey?.itemID == after.itemID)
}

@Test(.timeLimit(.minutes(2))) func identityPipelineAliasesShareCanonicalRevisions() async throws {
    let tree = try IdentityTree(); defer { tree.remove() }
    try Data(contentsOf: fixture("orientation-1.tiff")).write(to: tree.file)
    let link = tree.root.appendingPathComponent("alias.tiff")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tree.file)
    let pipeline = ImageIOPipeline(identityResolver: FileItemIdentityResolver(root: tree.scope))
    let original = try #require(try await pipeline.request(for: tree.file, maximumPixelSize: 128).renderKey)
    for alias in [link, tree.root.appendingPathComponent("a/../b.png")] {
        let request = try await pipeline.request(for: alias, maximumPixelSize: 128)
        #expect(request.renderKey == original)
        let decoded = try await pipeline.image(for: request)
        #expect(decoded.itemID == original.itemID)
        #expect(decoded.revision == original.revision)
    }
}
