import Foundation
import Testing
import MadoCore
@testable import MadoInfrastructure

private final class RemountEvidence: SecurityScope, BookmarkCoding, FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var mount = 0
    private var inode = "400"
    private var volume = "111"
    private var saved: FileResourceIdentity?
    private var counts = (0, 0)
    var requiresEmbeddedIdentity: Bool { true }
    func changeMount(inode: String = "400", volume: String = "111") {
        lock.withLock { mount += 1; self.inode = inode; self.volume = volume }
    }
    var currentVolume: String { lock.withLock { volume } }
    var savedIdentity: FileResourceIdentity? { lock.withLock { saved } }
    var scopeCounts: (Int, Int) { lock.withLock { counts } }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        lock.withLock { .init(volumeUUID: volume, fileIdentifier: "dev\(mount):\(inode):\(fileURL.lastPathComponent)") }
    }
    func recoveryIdentity(for fileURL: URL) -> FileResourceIdentity {
        lock.withLock { .init(volumeUUID: volume, fileIdentifier: "inode:\(inode):\(fileURL.lastPathComponent)") }
    }
    func create(for url: URL) throws -> Data {
        let identity = try identity(for: url)
        lock.withLock { saved = identity }
        return Data(url.path.utf8)
    }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        .init(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self), isDirectory: true), stale: false)
    }
    func start(_ url: URL) -> Bool { lock.withLock { counts.0 += 1 }; return true }
    func stop(_ url: URL) { lock.withLock { counts.1 += 1 } }
    func isReadable(_ url: URL) -> Bool { true }
}
private struct RemountStableReader: FileIdentityResourceReading {
    let evidence: RemountEvidence
    func identity(for fileURL: URL) throws -> FileResourceIdentity? { evidence.recoveryIdentity(for: fileURL) }
}
private actor RemountMounts: DiskMountPort {
    func mountedVolumes() -> [AccessProbeVolume] { [.init(uuid: "111", url: nil, name: nil)] }
    func events() -> AsyncStream<DiskMountEvent> { AsyncStream { $0.finish() } }
}
private struct RemountFixture {
    let base: URL, root: URL, child: URL
    let store: BookmarkStore
    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("Root", isDirectory: true)
        child = root.appendingPathComponent("Child", isDirectory: true)
        store = BookmarkStore(url: base.appendingPathComponent("roots.json"))
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
    func files(_ evidence: RemountEvidence, offline: Bool = false) throws -> FileAccess {
        try FileAccess(scope: evidence, bookmarks: evidence, store: store, buildSHA: "T229R2",
            resourceReader: evidence, recoveryResourceReader: RemountStableReader(evidence: evidence),
            bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) },
            resolvedVolumeUUID: { _ in evidence.currentVolume },
            bookmarkIdentity: { _ in evidence.savedIdentity },
            mountedVolumesProvider: { offline ? [] : [.init(uuid: "111", url: nil, name: nil)] })
    }
}

@Test(.timeLimit(.minutes(2))) func t229R2SameObjectSurvivesChangedMountTokens() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), files = try fixture.files(evidence)
    let id = try await files.grant(folder: fixture.root)
    let reference = try #require(await files.captureRecoveryFolder(rootID: id, folder: fixture.child))
    let saved = try Data(contentsOf: fixture.store.url)
    let oldRaw = try evidence.identity(for: fixture.root)
    evidence.changeMount()
    #expect(try evidence.identity(for: fixture.root) != oldRaw)
    let result = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause == .readable)
    #expect(result.folderURL?.standardizedFileURL.path == fixture.child.path)
    if result.classification.cause == .readable {
        let restored = try await files.resolveRecoveryFolder(reference, verifiedRoot: fixture.root)
        #expect(restored?.folderURL.path == fixture.child.path)
    }
    let repeated = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(repeated.classification.cause == .readable)
    #expect(try Data(contentsOf: fixture.store.url) == saved)
    #expect(evidence.scopeCounts.0 == evidence.scopeCounts.1)
}

@Test(.timeLimit(.minutes(2)), arguments: ["inode", "volume"])
func t229R2ChangedObjectStillRefusesRecovery(change: String) async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), files = try fixture.files(evidence)
    let id = try await files.grant(folder: fixture.root)
    evidence.changeMount(inode: change == "inode" ? "401" : "400", volume: change == "volume" ? "222" : "111")
    let result = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause != .readable)
    #expect(result.rootURL == nil && result.folderURL == nil)
    #expect(evidence.scopeCounts.0 == evidence.scopeCounts.1)
}

@Test(.timeLimit(.minutes(2))) func t229R2OfflineLaunchCannotInventRecoveryBaseline() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence()
    let original = try fixture.files(evidence)
    let id = try await original.grant(folder: fixture.root)
    evidence.changeMount()
    let offline = try fixture.files(evidence, offline: true)
    #expect(await offline.rootURL(id) == nil)
    let result = await offline.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause != .readable)
    #expect(result.rootURL == nil)
}

