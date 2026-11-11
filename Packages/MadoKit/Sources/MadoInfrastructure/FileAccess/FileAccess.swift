import Foundation
import MadoCore
import os
import Darwin

/// One lease lifetime; only a successfully started security scope requires a stop.
private struct ScopeSession {
    static let log = OSLog(subsystem: "io.github.anzchy.mado", category: "access")
    let scope: any SecurityScope
    let url: URL
    let rootID: AccessRootID?
    let trace: OSSignpostID
    let scopeStarted: Bool
    init(scope: any SecurityScope, url: URL, rootID: AccessRootID?) throws {
        let started = scope.start(url)
        // Finder drops/open events may already carry sandbox read access without
        // a startable URL scope. Bookmark roots still require their own scope.
        guard started || (rootID == nil && scope.isReadable(url)) else { throw FileAccessError.startFailed }
        scopeStarted = started
        self.scope = scope; self.url = url; self.rootID = rootID
        trace = OSSignpostID(log: Self.log)
        os_signpost(.begin, log: Self.log, name: "AccessLease", signpostID: trace, "outcome=leased scopeStarted=%{public}d", started ? 1 : 0)
    }
    func stop() {
        if scopeStarted { scope.stop(url) }
        os_signpost(.end, log: Self.log, name: "AccessLease", signpostID: trace, "outcome=released")
        Logger(subsystem: "io.github.anzchy.mado", category: "access").notice("AccessLease root=\(rootID?.rawValue.uuidString ?? "file", privacy: .public) remaining=0 outcome=released scopeStarted=\(scopeStarted, privacy: .public) path=\(url.path, privacy: .private)")
    }
}

public struct AccessRecoveryVerification: Sendable {
    public let classification: AccessProbeClassification
    public let bookmarkVolume: AccessProbeVolume
    public let rootURL: URL?
    public let folderURL: URL?
    public init(classification: AccessProbeClassification, bookmarkVolume: AccessProbeVolume,
                rootURL: URL?, folderURL: URL?) {
        self.classification = classification
        self.bookmarkVolume = bookmarkVolume
        self.rootURL = rootURL
        self.folderURL = folderURL
    }
}

