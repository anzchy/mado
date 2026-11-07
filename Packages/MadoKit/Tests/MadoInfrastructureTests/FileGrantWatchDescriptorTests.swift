import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure
import Darwin

@Test func issue140FileGrantDescriptorOpensInsideResolvedScope() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let file = f.url("root/image.png")
    try Data([1]).write(to: file)
    let descriptor = try await FileGrantWatchDescriptor.open(grant: file, access: f.access) { resolved in
        #expect(resolved == file)
        #expect(f.scope.counts == [1, 0])
        return 42
    }
    #expect(descriptor == 42)
    #expect(f.scope.counts == [1, 1])
}

@Test func issue140RealFileGrantDescriptorHasBalancedScope() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("image.png")
    try Data([1]).write(to: file)
    let scope = SystemSecurityScope()
    let access = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: directory.appendingPathComponent("roots.json")), buildSHA: "issue140-watch")
    let descriptor = try await FileGrantWatchDescriptor.open(grant: file, access: access) {
        Darwin.open($0.path, O_EVTONLY)
    }
    #expect(descriptor >= 0)
    if descriptor >= 0 { _ = Darwin.close(descriptor) }
}

@Test @MainActor func issue140FailedFileGrantWatchLogsOnceAndUsesForegroundFallback() async throws {
    let f = try WatchFixture(folders: ["root"]); defer { f.remove() }
    let file = f.url("root/image.png")
    try Data([1]).write(to: file)
    let fallback = FileGrantWatchFallback()
    for attempt in 0..<2 {
        let descriptor = try await FileGrantWatchDescriptor.open(grant: file, access: f.access) { _ in -1 }
        #expect(descriptor == -1)
        #expect(fallback.recordFailure(file) == (attempt == 0))
    }
    #expect(fallback.foregroundOnly.contains(file.standardizedFileURL))
    #expect(f.scope.counts == [2, 2])
}
