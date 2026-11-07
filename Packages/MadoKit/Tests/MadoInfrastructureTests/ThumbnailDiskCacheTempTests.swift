import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

@Test func p304OwnedStaleTempFilesAreSweptWithoutTouchingOtherFiles() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("image.tiff")
    let cacheDirectory = folder.appendingPathComponent("cache")
    try FileManager.default.copyItem(at: fixture("orientation-1.tiff"), to: file)
    let root = ItemIdentityRoot(id: AccessRootID(), url: folder)
    let pipeline = ImageIOPipeline()
    let request = try await pipeline.request(for: file, maximumPixelSize: 128, identityRoot: root)
    let decoded = try await pipeline.image(for: request)
    let cache = ThumbnailDiskCache(directory: cacheDirectory)
    let ticket = try #require(try await cache.prepare(request))
    try await cache.store(decoded, for: ticket)
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path).allSatisfy { !$0.hasPrefix(".tmp-") })

    let stale = cacheDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)")
    let current = cacheDirectory.appendingPathComponent(".tmp-\(UUID().uuidString)")
    let foreign = cacheDirectory.appendingPathComponent("payload.png.tmp-\(UUID().uuidString)")
    let outside = folder.appendingPathComponent(".tmp-\(UUID().uuidString)")
    for url in [stale, current, foreign, outside] { try Data("sentinel".utf8).write(to: url) }
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: stale.path)
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: foreign.path)
    try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: outside.path)

    #expect(try await ThumbnailDiskCache(directory: cacheDirectory).load(ticket).map { _ in true } == true)
    #expect(!FileManager.default.fileExists(atPath: stale.path))
    #expect(FileManager.default.fileExists(atPath: current.path))
    #expect(FileManager.default.fileExists(atPath: foreign.path))
    #expect(FileManager.default.fileExists(atPath: outside.path))
    #expect(try Data(contentsOf: outside) == Data("sentinel".utf8))
}