/// Shared by the application. All persisted-grant I/O runs on this actor's executor.
public actor FileAccess: AccessLeasing {
    public nonisolated let diagnostics: AccessDiagnostics
    private let scope: any SecurityScope
    private let bookmarks: any BookmarkCoding
    private let requiresEmbeddedIdentity: Bool
    private let resourceReader: any FileIdentityResourceReading
    private let recoveryResourceReader: any FileIdentityResourceReading
    private let bookmarkVolume: @Sendable (Data) -> AccessProbeVolume
    private let resolvedVolumeUUID: @Sendable (URL) throws -> String?
    private let bookmarkLocation: @Sendable (Data) -> URL?
    private let bookmarkIdentity: @Sendable (Data) -> FileResourceIdentity?
    private let mountedVolumesProvider: @Sendable () -> [AccessProbeVolume]
    private let store: BookmarkStore
    private let boundary: @Sendable (URL, URL) -> Bool
    private let buildSHA: String
    public let storeCorrupt: Bool
    private var saved: [AccessRootRecord]
    private struct SavedGrantVersion {
        let authority = AccessWorkAuthority()
        var counter: UInt64 = 0
    }
    private var savedGrantVersions: [AccessRootID: SavedGrantVersion] = [:]
    private var roots: [AccessRootID: URL] = [:]
    /// Location memory only; never used as an access grant.
    private var lastKnownRoots: [AccessRootID: URL] = [:]
    /// Legacy bookmarks have no embedded root identity. This baseline is valid
    /// only for roots verified as readable during this process lifetime.
    private var legacyBaseline: [AccessRootID: FileResourceIdentity] = [:]
    /// Established only while the saved opaque proof is still valid. Session-only:
    /// inode values are not durable across arbitrary filesystems or process launches.
    private var recoveryBaseline: [AccessRootID: FileResourceIdentity] = [:]
    private var previousRoots: [AccessRootID: [URL]] = [:]
    private var outcomes: [AccessRootID: String] = [:]
    private struct Active { let session: ScopeSession; var tokens: Set<UUID> }
    private enum SessionKey: Hashable { case root(AccessRootID, URL), file(URL, URL) }
    private var active: [SessionKey: Active] = [:]
    private var requests: [UUID: SessionKey] = [:]
    /// Session-only: File Grants never become persisted Access Roots.
    private struct FileGrantBookmark { var data: Data; var resource: FileResourceIdentity? }
    private var fileBookmarks: [URL: FileGrantBookmark] = [:]

    public init(scope: any SecurityScope, bookmarks: any BookmarkCoding, store: BookmarkStore, buildSHA: String,
                diagnostics: AccessDiagnostics = AccessDiagnostics(),
                resourceReader: (any FileIdentityResourceReading)? = nil,
                recoveryResourceReader: (any FileIdentityResourceReading)? = nil,
                requiresEmbeddedIdentity: Bool? = nil,
                boundary: @escaping @Sendable (URL, URL) -> Bool = { AccessBoundary.contains($0, in: $1) },
                bookmarkVolume: @escaping @Sendable (Data) -> AccessProbeVolume = { AccessProbeFactGatherer.bookmarkVolume(in: $0) },
                resolvedVolumeUUID: @escaping @Sendable (URL) throws -> String? = {
                    try $0.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                },
                bookmarkLocation: @escaping @Sendable (Data) -> URL? = {
                    URL.resourceValues(forKeys: [.pathKey], fromBookmarkData: $0)?.path.map { URL(fileURLWithPath: $0) }
                },
                bookmarkIdentity: @escaping @Sendable (Data) -> FileResourceIdentity? = {
                    AccessProbeFactGatherer.bookmarkIdentity(in: $0)
                },
                mountedVolumesProvider: @escaping @Sendable () -> [AccessProbeVolume] = {
                    AccessProbeFactGatherer.mountedVolumes(at: FileManager.default.mountedVolumeURLs(
                        includingResourceValuesForKeys: [.volumeUUIDStringKey, .volumeNameKey, .volumeURLKey],
                        options: []))
                }) throws {
        self.diagnostics = diagnostics
        self.boundary = boundary
        self.scope = scope; self.bookmarks = bookmarks; self.buildSHA = buildSHA
        self.requiresEmbeddedIdentity = requiresEmbeddedIdentity ?? bookmarks.requiresEmbeddedIdentity
        let liveReader = resourceReader ?? URLIdentityResourceReader()
        let recoveryReader = recoveryResourceReader ?? resourceReader ?? URLRecoveryIdentityResourceReader()
        self.resourceReader = liveReader
        self.recoveryResourceReader = recoveryReader
        self.bookmarkVolume = bookmarkVolume
        self.resolvedVolumeUUID = resolvedVolumeUUID
        self.bookmarkLocation = bookmarkLocation
        self.bookmarkIdentity = bookmarkIdentity
        self.mountedVolumesProvider = mountedVolumesProvider
        do {
            saved = try store.load()
            self.store = store; storeCorrupt = false
        } catch {
            // Preserve the damaged evidence; subsequent grants persist separately.
            let recovery = BookmarkStore(url: store.url.appendingPathExtension("recovered"))
            saved = (try? recovery.load()) ?? []
            self.store = recovery; storeCorrupt = true
            Logger(subsystem: "io.github.anzchy.mado", category: "access").error("AccessStore kind=storeCorrupt")
        }
        let logger = Logger(subsystem: "io.github.anzchy.mado", category: "access")
        for index in saved.indices {
            let record = saved[index]
            var outcome = "failed"
            do {
                let volume = bookmarkVolume(record.bookmark)
                if let uuid = volume.uuid {
                    guard mountedVolumesProvider().contains(where: { $0.uuid == uuid }) else {
                        // A no-mount resolve may recover the previous path for child rebasing.
                        // It is a location hint, never a published access grant.
                        lastKnownRoots[record.id] = try? bookmarks.resolve(record.bookmark).url
                        throw FileAccessError.needsReconnection(record.id)
                    }
                }
                // A volume without a UUID (typically a network share) cannot embed
                // identity and has no remount tracking; a scoped listing still gates it.
                let isUUIDLess = self.requiresEmbeddedIdentity && volume.uuid == nil
                let resolution = try bookmarks.resolve(record.bookmark)
                guard !Self.isTrashed(resolution.url) else {
                    throw FileAccessError.needsReconnection(record.id)
                }
                if volume.uuid != nil || isUUIDLess, (try? resolvedVolumeUUID(resolution.url)) != volume.uuid {
                    throw FileAccessError.needsReconnection(record.id)
                }
                let isLegacy = self.requiresEmbeddedIdentity && !isUUIDLess && bookmarkIdentity(record.bookmark) == nil
                if isLegacy {
                    let session = try ScopeSession(scope: scope, url: resolution.url, rootID: record.id)
                    defer { session.stop() }
                    _ = try FileManager.default.contentsOfDirectory(at: resolution.url,
                        includingPropertiesForKeys: nil)
                    guard let identity = try liveReader.identity(for: resolution.url) else {
                        throw FileAccessError.needsReconnection(record.id)
                    }
                    legacyBaseline[record.id] = identity
                    recoveryBaseline[record.id] = Self.trustedRecoveryIdentity(at: resolution.url,
                        expected: identity, rawReader: liveReader, recoveryReader: recoveryReader)
                    outcome = "resolved"
                } else if resolution.stale || isUUIDLess {
                    let session = try ScopeSession(scope: scope, url: resolution.url, rootID: record.id)
                    defer { session.stop() }
                    if let expected = bookmarkIdentity(record.bookmark),
                       (try? liveReader.identity(for: resolution.url)) != expected {
                        throw FileAccessError.needsReconnection(record.id)
                    }
                    if volume.uuid != nil || isUUIDLess {
                        _ = try FileManager.default.contentsOfDirectory(at: resolution.url,
                            includingPropertiesForKeys: nil)
                    }
                    if resolution.stale {
                        var refreshed = saved
                        refreshed[index].bookmark = try bookmarks.create(for: resolution.url)
                        try self.store.save(refreshed)
                        saved = refreshed
                        outcome = "stale"
                    } else { outcome = "resolved" }
                    recoveryBaseline[record.id] = Self.trustedRecoveryIdentity(at: resolution.url,
                        expected: bookmarkIdentity(record.bookmark), rawReader: liveReader, recoveryReader: recoveryReader)
                } else {
                    outcome = "resolved"
                    if let expected = bookmarkIdentity(record.bookmark),
                       let session = try? ScopeSession(scope: scope, url: resolution.url, rootID: record.id) {
                        defer { session.stop() }
                        recoveryBaseline[record.id] = Self.trustedRecoveryIdentity(at: resolution.url,
                            expected: expected, rawReader: liveReader, recoveryReader: recoveryReader)
                    }
                }
                roots[record.id] = resolution.url
                lastKnownRoots[record.id] = resolution.url
            } catch { outcome = "failed" }
            outcomes[record.id] = outcome
            logger.notice("AccessRoot root=\(record.id.rawValue.uuidString, privacy: .public) outcome=\(outcome, privacy: .public) creating=\(record.creatingBuildSHA, privacy: .public) current=\(buildSHA, privacy: .public)")
        }
    }
    /// Caller owns the scope. No baseline is first established by recovery itself.
    private static func trustedRecoveryIdentity(at root: URL, expected: FileResourceIdentity?,
        rawReader: any FileIdentityResourceReading, recoveryReader: any FileIdentityResourceReading) -> FileResourceIdentity? {
        guard let expected, (try? rawReader.identity(for: root)) == expected,
              (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) != nil else { return nil }
        let identity = try? recoveryReader.identity(for: root)
        // A replacement during metadata/listing must not establish its own proof.
        guard (try? rawReader.identity(for: root)) == expected else { return nil }
        return identity
    }
    public func savedGrantSnapshot(_ id: AccessRootID) -> SavedAccessGrantSnapshot? {
        guard let record = saved.first(where: { $0.id == id }) else { return nil }
        let version = savedGrantVersions[id] ?? SavedGrantVersion()
        savedGrantVersions[id] = version
        return SavedAccessGrantSnapshot(record: record, bookmarkVolume: bookmarkVolume(record.bookmark),
            rootURL: roots[id], version: version.authority.permit(counter: version.counter))
    }
    /// No await may separate this fence from the attempted persistent mutation.
    /// A failed save conservatively invalidates previously captured versions too.
    private func invalidateSavedGrantVersion(_ id: AccessRootID) {
        guard var version = savedGrantVersions[id] else { return }
        version.counter += 1
        version.authority.update(counter: version.counter, readable: true)
        savedGrantVersions[id] = version
    }
    private struct RebindMemory {
        let saved: [AccessRootRecord]
        let roots: [AccessRootID: URL]
        let lastKnown: [AccessRootID: URL]
        let legacy: [AccessRootID: FileResourceIdentity]
        let recovery: [AccessRootID: FileResourceIdentity]
        let previous: [AccessRootID: [URL]]
        let explicitTrash: [AccessRootID: ExplicitTrashSelection]
    }
    private struct RebindUndo {
        let sourceID: AccessRootID
        let before: AccessStoreBytes
        let memory: RebindMemory
        let recentStore: RecentFolderStore
    }
    private struct ExplicitTrashSelection {
        let url: URL
        let identity: FileResourceIdentity
    }
    private var explicitTrashSelections: [AccessRootID: ExplicitTrashSelection] = [:]
    private var rebindUndos: [AccessRebindUndoToken: RebindUndo] = [:]

    /// Explicit panel selection replaces location and identity, never image state.
    /// No suspension separates persistence, rollback and logical publication.
    public func rebind(_ id: AccessRootID, folder: URL, recentStore: RecentFolderStore,
                       existenceProbe: @Sendable (URL) throws -> Void = { _ = try $0.resourceValues(forKeys: [.isDirectoryKey]) }) throws -> AccessRebindResult {
        let prefix = "AccessTransaction root=\(id.rawValue.uuidString) operation=rebind"
        var stage = "source"
        diagnostics.emit("\(prefix) outcome=attempt stage=begin kind=none")
        do {
            guard !storeCorrupt, let source = saved.first(where: { $0.id == id }) else { throw FileAccessError.corruptStore }
            guard let oldRoot = lastKnownRoots[id] ?? roots[id] ?? bookmarkLocation(source.bookmark) else {
                throw FileAccessError.invalidFolder
            }
            // Foreground checks may follow an inactive root without refreshing its
            // Recent references. Capture trusted locations before retiring history.
            let oldRoots = [oldRoot] + (previousRoots[id] ?? []).reversed()
            stage = "selection"
            let session = try ScopeSession(scope: scope, url: folder, rootID: id)
            defer { session.stop() }
            let destination = canonical(folder)
            guard try destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw FileAccessError.invalidFolder }
            _ = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            let matching = persistedDestination(destination, excluding: id)
            let destinationID = matching ?? AccessRootID()
            let bookmark = try bookmarks.create(for: destination)
            let selectedTrash = try explicitTrashEvidence(at: destination)
            var replacement = saved.filter { $0.id != id }
            if let index = replacement.firstIndex(where: { $0.id == destinationID }) {
                replacement[index].bookmark = bookmark
            } else {
                let record = AccessRootRecord(id: destinationID, bookmark: bookmark, displayName: destination.lastPathComponent,
                                              creatingBuildSHA: buildSHA, createdAt: Date())
                replacement.insert(record, at: saved.firstIndex(where: { $0.id == id })!)
            }
            let result = try recentStore.withTransaction { recentURL in
                stage = "validateRoots"
                try AccessStoreBytes.validate(store.url, as: AccessRootRecord.self)
                stage = "validateRecents"
                try AccessStoreBytes.validate(recentURL, as: RecentFolder.self)
                stage = "snapshot"
                let before = try AccessStoreBytes(urls: [store.url, recentURL])
                stage = "readRecents"
                let recent: [RecentFolder]
                if FileManager.default.fileExists(atPath: recentURL.path) {
                    switch try StoredSchema.decodeItems(Data(contentsOf: recentURL), as: RecentFolder.self, at: recentURL) {
                    case .current(let values): recent = values
                    case .unsupported: throw FileAccessError.corruptStore
                    }
                } else { recent = [] }
                let remapped = AccessRecentRemap.remap(recent, sourceID: id, oldRoots: oldRoots,
                    destinationID: destinationID, newRoot: destination, probe: existenceProbe)
                let memory = RebindMemory(saved: saved, roots: roots, lastKnown: lastKnownRoots,
                    legacy: legacyBaseline, recovery: recoveryBaseline, previous: previousRoots,
                    explicitTrash: explicitTrashSelections)
                stage = "cancellation"
                try Task.checkCancellation()
                invalidateSavedGrantVersion(id)
                invalidateSavedGrantVersion(destinationID)
                do {
                    // Use the strict writer: legacy save() intentionally swallows future schemas.
                    stage = "writeRoots"
                    try StoredSchema.writeItems(replacement, to: store.url)
                    stage = "writeRecents"
                    try StoredSchema.writeItems(remapped, to: recentURL)
                    stage = "publish"
                    let token = AccessRebindUndoToken(id: UUID())
                    saved = replacement
                    roots.removeValue(forKey: id)
                    lastKnownRoots.removeValue(forKey: id)
                    legacyBaseline.removeValue(forKey: id)
                    recoveryBaseline.removeValue(forKey: id)
                    previousRoots.removeValue(forKey: id)
                    explicitTrashSelections.removeValue(forKey: id)
                    legacyBaseline.removeValue(forKey: destinationID)
                    recoveryBaseline.removeValue(forKey: destinationID)
                    explicitTrashSelections[destinationID] = selectedTrash
                    publishRoot(destinationID, url: destination)
                    rebindUndos[token] = RebindUndo(sourceID: id, before: before, memory: memory,
                        recentStore: recentStore)
                    return AccessRebindResult(rootID: destinationID, rootURL: destination, undo: token)
                } catch {
                    let failedStage = stage
                    stage = "restorePrevious"
                    diagnostics.emit("\(prefix) outcome=rollback stage=\(stage) kind=\(AccessDiagnostics.errorKind(error))")
                    try before.restore()
                    stage = failedStage
                    throw error
                }
            }
            diagnostics.emit("\(prefix) outcome=commit stage=publish kind=none")
            return result
        } catch {
            diagnostics.emit("\(prefix) outcome=error stage=\(stage) kind=\(AccessDiagnostics.errorKind(error))")
            throw error
        }
    }

    public func undoRebind(_ token: AccessRebindUndoToken) throws {
        let root = rebindUndos[token]?.sourceID.rawValue.uuidString ?? "unknown"
        let prefix = "AccessTransaction root=\(root) operation=undo"
        var stage = "token"
        diagnostics.emit("\(prefix) outcome=attempt stage=begin kind=none")
        do {
            guard let undo = rebindUndos[token] else { throw FileAccessError.invalidFolder }
            try undo.recentStore.withTransaction { recentURL in
                stage = "snapshot"
                let current = try AccessStoreBytes(urls: [store.url, recentURL])
                stage = "validateRoots"
                try AccessStoreBytes.validate(store.url, as: AccessRootRecord.self)
                stage = "validateRecents"
                try AccessStoreBytes.validate(recentURL, as: RecentFolder.self)
                stage = "cancellation"
                try Task.checkCancellation()
                for id in Set(saved.map(\.id)).union(undo.memory.saved.map(\.id)) { invalidateSavedGrantVersion(id) }
                stage = "restore"
                do { try undo.before.restore() }
                catch {
                    stage = "restoreCurrent"
                    diagnostics.emit("\(prefix) outcome=rollback stage=\(stage) kind=\(AccessDiagnostics.errorKind(error))")
                    try current.restore()
                    stage = "restore"
                    throw error
                }
                stage = "publish"
                saved = undo.memory.saved
                roots = undo.memory.roots
                lastKnownRoots = undo.memory.lastKnown
                legacyBaseline = undo.memory.legacy
                recoveryBaseline = undo.memory.recovery
                previousRoots = undo.memory.previous
                explicitTrashSelections = undo.memory.explicitTrash
                rebindUndos.removeValue(forKey: token)
            }
            diagnostics.emit("\(prefix) outcome=commit stage=publish kind=none")
        } catch {
            diagnostics.emit("\(prefix) outcome=error stage=\(stage) kind=\(AccessDiagnostics.errorKind(error))")
            throw error
        }
    }

    public func discardRebindUndo(_ token: AccessRebindUndoToken) { rebindUndos.removeValue(forKey: token) }
    /// Match fresh bookmark resolution under its own scope, including a persisted
    /// destination whose published location was dropped by an earlier failed read.
    private func persistedDestination(_ destination: URL, excluding id: AccessRootID) -> AccessRootID? {
        for record in saved {
            guard record.id != id else { continue }
            guard let resolution = try? bookmarks.resolve(record.bookmark),
                  let session = try? ScopeSession(scope: scope, url: resolution.url, rootID: record.id) else { continue }
            defer { session.stop() }
            guard canonical(resolution.url) == destination else { continue }
            if let expected = bookmarkIdentity(record.bookmark),
               (try? resourceReader.identity(for: destination)) != expected { continue }
            if let uuid = bookmarkVolume(record.bookmark).uuid,
               (try? resolvedVolumeUUID(destination)) != uuid { continue }
            return record.id
        }
        return nil
    }
    private func explicitTrashEvidence(at destination: URL) throws -> ExplicitTrashSelection? {
        guard Self.isTrashed(destination) else { return nil }
        guard let identity = try recoveryResourceReader.identity(for: destination) else { throw FileAccessError.invalidFolder }
        return ExplicitTrashSelection(url: destination, identity: identity)
    }
    private func permitsExplicitTrash(_ id: AccessRootID, at url: URL) -> Bool {
        guard let selected = explicitTrashSelections[id], canonical(url) == selected.url else { return false }
        return true
    }
    /// Session-only panel selection verification. Automatic recovery never calls this.
    public func verifyExplicitSelection(_ id: AccessRootID) throws -> URL {
        guard let record = saved.first(where: { $0.id == id }), let root = roots[id] else { throw FileAccessError.needsReconnection(id) }
        let session = try ScopeSession(scope: scope, url: root, rootID: id)
        defer { session.stop() }
        let resolved = try bookmarks.resolve(record.bookmark).url
        guard canonical(root) == canonical(resolved),
              !Self.isTrashed(resolved) || permitsExplicitTrash(id, at: resolved) else { throw FileAccessError.needsReconnection(id) }
        try validateLegacyRoot(id, at: resolved)
        _ = try FileManager.default.contentsOfDirectory(at: resolved, includingPropertiesForKeys: nil)
        return resolved
    }
    public func records() -> [AccessRootRecord] { saved }
    public func launchOutcomes() -> [AccessRootID: String] { outcomes }
    /// Published location only; Recent queries never create or refresh authority.
    public func rootURL(_ id: AccessRootID) -> URL? { roots[id] }
    public func savedVolume(_ id: AccessRootID) -> AccessProbeVolume? {
        guard let bookmark = saved.first(where: { $0.id == id })?.bookmark else { return nil }
        return bookmarkVolume(bookmark)
    }
    /// Captures identity while the folder is readable. A later path alone never
    /// establishes that a replacement directory is the previously browsed folder.
    public func captureRecoveryFolder(rootID: AccessRootID, folder: URL) throws -> AccessFolderRecoveryReference? {
        let lease = try acquire(.root(rootID, file: folder))
        defer { release(lease) }
        let root = canonical(lease.url)
        var target = canonical(folder)
        guard boundary(target, root) else { throw FileAccessError.outsideRoot }
        target.removeAllCachedResourceValues()
        do {
            guard try target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  let rootIdentity = try recoveryResourceReader.identity(for: root),
                  let folderIdentity = try recoveryResourceReader.identity(for: target) else { return nil }
            return AccessFolderRecoveryReference(rootID: rootID,
                relativeComponents: Array(target.pathComponents.dropFirst(root.pathComponents.count)),
                folderURL: target,
                rootIdentity: rootIdentity, folderIdentity: folderIdentity)
        } catch where Self.isMissingRecoveryFolder(error) { return nil }
    }
    /// The caller has verified this root app-wide. This operation validates the
    /// individual window's saved folder under a fresh lease without guessing paths.
    public func resolveRecoveryFolder(_ reference: AccessFolderRecoveryReference,
                                      verifiedRoot: URL) throws -> AccessFolderRecoveryLocation? {
        let lease = try acquire(.root(reference.rootID, file: verifiedRoot))
        defer { release(lease) }
        let root = canonical(lease.url)
        guard root == canonical(verifiedRoot),
              (try recoveryResourceReader.identity(for: root)) == reference.rootIdentity else {
            throw FileAccessError.needsReconnection(reference.rootID)
        }
        var folder = canonical(reference.relativeComponents.reduce(root) { $0.appendingPathComponent($1) })
        guard boundary(folder, root) else { return nil }
        folder.removeAllCachedResourceValues()
        do {
            guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
                  (try recoveryResourceReader.identity(for: folder)) == reference.folderIdentity else { return nil }
            _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            guard (try recoveryResourceReader.identity(for: folder)) == reference.folderIdentity else { return nil }
            // The lease above proved the saved record exists; no await separates it from here.
            return savedGrantSnapshot(reference.rootID).map {
                AccessFolderRecoveryLocation(rootURL: root, folderURL: folder, grant: $0)
            }
        } catch where Self.isMissingRecoveryFolder(error) { return nil }
    }
    private static func isMissingRecoveryFolder(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)) || (error.domain == NSPOSIXErrorDomain && [Int(ENOENT), Int(ENOTDIR)].contains(error.code))
    }
    public func verifySavedRootForRecovery(_ id: AccessRootID,
                                           mounts: any DiskMountPort) async -> AccessRecoveryVerification {
        await verifySavedRootForRecovery(id, targetFolder: nil, mounts: mounts)
    }
    public func verifySavedRootForRecovery(_ id: AccessRootID, folder: URL,
                                           mounts: any DiskMountPort) async -> AccessRecoveryVerification {
        await verifySavedRootForRecovery(id, targetFolder: folder, mounts: mounts)
    }
    private func verifySavedRootForRecovery(_ id: AccessRootID, targetFolder: URL?,
                                            mounts: any DiskMountPort) async -> AccessRecoveryVerification {
        let rootID = id.rawValue.uuidString
        let attempt = UUID().uuidString
        let prefix = "AccessRecoveryVerify root=\(rootID) attempt=\(attempt)"
        var stage = "savedGrant"
        var location = targetFolder
        var outcome = "refused"
        diagnostics.emit("\(prefix) outcome=attempt", path: targetFolder)
        defer { diagnostics.emit("\(prefix) outcome=\(outcome) stage=\(stage)", path: location) }
        let empty = AccessProbeVolume(uuid: nil, url: nil, name: nil)
        // Mount enumeration suspends this actor. Read the saved grant afterwards
        // so an explicit reselection during that wait cannot be overwritten.
        let mounted = await mounts.mountedVolumes()
        guard let record = saved.first(where: { $0.id == id }) else {
            return AccessRecoveryVerification(classification: .init(cause: .unknown, isInTrash: false),
                                              bookmarkVolume: empty, rootURL: nil, folderURL: nil)
        }
        let volume = bookmarkVolume(record.bookmark)
        diagnostics.emit("\(prefix) volume=\(volume.uuid ?? "unknown")")
        func classified(_ resolution: AccessProbeResolution, scopeStarted: Bool? = nil,
                        listing: AccessProbeDirectoryListing? = nil, isInTrash: Bool = false,
                        rootURL: URL? = nil, folderURL: URL? = nil) -> AccessRecoveryVerification {
            let facts = AccessProbeFacts(volume: volume, mountedVolumes: mounted, resolution: resolution,
                                         scopeStarted: scopeStarted, listing: listing, isInTrash: isInTrash)
            let classification = AccessCauseClassifier.classify(facts)
            diagnostics.emit("\(prefix) cause=\(classification.cause.rawValue)")
            if classification.cause == .readable { outcome = "verified" }
            return AccessRecoveryVerification(classification: classification,
                                              bookmarkVolume: volume, rootURL: rootURL, folderURL: folderURL)
        }
        // A bookmark can resolve to an empty abandoned mount point. Never use
        // scope or listing to override a missing or wrong UUID. A volume that
        // has no UUID at all is only retried here (foreground), never by disk events.
        stage = "mount"
        if let uuid = volume.uuid, !mounted.contains(where: { $0.uuid == uuid }) {
            return classified(.failed(domain: "MadoAccess", code: 0))
        }
        stage = "bookmark"
        let resolution: ResolvedBookmark
        do { resolution = try bookmarks.resolve(record.bookmark) }
        catch {
            diagnostics.emit("\(prefix) bookmark=failed error=\(AccessDiagnostics.errorKind(error))")
            return classified(.failed(Self.probeError(error)))
        }
        let root = resolution.url
        location = root
        diagnostics.emit("\(prefix) bookmark=resolved stale=\(resolution.stale)", path: root)
        let resolved = AccessProbeResolution.resolved(root, stale: resolution.stale)
        stage = "volumeRead"
        let actualUUID: String?
        do { actualUUID = try resolvedVolumeUUID(root) }
        catch {
            diagnostics.emit("\(prefix) stage=volumeRead error=\(AccessDiagnostics.errorKind(error))", path: root)
            // The former try? adapter produced nil on read failure. Preserve its
            // comparison semantics, including UUID-less roots, while explaining it.
            actualUUID = nil
        }
        if actualUUID != volume.uuid {
            stage = "volumeMismatch"
            diagnostics.emit("\(prefix) stage=volumeMismatch expectedVolume=\(volume.uuid ?? "unknown") actualVolume=\(actualUUID ?? "unknown")", path: root)
            return classified(resolved, isInTrash: Self.isTrashed(root))
        }
        stage = "trash"
        guard !Self.isTrashed(root) else { return classified(resolved, isInTrash: true) }
        let sessionIdentity = recoveryBaseline[id]
        let expectedIdentity = sessionIdentity ?? bookmarkIdentity(record.bookmark) ?? legacyBaseline[id]
        stage = "identityMissing"
        guard expectedIdentity != nil || !requiresEmbeddedIdentity || volume.uuid == nil else {
            return classified(resolved)
        }
        stage = "scope"
        let session: ScopeSession
        do {
            session = try ScopeSession(scope: scope, url: root, rootID: id)
            diagnostics.emit("\(prefix) scopeStarted=true", path: root)
        } catch {
            diagnostics.emit("\(prefix) scopeStarted=false error=\(AccessDiagnostics.errorKind(error))", path: root)
            return classified(resolved, scopeStarted: false)
        }
        defer { session.stop() }
        if let expectedIdentity {
            let actualIdentity: FileResourceIdentity?
            stage = "identityRead"
            do { actualIdentity = try (sessionIdentity == nil ? resourceReader : recoveryResourceReader).identity(for: root) }
            catch {
                diagnostics.emit("\(prefix) stage=identityRead error=\(AccessDiagnostics.errorKind(error))", path: root)
                roots.removeValue(forKey: id)
                return classified(resolved, scopeStarted: true)
            }
            stage = actualIdentity == nil ? "identityMissing" : "identityMismatch"
            guard actualIdentity == expectedIdentity else {
                roots.removeValue(forKey: id)
                return classified(resolved, scopeStarted: true)
            }
            diagnostics.emit("\(prefix) identity=match", path: root)
        }
        stage = "rootRead"
        let rootListing: AccessProbeDirectoryListing
        do {
            rootListing = .succeeded(entryCount: try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil).count)
            diagnostics.emit("\(prefix) stage=rootRead outcome=readable", path: root)
        } catch {
            diagnostics.emit("\(prefix) stage=rootRead error=\(AccessDiagnostics.errorKind(error))", path: root)
            return classified(resolved, scopeStarted: true, listing: .failed(Self.probeError(error)))
        }
        let candidate: URL
        if let folder = targetFolder, let priorRoot = lastKnownRoots[id],
           folder.standardizedFileURL.pathComponents.starts(with: priorRoot.standardizedFileURL.pathComponents),
           priorRoot.standardizedFileURL != root.standardizedFileURL {
            let suffix = folder.standardizedFileURL.pathComponents.dropFirst(priorRoot.standardizedFileURL.pathComponents.count)
            candidate = suffix.reduce(root) { $0.appendingPathComponent($1) }
        } else { candidate = targetFolder ?? root }
        // Only a genuinely readable saved bookmark restores the published root.
        publishRoot(id, url: root)
        stage = "boundary"
        guard boundary(candidate, root) else {
            return classified(resolved, scopeStarted: true, rootURL: root)
        }
        if candidate.standardizedFileURL == root.standardizedFileURL {
            stage = "rootRead"
            return classified(resolved, scopeStarted: true, listing: rootListing,
                              rootURL: root, folderURL: root)
        }
        stage = "folderRead"
        location = candidate
        do {
            let listing = AccessProbeDirectoryListing.succeeded(entryCount: try FileManager.default.contentsOfDirectory(
                at: candidate, includingPropertiesForKeys: nil).count)
            return classified(resolved, scopeStarted: true, listing: listing,
                              rootURL: root, folderURL: candidate)
        } catch {
            diagnostics.emit("\(prefix) stage=folderRead error=\(AccessDiagnostics.errorKind(error))", path: candidate)
            return classified(resolved, scopeStarted: true,
                              listing: .failed(Self.probeError(error)), rootURL: root)
        }
    }
    private static func probeError(_ error: Error) -> AccessProbeError {
        let nsError = error as NSError
        let underlying = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError).map { probeError($0) }
        return AccessProbeError(domain: nsError.domain, code: nsError.code,
                                underlyingErrors: underlying.map { [$0] } ?? [])
    }
    private func publishRoot(_ id: AccessRootID, url: URL) {
        if let old = roots[id], old.standardizedFileURL != url.standardizedFileURL {
            var history = previousRoots[id] ?? []
            history.append(old)
            if history.count > 8 { history.removeFirst() }
            previousRoots[id] = history
        }
        roots[id] = url
        lastKnownRoots[id] = url
    }
    public func resolveFileGrant(_ file: URL) throws -> URL {
        let key = file.standardizedFileURL
        guard let bookmark = fileBookmarks[key] else { return file }
        // A new inode at the old name could be a replacement or reuse after rename.
        if FileManager.default.fileExists(atPath: file.path) {
            let current = try? resourceReader.identity(for: file)
            if bookmark.resource == nil || current == bookmark.resource { return file }
            do {
                let moved = try resolveFileBookmark(bookmark, original: file)
                if moved != file, FileManager.default.fileExists(atPath: moved.path) { return moved }
            } catch FileAccessError.fileDeleted(_) {
                // A trashed former inode yields to a live replacement at the granted path.
            }
            catch { /* Bookmark failure permits the replacement at the original path. */ }
            let session = try ScopeSession(scope: scope, url: file, rootID: nil)
            defer { session.stop() }
            guard FileManager.default.isReadableFile(atPath: file.path) else {
                throw FileAccessError.needsFileReconnection(file)
            }
            if let data = try? bookmarks.create(for: file) {
                fileBookmarks[key] = FileGrantBookmark(data: data, resource: current)
            }
            return file
        }
        return try resolveFileBookmark(bookmark, original: file)
    }
    private func resolveFileBookmark(_ bookmark: FileGrantBookmark, original: URL) throws -> URL {
        do {
            let resolved = try bookmarks.resolve(bookmark.data)
            if Self.isTrashed(resolved.url) { throw FileAccessError.fileDeleted(original) }
            if resolved.stale {
                let session = try ScopeSession(scope: scope, url: resolved.url, rootID: nil)
                defer { session.stop() }
                fileBookmarks[original.standardizedFileURL]?.data = try bookmarks.create(for: resolved.url)
            }
            return resolved.url
        } catch FileAccessError.fileDeleted(let file) { throw FileAccessError.fileDeleted(file) }
        catch { throw FileAccessError.needsFileReconnection(original) }
    }
    static func isTrashed(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let components = normalized.pathComponents
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false),
           components.starts(with: trash.standardizedFileURL.pathComponents) { return true }
        // Resource values are unavailable for a missing descendant. Its nearest
        // existing ancestor still establishes the actual mounted volume root.
        var ancestor = normalized
        var volume = try? ancestor.resourceValues(forKeys: [.volumeURLKey]).volume
        while volume == nil {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            ancestor = parent
            volume = try? ancestor.resourceValues(forKeys: [.volumeURLKey]).volume
        }
        guard let volume else { return false }
        return isInPerUserVolumeTrash(normalized, volume: volume)
    }
    static func isInPerUserVolumeTrash(_ url: URL, volume: URL, uid: uid_t = getuid()) -> Bool {
        let perUserTrash = volume.appendingPathComponent(".Trashes", isDirectory: true)
            .appendingPathComponent(String(uid), isDirectory: true)
        return url.standardizedFileURL.pathComponents.starts(with: perUserTrash.standardizedFileURL.pathComponents)
    }
    /// A point-in-time access check for Recent, balanced before any UI decision.
    public func probeRootURL(_ id: AccessRootID) throws -> URL {
        guard let record = saved.first(where: { $0.id == id }), roots[id] != nil else {
            throw FileAccessError.needsReconnection(id)
        }
        let current: URL
        do { current = try bookmarks.resolve(record.bookmark).url }
        catch { roots.removeValue(forKey: id); throw FileAccessError.needsReconnection(id) }
        // This is automatic admission (recent/foreground), even when an explicit
        // selection currently authorizes readers of this Trash directory.
        guard !Self.isTrashed(current) else { throw FileAccessError.needsReconnection(id) }
        // A cached path may be obsolete after a move. Probe the resolved root itself;
        // acquire still validates scope and refreshes stale bookmarks as usual.
        let lease = try acquire(.root(id, file: current))
        release(lease)
        return lease.url
    }
    public func relocatedFolder(_ folder: URL, rootID id: AccessRootID) throws -> URL? {
        var candidates = previousRoots[id] ?? []
        if let currentRoot = roots[id] { candidates.append(currentRoot) }
        var oldRoot: URL?
        for candidate in candidates {
            guard folder.standardizedFileURL.pathComponents.starts(with: candidate.standardizedFileURL.pathComponents) else { continue }
            if let current = oldRoot, current.pathComponents.count >= candidate.pathComponents.count { continue }
            oldRoot = candidate
        }
        guard let oldRoot else { return nil }
        let newRoot = try probeRootURL(id)
        guard newRoot.standardizedFileURL != oldRoot.standardizedFileURL else { return nil }
        let suffix = folder.standardizedFileURL.pathComponents.dropFirst(oldRoot.standardizedFileURL.pathComponents.count)
        var rebased = newRoot
        for component in suffix { rebased.appendPathComponent(component) }
        return rebased
    }
    /// Only an explicit system-panel selection may replace a persisted root.
    public func reconnect(_ id: AccessRootID, folder: URL) throws -> URL {
        let logger = Logger(subsystem: "io.github.anzchy.mado", category: "access")
        var phase = "scope"
        do {
            let session = try ScopeSession(scope: scope, url: folder, rootID: id)
            defer { session.stop() }
            phase = "directory"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FileAccessError.invalidFolder
            }
            phase = "collision"
            if let other = matchingRoot(canonical(folder), excluding: id) {
                throw FileAccessError.alreadyGranted(other)
            }
            phase = "bookmark"
            let bookmark = try bookmarks.create(for: folder)
            let previous = saved.first { $0.id == id }
            let record = AccessRootRecord(id: id, bookmark: bookmark, displayName: folder.lastPathComponent,
                creatingBuildSHA: previous?.creatingBuildSHA ?? buildSHA, createdAt: previous?.createdAt ?? Date())
            var replacement = saved.filter { $0.id != id }
            if let index = saved.firstIndex(where: { $0.id == id }) { replacement.insert(record, at: index) }
            else { replacement.append(record) }
            let selectedTrash = try explicitTrashEvidence(at: canonical(folder))
            phase = "store"
            invalidateSavedGrantVersion(id)
            try store.save(replacement)
            saved = replacement
            explicitTrashSelections[id] = selectedTrash
            legacyBaseline.removeValue(forKey: id)
            recoveryBaseline[id] = Self.trustedRecoveryIdentity(at: folder, expected: bookmarkIdentity(bookmark),
                rawReader: resourceReader, recoveryReader: recoveryResourceReader)
            publishRoot(id, url: folder)
            logger.notice("AccessReconnect root=\(id.rawValue.uuidString, privacy: .public) outcome=reconnected error=none path=\(folder.path, privacy: .private)")
            return folder
        } catch {
            logger.notice("AccessReconnect root=\(id.rawValue.uuidString, privacy: .public) outcome=failed error=\(phase, privacy: .public) path=\(folder.path, privacy: .private)")
            throw error
        }
    }
    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }
    /// Canonicalizing another root may inspect metadata: hold its own scope too.
    private func matchingRoot(_ folder: URL, excluding id: AccessRootID? = nil) -> AccessRootID? {
        for record in saved {
            guard record.id != id else { continue }
            guard let url = roots[record.id] else { continue }
            if url.standardizedFileURL.pathComponents == folder.pathComponents { return record.id }
            guard let session = try? ScopeSession(scope: scope, url: url, rootID: record.id) else { continue }
            defer { session.stop() }
            if canonical(url).pathComponents == folder.pathComponents { return record.id }
        }
        return nil
    }
    public func rootCovering(_ file: URL) -> AccessRootID? {
        // Unscoped path resolution cannot establish authority. Confirm each
        // candidate using the same balanced, scoped check as an actual lease.
        for record in saved {
            if let lease = try? acquire(.root(record.id, file: file)) {
                release(lease)
                return record.id
            }
        }
        return nil
    }
    /// The directory a single drop or open event names, as its canonical target;
    /// nil when it is not a directory. Reads metadata only: a delivered
    /// folder still becomes an Access Root through the system open panel alone.
    public func deliveredFolder(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        // No scope (#233): the sandbox lets a dropped link's target be stat'ed though the link is neither
        // readable nor startable (smoke507-20261107). FileManager follows the link without a trailing slash.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: canonical(url).path, isDirectory: true)
    }
    /// Only the composition root's successful system panel invokes this operation.
    public func grant(folder: URL, excludingRoot: AccessRootID? = nil) throws -> AccessRootID {
        let logger = Logger(subsystem: "io.github.anzchy.mado", category: "access")
        var id = AccessRootID()
        var existing = false
        var started = false
        var phase = "scope"
        do {
            let session = try ScopeSession(scope: scope, url: folder, rootID: id)
            started = true
            defer { session.stop() }
            phase = "directory"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw FileAccessError.invalidFolder
            }
            // Resolve only while the original user-selected URL's authority is held.
            // The bookmark must name the directory target, not the symlink inode.
            let target = canonical(folder)
            phase = "match"
            if let held = matchingRoot(target, excluding: excludingRoot) { id = held; existing = true }
            phase = "bookmark"
            let bookmark = try bookmarks.create(for: target)
            var replacement = saved
            if let index = replacement.firstIndex(where: { $0.id == id }) { replacement[index].bookmark = bookmark }
            else {
                replacement.append(AccessRootRecord(id: id, bookmark: bookmark, displayName: folder.lastPathComponent,
                    creatingBuildSHA: buildSHA, createdAt: Date()))
            }
            let selectedTrash = try explicitTrashEvidence(at: target)
            phase = "store"
            invalidateSavedGrantVersion(id)
            try store.save(replacement)
            saved = replacement
            explicitTrashSelections[id] = selectedTrash
            legacyBaseline.removeValue(forKey: id)
            recoveryBaseline[id] = Self.trustedRecoveryIdentity(at: target, expected: bookmarkIdentity(bookmark),
                rawReader: resourceReader, recoveryReader: recoveryResourceReader)
            publishRoot(id, url: folder)
            logger.notice("AccessGrant kind=panelFolder scopeStarted=true root=\(id.rawValue.uuidString, privacy: .public) existing=\(existing, privacy: .public) outcome=granted path=\(folder.path, privacy: .private)")
            return id
        } catch {
            logger.notice("AccessGrant kind=panelFolder scopeStarted=\(started, privacy: .public) root=\(id.rawValue.uuidString, privacy: .public) existing=\(existing, privacy: .public) outcome=failed error=\(phase, privacy: .public) path=\(folder.path, privacy: .private)")
            throw error
        }
    }
    public func acquire(_ request: AccessRequest) throws -> AccessLease {
        let key: SessionKey
        let url: URL
        let rootID: AccessRootID?
        var staleRecord: AccessRootRecord?
        switch request {
        case .root(let id, let file):
            guard let record = saved.first(where: { $0.id == id }), roots[id] != nil else {
                throw FileAccessError.needsReconnection(id)
            }
            rootID = id
            do {
                // Resolution may follow a move even while older leases are held.
                let resolution = try bookmarks.resolve(record.bookmark)
                guard !Self.isTrashed(resolution.url) || permitsExplicitTrash(id, at: resolution.url) else { throw FileAccessError.needsReconnection(id) }
                key = .root(id, resolution.url)
                url = active[key]?.session.url ?? resolution.url
                if resolution.stale && legacyBaseline[id] == nil { staleRecord = record }
            }
            catch { roots.removeValue(forKey: id); throw FileAccessError.needsReconnection(id) }
            // A readable ancestor must not authorize automatic content reads in
            // its actual Trash descendant, including through a symlink alias.
            guard !Self.isTrashed(file) || (permitsExplicitTrash(id, at: url) && boundary(canonical(file), canonical(url))) else { throw FileAccessError.outsideRoot }
            if active[key] != nil, !boundary(file, url) { throw FileAccessError.outsideRoot }
        case .fileGrant(let file):
            url = try resolveFileGrant(file)
            key = .file(file.standardizedFileURL, url.standardizedFileURL); rootID = nil
        }
        let lease = AccessLease(url: url, rootID: rootID, resolvedFileURL: rootID == nil ? url : nil)
        if var entry = active[key] {
            if let rootID { try validateLegacyRoot(rootID, at: url) }
            if let record = staleRecord, roots[record.id] != url {
                do { try refreshBookmark(record, for: url) }
                catch {
                    roots.removeValue(forKey: record.id)
                    throw FileAccessError.needsReconnection(record.id)
                }
            }
            entry.tokens.insert(lease.token); active[key] = entry
        } else {
            let session: ScopeSession
            do { session = try ScopeSession(scope: scope, url: url, rootID: rootID) }
            catch {
                if case .fileGrant(let file) = request, fileBookmarks[file.standardizedFileURL] != nil {
                    throw FileAccessError.needsFileReconnection(file)
                }
                throw error
            }
            if let rootID {
                do { try validateLegacyRoot(rootID, at: url) }
                catch { session.stop(); throw error }
            }
            if case .root(_, let file) = request, !boundary(file, url) {
                session.stop()
                throw FileAccessError.outsideRoot
            }
            if let record = staleRecord {
                do { try refreshBookmark(record, for: url) }
                catch {
                    session.stop()
                    roots.removeValue(forKey: record.id)
                    throw FileAccessError.needsReconnection(record.id)
                }
            }
            active[key] = Active(session: session, tokens: [lease.token])
            if case .fileGrant(let file) = request, FileManager.default.fileExists(atPath: url.path),
               fileBookmarks[file.standardizedFileURL] == nil {
                do {
                    let data = try bookmarks.create(for: url)
                    fileBookmarks[file.standardizedFileURL] = FileGrantBookmark(data: data,
                        resource: try? resourceReader.identity(for: url))
                } catch {
                    diagnostics.emit("FileGrantBookmark stage=create outcome=failed kind=\(AccessDiagnostics.errorKind(error))")
                }
            }
        }
        if let rootID { publishRoot(rootID, url: url) }
        requests[lease.token] = key
        return lease
    }
    /// The caller holds either a newly started or an existing live session scope.
    private func validateLegacyRoot(_ id: AccessRootID, at url: URL) throws {
        if let selected = explicitTrashSelections[id] {
            guard canonical(url) == selected.url,
                  (try? recoveryResourceReader.identity(for: url)) == selected.identity else {
                roots.removeValue(forKey: id)
                throw FileAccessError.needsReconnection(id)
            }
        }
        if let expected = recoveryBaseline[id] {
            guard (try? recoveryResourceReader.identity(for: url)) == expected else {
                roots.removeValue(forKey: id)
                throw FileAccessError.needsReconnection(id)
            }
            return
        }
        guard let expected = legacyBaseline[id] else { return }
        guard (try? resourceReader.identity(for: url)) == expected else {
            roots.removeValue(forKey: id)
            throw FileAccessError.needsReconnection(id)
        }
    }
    /// The caller holds either a newly started or an existing live session scope.
    private func refreshBookmark(_ record: AccessRootRecord, for url: URL) throws {
        let volume = bookmarkVolume(record.bookmark)
        if let uuid = volume.uuid {
            guard mountedVolumesProvider().contains(where: { $0.uuid == uuid }),
                  (try? resolvedVolumeUUID(url)) == uuid,
                  let expected = recoveryBaseline[record.id] ?? bookmarkIdentity(record.bookmark),
                  (try? (recoveryBaseline[record.id] == nil ? resourceReader : recoveryResourceReader).identity(for: url)) == expected else {
                throw FileAccessError.needsReconnection(record.id)
            }
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        } else if requiresEmbeddedIdentity {
            // No volume UUID: no mount to match, but the root must still sit on a
            // UUID-less volume, match any known identity, and really list.
            guard (try? resolvedVolumeUUID(url)) == nil else { throw FileAccessError.needsReconnection(record.id) }
            if let expected = bookmarkIdentity(record.bookmark),
               (try? resourceReader.identity(for: url)) != expected {
                throw FileAccessError.needsReconnection(record.id)
            }
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        }
        var replacement = record
        replacement.bookmark = try bookmarks.create(for: url)
        let refreshed = saved.map { $0.id == record.id ? replacement : $0 }
        invalidateSavedGrantVersion(record.id)
        try store.save(refreshed)
        saved = refreshed
    }
    public func release(_ lease: AccessLease) {
        guard let key = requests.removeValue(forKey: lease.token), var entry = active[key] else { return }
        entry.tokens.remove(lease.token)
        if entry.tokens.isEmpty {
            entry.session.stop(); active.removeValue(forKey: key)
        } else { active[key] = entry }
    }
}