@Test func t229R2SystemSessionInodeProofIsNotPersisted() throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let codec = SystemSecurityScope(), reader = URLRecoveryIdentityResourceReader()
    let bookmark = try codec.create(for: fixture.root)
    let savedOpaque = try #require(AccessProbeFactGatherer.bookmarkIdentity(in: bookmark))
    #expect(try URLIdentityResourceReader().identity(for: fixture.root) == savedOpaque)
    let readIdentity = try reader.identity(for: fixture.root)
    let original = try #require(readIdentity)
    let attributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
    let inode = try #require(attributes[.systemFileNumber] as? NSNumber)
    #expect(original.fileIdentifier == "inode:\(inode.uint64Value)")
    let moved = fixture.base.appendingPathComponent("Moved", isDirectory: true)
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    #expect(try reader.identity(for: moved) == original)
    try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
    #expect(try reader.identity(for: fixture.root) != original)
    #expect(AccessProbeFactGatherer.bookmarkIdentity(in: bookmark) == savedOpaque)
}

private final class OptionalRecoveryReader: FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var missing = false
    private var throwing = false
    let evidence: RemountEvidence
    init(_ evidence: RemountEvidence) { self.evidence = evidence }
    func becomeMissing() { lock.withLock { missing = true } }
    func becomeThrowing() { lock.withLock { throwing = true } }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        try lock.withLock {
            if throwing { throw CocoaError(.fileReadNoPermission) }
            return missing ? nil : evidence.recoveryIdentity(for: fileURL)
        }
    }
}

@Test(.timeLimit(.minutes(2))) func t229R2MissingSessionProofCannotFallBackToMatchingOpaqueToken() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), reader = OptionalRecoveryReader(evidence)
    let files = try FileAccess(scope: evidence, bookmarks: evidence, store: fixture.store, buildSHA: "T229R2",
        resourceReader: evidence, recoveryResourceReader: reader,
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in evidence.savedIdentity })
    let id = try await files.grant(folder: fixture.root)
    reader.becomeMissing()
    let result = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause != .readable)
    #expect(result.rootURL == nil)
}

@Test(.timeLimit(.minutes(2))) func t229R2CapturedFolderRefusesDifferentInodeAtSamePath() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence()
    let files = try FileAccess(scope: evidence, bookmarks: evidence, store: fixture.store, buildSHA: "T229R2",
        resourceReader: evidence, recoveryResourceReader: URLRecoveryIdentityResourceReader(),
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in evidence.savedIdentity })
    let id = try await files.grant(folder: fixture.root)
    let reference = try #require(await files.captureRecoveryFolder(rootID: id, folder: fixture.child))
    evidence.changeMount()
    let verified = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(verified.classification.cause == .readable)
    try FileManager.default.moveItem(at: fixture.child, to: fixture.root.appendingPathComponent("OldChild"))
    try FileManager.default.createDirectory(at: fixture.child, withIntermediateDirectories: true)
    let restored = try await files.resolveRecoveryFolder(reference, verifiedRoot: fixture.root)
    #expect(restored == nil)
}

@Test(.timeLimit(.minutes(2))) func t229R2ThrowingSessionProofCannotFallBackToMatchingOpaqueToken() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), reader = OptionalRecoveryReader(evidence)
    let files = try FileAccess(scope: evidence, bookmarks: evidence, store: fixture.store, buildSHA: "T229R2",
        resourceReader: evidence, recoveryResourceReader: reader,
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in evidence.savedIdentity })
    let id = try await files.grant(folder: fixture.root)
    reader.becomeThrowing()
    let result = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause != .readable)
    #expect(result.rootURL == nil)
}

private final class ReplacementDuringCaptureReader: FileIdentityResourceReading, @unchecked Sendable {
    private let lock = NSLock()
    private var replaced = false
    let evidence: RemountEvidence
    init(_ evidence: RemountEvidence) { self.evidence = evidence }
    func identity(for fileURL: URL) throws -> FileResourceIdentity? {
        lock.withLock {
            if !replaced { evidence.changeMount(inode: "401"); replaced = true }
            return evidence.recoveryIdentity(for: fileURL)
        }
    }
}

@Test(.timeLimit(.minutes(2))) func t229R2ReplacementDuringCaptureCannotEstablishItsOwnBaseline() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence()
    let files = try FileAccess(scope: evidence, bookmarks: evidence, store: fixture.store, buildSHA: "T229R2",
        resourceReader: evidence, recoveryResourceReader: ReplacementDuringCaptureReader(evidence),
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in evidence.savedIdentity })
    let id = try await files.grant(folder: fixture.root)
    let result = await files.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause != .readable)
    #expect(result.rootURL == nil)
}

