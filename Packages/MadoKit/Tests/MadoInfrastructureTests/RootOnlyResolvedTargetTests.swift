import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private actor T229ResolvedTargetMounts: DiskMountPort {
    let volume: AccessProbeVolume
    init(_ volume: AccessProbeVolume) { self.volume = volume }
    func mountedVolumes() -> [AccessProbeVolume] { [volume] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}

@Test func t229RootOnlyResolvedTargetNeverRebasesAlreadyResolvedRoot() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let oldRoot = base.appendingPathComponent("old-mount/chosen", isDirectory: true)
    try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    let identity = try #require(try URLIdentityResourceReader().identity(for: oldRoot))
    let volume = AccessProbeVolume(uuid: "111", url: base, name: "Photos")
    let scope = CountingScope(), codec = FakeBookmarks()
    let files = try FileAccess(scope: scope, bookmarks: codec,
        store: BookmarkStore(url: base.appendingPathComponent("support/roots.json")), buildSHA: "T229-WI5",
        bookmarkVolume: { _ in volume }, resolvedVolumeUUID: { _ in "111" }, bookmarkIdentity: { _ in identity })
    let id = try await files.grant(folder: oldRoot)
    let parked = base.appendingPathComponent("parked-original")
    try FileManager.default.moveItem(at: oldRoot, to: parked)
    try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    let resolvedRoot = oldRoot.appendingPathComponent("new-mount/chosen", isDirectory: true)
    try FileManager.default.createDirectory(at: resolvedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: parked, to: resolvedRoot)
    codec.relocated = resolvedRoot
    #expect(try URLIdentityResourceReader().identity(for: resolvedRoot) == identity)
    let result = await files.verifySavedRootForRecovery(id, mounts: T229ResolvedTargetMounts(volume))
    #expect(result.classification.cause == .readable)
    #expect(result.rootURL == resolvedRoot && result.folderURL == resolvedRoot)
    #expect(scope.counts[0] == scope.counts[1])
}
