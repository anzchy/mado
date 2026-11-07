import Foundation
import PicseeCore
import PicseeApplication
import PicseeInfrastructure

struct AccessServices: Sendable {
    let files: FileAccess
    let monitor: AccessMonitor
    let recent: RecentFolderStore
    let lister = SiblingLister()
    let browser: FolderBrowser
    /// One watch per Access Root, shared by every window's folder scan.
    let watch: any FolderWatching
    private let selectionScope: any SecurityScope
    init(buildSHA: String) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Mado")
        let system = SystemSecurityScope()
        selectionScope = system
        files = try FileAccess(scope: system, bookmarks: system,
            store: BookmarkStore(url: support.appendingPathComponent("access-roots.json")), buildSHA: buildSHA)
        monitor = AccessMonitor(files: files)
        recent = RecentFolderStore(url: support.appendingPathComponent("recent-folders.json"))
        browser = FolderBrowser()
        watch = WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler())
    }
    init(files: FileAccess, recent: RecentFolderStore, browser: FolderBrowser, watch: any FolderWatching,
         mounts: (any DiskMountPort)? = nil, selectionScope: any SecurityScope = SystemSecurityScope()) {
        self.files = files
        self.selectionScope = selectionScope
        self.monitor = AccessMonitor(files: files, mounts: mounts)
        self.recent = recent
        self.browser = browser
        self.watch = watch
    }
    #if DEBUG && PICSEE_UI_TEST_FIXTURE
    init(buildSHA: String, fixtureRoot: URL) throws {
        let support = fixtureRoot.appendingPathComponent(".test-access", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let adapter = UITestContainerAccess(root: fixtureRoot)
        selectionScope = adapter
        files = try FileAccess(scope: adapter, bookmarks: adapter,
            store: BookmarkStore(url: support.appendingPathComponent("access-roots.json")), buildSHA: buildSHA)
        monitor = AccessMonitor(files: files)
        recent = RecentFolderStore(url: support.appendingPathComponent("recent-folders.json"))
        browser = FolderBrowser()
        watch = WatchHub(access: files, source: FSEventSource(), scheduler: DispatchWatchScheduler())
    }
    #endif
    func grant(_ folder: URL) async throws -> AccessRootID {
        // Retain the native selection's authority through canonical recent-folder
        // recording; a resolved path alone must not establish access.
        let started = selectionScope.start(folder)
        defer { if started { selectionScope.stop(folder) } }
        let id = try await files.grant(folder: folder)
        await monitor.reauthorize(id, explicitSelection: true)
        let target = folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        try await recent.add(RecentFolder(rootID: id, url: target, displayName: target.lastPathComponent, recordedRoot: target))
        return id
    }
    func images(in folder: URL, rootID: AccessRootID) async throws -> [URL] {
        try await files.withLease(.root(rootID, file: folder)) { lease in
            try await lister.images(in: folder, root: lease.url)
        }
    }
    // Untested native composition; FileAccess and Recent persistence are package-tested.
    func rootURL(_ id: AccessRootID) async -> URL? { await files.rootURL(id) }
    func probeRootURL(_ id: AccessRootID) async throws -> URL { try await files.probeRootURL(id) }
    func reconnect(_ id: AccessRootID, folder: URL) async throws -> (rootID: AccessRootID, url: URL) {
        let targetID: AccessRootID
        let url: URL
        do { url = try await files.reconnect(id, folder: folder); targetID = id }
        catch FileAccessError.alreadyGranted(let other) {
            guard let held = await files.rootURL(other) else { throw FileAccessError.needsReconnection(other) }
            targetID = other; url = held
        }
        await monitor.reauthorize(targetID, explicitSelection: true)
        try await recent.add(RecentFolder(rootID: targetID, url: url, displayName: url.lastPathComponent, recordedRoot: url))
        return (targetID, url)
    }
    /// A fresh panel selection refers to this URL, never an older File Grant's
    /// tracked bookmark. Hold its scope through identity proof and persistent grant.
    func reselect(_ id: AccessRootID, folder: URL, reference: AccessFolderRecoveryReference?) async throws
        -> (rootID: AccessRootID, url: URL, restored: Bool) {
        let task = Task.detached { [self] in
            try Task.checkCancellation()
            guard selectionScope.start(folder) else { throw FileAccessError.startFailed }
            defer { selectionScope.stop(folder) }
            _ = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            let matches: Bool
            if let reference, reference.rootID == id {
                matches = try URLRecoveryIdentityResourceReader().identity(for: folder) == reference.rootIdentity
            } else {
                let saved = await files.savedGrantSnapshot(id)
                if let expected = saved.flatMap({ AccessProbeFactGatherer.bookmarkIdentity(in: $0.record.bookmark) }) {
                    matches = try URLIdentityResourceReader().identity(for: folder) == expected
                } else { matches = false }
            }
            try Task.checkCancellation()
            if matches {
                let target = try await reconnect(id, folder: folder)
                return (rootID: target.rootID, url: target.url, restored: target.rootID == id)
            }
            let selected = try await files.grant(folder: folder, excludingRoot: id)
            await monitor.reauthorize(selected, explicitSelection: true)
            try await recent.add(RecentFolder(rootID: selected, url: folder, displayName: folder.lastPathComponent, recordedRoot: folder))
            return (rootID: selected, url: folder, restored: false)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

}
