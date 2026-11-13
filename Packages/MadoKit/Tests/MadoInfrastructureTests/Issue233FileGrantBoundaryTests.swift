import Foundation
import Darwin
import Testing
import MadoCore
import MadoApplication
import MadoInfrastructure

private actor LossLeaseRecorder: AccessLeasing {
    let real: FileAccess
    var requests: [AccessRequest] = []
    var active: Set<UUID> = []
    init(_ real: FileAccess) { self.real = real }
    func acquire(_ request: AccessRequest) async throws -> AccessLease {
        requests.append(request)
        let lease = try await real.acquire(request)
        active.insert(lease.token)
        return lease
    }
    func release(_ lease: AccessLease) async { await real.release(lease); active.remove(lease.token) }
}

@Test(.timeLimit(.minutes(2))) func issue233PackageFileGrantReadersNeverRequestRootLease() async throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: base) }
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("TestAssets/synthetic/landscape-3x2.png")
    let file = base.appendingPathComponent("image.png")
    try fm.copyItem(at: fixture, to: file)
    let scope = SystemSecurityScope()
    let real = try FileAccess(scope: scope, bookmarks: scope,
        store: BookmarkStore(url: base.appendingPathComponent("roots.json")), buildSHA: "issue233")
    let access = LossLeaseRecorder(real)
    let descriptor = try await FileGrantWatchDescriptor.open(grant: file, access: access) { Darwin.open($0.path, O_EVTONLY) }
    #expect(descriptor >= 0)
    #expect(await access.active.isEmpty)
    #expect(Darwin.close(descriptor) == 0)
    #expect(Darwin.fcntl(descriptor, F_GETFD) == -1)
    let source = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: ImageIOPipeline())
    let (request, image) = try await source.image(maximumPixelSize: 128)
    #expect(request.fileURL.standardizedFileURL.resolvingSymlinksInPath() == file.standardizedFileURL.resolvingSymlinksInPath())
    #expect(image.sourcePixelSize.width > image.sourcePixelSize.height)
    await source.close()
    #expect(await access.active.isEmpty)
    try fm.removeItem(at: file)
    await #expect(throws: (any Error).self) {
        _ = try await AccessImageSource.open(.fileGrant(file), access: access, pipeline: ImageIOPipeline())
    }
    await #expect(throws: (any Error).self) {
        _ = try await FileGrantWatchDescriptor.open(grant: file, access: access) { Darwin.open($0.path, O_EVTONLY) }
    }
    #expect(await access.active.isEmpty)
    let requests = await access.requests
    #expect(requests.count >= 5)
    #expect(requests.allSatisfy { $0 == .fileGrant(file) })
    #expect(!fm.fileExists(atPath: base.appendingPathComponent("roots.json").path))
}