@Test(.timeLimit(.minutes(2))) func t229R2OnlineLaunchCapturesSessionProofBeforeLaterRemount() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), original = try fixture.files(evidence)
    let id = try await original.grant(folder: fixture.root)
    let saved = try Data(contentsOf: fixture.store.url)
    let launched = try fixture.files(evidence)
    #expect(await launched.rootURL(id)?.standardizedFileURL.path == fixture.root.path)
    #expect(await launched.launchOutcomes()[id] == "resolved")
    evidence.changeMount()
    let result = await launched.verifySavedRootForRecovery(id, folder: fixture.child, mounts: RemountMounts())
    #expect(result.classification.cause == .readable)
    #expect(result.folderURL?.standardizedFileURL.path == fixture.child.path)
    #expect(try Data(contentsOf: fixture.store.url) == saved)
    #expect(evidence.scopeCounts.0 == evidence.scopeCounts.1)
}

@Test(.timeLimit(.minutes(2))) func t229R2LegacyWithoutInodeRetainsRawProofAndRejectsChangedObject() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), unavailable = OptionalRecoveryReader(evidence)
    unavailable.becomeMissing()
    let id = AccessRootID(), bookmark = try evidence.create(for: fixture.root)
    try fixture.store.save([AccessRootRecord(id: id, bookmark: bookmark, displayName: "Root",
        creatingBuildSHA: "T229R2-legacy", createdAt: Date())])
    let saved = try Data(contentsOf: fixture.store.url)
    let file = fixture.root.appendingPathComponent("readable.txt")
    let expected = Data("readable under the observed raw legacy proof".utf8)
    try expected.write(to: file)
    let files = try FileAccess(scope: evidence, bookmarks: evidence, store: fixture.store, buildSHA: "T229R2",
        resourceReader: evidence, recoveryResourceReader: unavailable,
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in nil }, mountedVolumesProvider: { [.init(uuid: "111", url: nil, name: nil)] })
    #expect(await files.rootURL(id)?.standardizedFileURL.path == fixture.root.path)
    let read = try await files.withLease(.root(id, file: file)) { _ in try Data(contentsOf: file) }
    #expect(read == expected)
    evidence.changeMount(inode: "401")
    await #expect(throws: FileAccessError.needsReconnection(id)) {
        try await files.withLease(.root(id, file: file)) { _ in try Data(contentsOf: file) }
    }
    #expect(await files.rootURL(id) == nil)
    #expect(try Data(contentsOf: fixture.store.url) == saved)
    #expect(evidence.scopeCounts.0 == evidence.scopeCounts.1)
}

private struct RemountStaleCodec: BookmarkCoding {
    let evidence: RemountEvidence
    var requiresEmbeddedIdentity: Bool { true }
    func create(for url: URL) throws -> Data { try evidence.create(for: url) }
    func resolve(_ data: Data) throws -> ResolvedBookmark {
        let resolved = try evidence.resolve(data)
        return ResolvedBookmark(url: resolved.url, stale: true)
    }
}

@Test(.timeLimit(.minutes(2))) func t229R2StaleRefreshWithoutInodeUsesValidOpaqueProofAndInvalidatesOldFence() async throws {
    let fixture = try RemountFixture(); defer { fixture.remove() }
    let evidence = RemountEvidence(), unavailable = OptionalRecoveryReader(evidence)
    unavailable.becomeMissing()
    let file = fixture.root.appendingPathComponent("readable.txt")
    let expected = Data("raw opaque proof still permits a safe bookmark refresh".utf8)
    try expected.write(to: file)
    let files = try FileAccess(scope: evidence, bookmarks: RemountStaleCodec(evidence: evidence),
        store: fixture.store, buildSHA: "T229R2", resourceReader: evidence, recoveryResourceReader: unavailable,
        bookmarkVolume: { _ in .init(uuid: "111", url: nil, name: nil) }, resolvedVolumeUUID: { _ in "111" },
        bookmarkIdentity: { _ in evidence.savedIdentity },
        mountedVolumesProvider: { [.init(uuid: "111", url: nil, name: nil)] })
    let id = try await files.grant(folder: fixture.root)
    let before = try #require(await files.savedGrantSnapshot(id))
    let read = try await files.withLease(.root(id, file: file)) { _ in try Data(contentsOf: file) }
    #expect(read == expected)
    #expect(throws: CancellationError.self) { try before.admitting { before.record.id } }
    let refreshed = try #require(await files.savedGrantSnapshot(id))
    #expect(try refreshed.admitting { refreshed.record.id } == id)
    #expect(try fixture.store.load().first?.bookmark == refreshed.record.bookmark)
    #expect(evidence.scopeCounts.0 == evidence.scopeCounts.1)
}
