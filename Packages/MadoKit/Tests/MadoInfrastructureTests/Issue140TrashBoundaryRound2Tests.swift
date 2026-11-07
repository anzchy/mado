import Foundation
import Testing
import MadoCore
import MadoApplication
@testable import MadoInfrastructure

@Test func issue140OrdinaryDotTrashFolderKeepsMovedFileGrantLive() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let ordinaryTrash = base.appendingPathComponent(".Trash")
    try fm.createDirectory(at: ordinaryTrash, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let original = base.appendingPathComponent("image.png")
    let moved = ordinaryTrash.appendingPathComponent("image.png")
    try fm.copyItem(at: fixture("landscape-3x2.png"), to: original)
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue140-r2-trash-boundary")
    let source = try await AccessImageSource.open(.fileGrant(original), access: access,
        pipeline: ImageIOPipeline())
    _ = try await source.image(maximumPixelSize: 64)
    try fm.moveItem(at: original, to: moved)
    let resolved = try? await access.resolveFileGrant(original)
    #expect(resolved?.standardizedFileURL == moved.standardizedFileURL)
    let next = try? await source.image(maximumPixelSize: 64)
    #expect(next?.0.fileURL.standardizedFileURL == moved.standardizedFileURL)
    await source.close()
}
