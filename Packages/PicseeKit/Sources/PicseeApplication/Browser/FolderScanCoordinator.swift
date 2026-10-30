import Foundation
import Observation
import PicseeCore

public enum MetadataSortState: Sendable, Equatable { case idle, pending, incomplete, complete }

struct FolderScanRestorePoint {
    let source: FolderSnapshot
    let conditions: FolderViewConditions
    let loopEnabled: Bool
    let recursiveEnabled: Bool
    let inputURL: URL?
    let currentItemID: ItemID?
    let currentURL: URL?
    let canPresent: (@MainActor () -> Bool)?
    let folder: URL?
}

/// A failed folder-entry read its Retry can return to: Cancel Reading during the Retry restores it (#238).
struct FolderScanFailedRead {
    let error: any Error
    let folder: URL
    let rootID: AccessRootID
    let conditions: FolderViewConditions
    let loopEnabled: Bool
    let recursiveEnabled: Bool
    let canPresent: @MainActor () -> Bool
}

@MainActor private final class RefreshBuffer { var entries: [FolderEntry] = [] }
/// One scan owner per window. The scanning task retains its lease until enumeration really exits.
@MainActor @Observable public final class FolderScanCoordinator {
    public private(set) var snapshot: FolderSnapshot?
    public private(set) var sourceSnapshot: FolderSnapshot?
    @ObservationIgnored public var onReadFailure: (@MainActor (AccessRootID, URL) -> Void)?
    /// Asked once per failed read before it is published: true when the Access Root itself is lost (page 26, #238).
    @ObservationIgnored public var rootLossCheck: (@MainActor (AccessRootID, any Error) async -> Bool)?
    public private(set) var conditions = FolderViewConditions()
    // Keep the filter's folder identity across end() during single-image admission.
    private var conditionsFolder: URL?
    public var isMetadataSortPending: Bool {
        guard sourceSnapshot != nil, conditions.sort == .captureDate || conditions.sort == .pixelDimensions else { return false }
        return activeGeneration != nil || refreshTask != nil || !pendingMetadataIDs.isEmpty
    }
    public var metadataSortState: MetadataSortState {
        guard sourceSnapshot != nil, conditions.sort == .captureDate || conditions.sort == .pixelDimensions else { return .idle }
        if isMetadataSortPending { return .pending }
        return metadataUnknownItemIDs.isEmpty ? .complete : .incomplete
    }
    public private(set) var metadataUnknownItemIDs: Set<ItemID> = []
    public private(set) var loopEnabled = false
    public private(set) var recursiveEnabled = false
    /// A filtered empty projection is final only after enumeration, or while its prior result remains shown during refresh.
    public var hasNoMatches: Bool {
        sourceSnapshot?.isComplete == true && (refreshTask == nil || noMatchesPresented)
            && sourceSnapshot?.entries.isEmpty == false && snapshot?.entries.isEmpty == true
    }
    /// A complete, failure-free source with no supported images; a refresh in flight keeps the shown value.
    public var isEmptyFolder: Bool {
        failure == nil && !isReadingFolder && sourceSnapshot?.isComplete == true && sourceSnapshot?.entries.isEmpty == true
    }
    public var isAwaitingFilteredMatch: Bool {
        guard failure == nil, !isReadingFolder, !hasNoMatches, conditions.selectedExtensions != nil,
              snapshot?.entries.isEmpty == true,
              sourceSnapshot?.isComplete == false ||
                  (refreshTask != nil && sourceSnapshot?.entries.isEmpty == false) else { return false }
        guard let currentURL else { return true }
        return !conditions.includesExtension(currentURL.pathExtension)
    }
    public var availableExtensions: [String] {
        Array(Set(sourceSnapshot?.entries.map(\.normalizedExtension) ?? [])).sorted()
    }
    public func preservesPresentationAuthorityForRetry(_ url: URL, accessRequest: AccessRequest?) -> Bool {
        guard case .root(let requestRoot, let file)? = accessRequest,
              let rootID = activeFolder?.rootID ?? sourceSnapshot?.version.rootID,
              requestRoot == rootID,
              file.standardizedFileURL == url.standardizedFileURL,
              inputURL?.standardizedFileURL == url.standardizedFileURL,
              currentURL?.standardizedFileURL == url.standardizedFileURL,
              automaticPresentationAllowed?() != false else { return false }
        return true
    }
    public func setConditions(_ value: FolderViewConditions) {
        if conditions.sort != value.sort { invalidateMetadata() }
        conditions = value
        projectSource()
        enqueueMetadata()
    }
    /// Accepts a same-version source update, including removals from a future watcher.
    func replaceSourceSnapshot(_ next: FolderSnapshot, added: [FolderEntry]? = nil) {
        guard sourceSnapshot?.version == next.version else { return }
        sourceSnapshot = next
        projectSource()
        enqueueMetadata(candidates: added)
    }
    public func setLoopEnabled(_ value: Bool) { loopEnabled = value }
    /// `rereadingFolder` rescans as a folder open (Reading State, first entry on completion) instead of keeping the shown image.
    @discardableResult public func setRecursiveEnabled(_ value: Bool, rereadingFolder: Bool = false) -> Task<Void, any Error>? {
        guard recursiveEnabled != value else { return nil }
        recursiveEnabled = value
        guard let folder = activeFolder ?? sourceSnapshot.map({ ($0.version.folder, $0.version.rootID) }),
            let canPresent = automaticPresentationAllowed else { return nil }
        let shown = rereadingFolder ? nil : currentURL
        let staysInFlatFolder = shown?.deletingLastPathComponent().standardizedFileURL == folder.url.standardizedFileURL
        let retainedInput = value || staysInFlatFolder ? shown : nil
        if !value && shown != nil && !staysInFlatFolder { excludedPresentationNeedsReconciliation = true }
        return start(folder: folder.url, rootID: folder.rootID, input: retainedInput,
            canPresent: canPresent, preserveConditions: true)
    }
    public private(set) var generation: UInt64 = 0
    public var isScanning: Bool { activeGeneration != nil }
    public private(set) var isReadingFolder = false
    /// The folder is shown but not watched: the watch subscription failed (lease or stream).
    public private(set) var isWatchUnavailable = false
    public private(set) var failure: (any Error)?
    public var completedImageCount: Int? {
        guard failure == nil, sourceSnapshot?.isComplete == true else { return nil }
        return sourceSnapshot?.navigationEntries.count
    }
    public var failureReason: String? {
        guard let failure else { return nil }
        if failure is FolderScanLimitError { return "Scan limit reached" }
        if failure is FileAccessError { return "Folder access denied" }
        let error = failure as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return "Folder access denied" }
        if error.domain == NSPOSIXErrorDomain {
            if error.code == Int(POSIXError.Code.EACCES.rawValue) { return "Folder access denied" }
            if error.code == Int(POSIXError.Code.EPERM.rawValue) { return "Folder access denied" }
        }
        return "Folder scan failed"
    }
    /// The folder a failed read was reading, by display name (24F-A heading).
    public var failedFolderName: String { (activeFolder?.url ?? sourceFolder)?.lastPathComponent ?? "" }
    @discardableResult public func retry() -> Task<Void, any Error>? {
        // A failed refresh has no active folder; it rescans the complete source's folder.
        guard let error = failure, let folder = activeFolder ?? sourceSnapshot.map({ ($0.version.folder, $0.version.rootID) }),
              let canPresent = automaticPresentationAllowed else { return nil }
        // The image the user moved to after the failure, not the one the failed scan began with.
        let input = currentURL ?? inputURL
        // Only a folder entry returns to 「读取失败」; an image-first Retry keeps the viewing surface.
        let point = input == nil ? FolderScanFailedRead(error: error, folder: folder.url, rootID: folder.rootID,
            conditions: conditions, loopEnabled: loopEnabled, recursiveEnabled: recursiveEnabled, canPresent: canPresent) : nil
        let task = start(folder: folder.url, rootID: folder.rootID, input: input,
            canPresent: canPresent, preserveConditions: true)
        failedRead = point
        return task
    }
    private var failedRead: FolderScanFailedRead?
    public private(set) var inputURL: URL?
    public internal(set) var currentItemID: ItemID?
    public internal(set) var currentURL: URL?
    public weak var host: (any FolderScanHost)?
    var pendingDirection: NavigationDirection?
    var automaticPresentationAllowed: (@MainActor () -> Bool)?
    private let access: any AccessLeasing
    private let scanner: any FolderScanning
    private let metadataReader: (any FolderMetadataReading)?
    private var metadata: [ItemID: FolderImageMetadata] = [:]
    private var metadataEntries: [ItemID: FolderEntry] = [:]
    private var metadataQueue: [FolderEntry] = []
    private var metadataQueueIndex = 0
    private var metadataSinceProjection = 0
    private(set) var metadataProjectionCount = 0
    private var pendingMetadataIDs: Set<ItemID> = []
    private var metadataTask: Task<Void, Never>?
    private var metadataDrain: Task<Void, Never>?
    private var metadataRevision: UInt64 = 0
    private let trace: (any FolderScanTracing)?
    private let watcher: (any FolderWatching)?
    private var firstBatchTraced = false
    private var noMatchesPresented = false
    var presentationRevision: UInt64 = 0
    private var scanTask: Task<Void, any Error>?
    private var activeGeneration: UInt64?
    private var activeFolder: (url: URL, rootID: AccessRootID)?
    private var excludedPresentationNeedsReconciliation = false
    private var sourceFolder: URL?
    @ObservationIgnored private var watch: (any FolderWatchSubscription)?
    @ObservationIgnored private var retiredWatches: [any FolderWatchSubscription] = []
    private var watchToken: UInt64 = 0
    private var watchRequested = false
    private var refreshPending = false
    private var refreshFailed = false
    private var refreshTask: Task<Void, any Error>?
    public convenience init(access: any AccessLeasing, scanner: any FolderScanning, trace: (any FolderScanTracing)? = nil,
        watcher: (any FolderWatching)? = nil) {
        self.init(access: access, scanner: scanner, trace: trace, metadataReader: nil, watcher: watcher)
    }
    public convenience init(access: any AccessLeasing, scanner: any FolderScanning,
                            metadataReader: any FolderMetadataReading) {
        self.init(access: access, scanner: scanner, trace: nil, metadataReader: metadataReader, watcher: nil)
    }
    public init(access: any AccessLeasing, scanner: any FolderScanning, trace: (any FolderScanTracing)?,
                metadataReader: (any FolderMetadataReading)?, watcher: (any FolderWatching)? = nil) {
        self.access = access; self.scanner = scanner; self.trace = trace
        self.metadataReader = metadataReader; self.watcher = watcher
    }
    /// A coordinator released without end() still cancels the watch it holds.
    deinit {
        let held = retiredWatches + (watch.map { [$0] } ?? [])
        if !held.isEmpty { Task { for subscription in held { await subscription.cancel() } } }
    }
    /// Silent rescan of the complete source: no Reading State and no host start; nil when there is none.
    /// A failure shows the folder scan failure and keeps the snapshot and the watch; a Current Item whose file is
    /// gone is cleared rather than kept on screen. The next successful refresh clears the failure.
    @discardableResult public func refresh() -> Task<Void, any Error>? {
        guard let source = sourceSnapshot, source.isComplete, activeGeneration == nil, failure == nil || refreshFailed,
              let folder = sourceFolder else { return nil }
        refreshPending = false
        refreshTask?.cancel()
        cancelMetadataWork()
        generation &+= 1
        let token = generation, rootID = source.version.rootID, buffer = RefreshBuffer()
        let options = FolderScanOptions(recursive: recursiveEnabled)
        trace?.begin(generation: token, folderURL: folder)
        let task = Task { [self] in
            do {
                var scannedFolder = folder
                do {
                    try await Self.scanLeased(folder: folder, rootID: rootID, generation: token, input: nil, options: options,
                        access: access, scanner: scanner, ready: { _, _ in }, emit: { buffer.entries += $0 })
                } catch {
                    guard let relocated = try? await access.relocatedFolder(folder, rootID: rootID),
                          relocated.standardizedFileURL != folder.standardizedFileURL else { throw error }
                    buffer.entries.removeAll()
                    scannedFolder = relocated
                    try await Self.scanLeased(folder: relocated, rootID: rootID, generation: token, input: nil, options: options,
                        access: access, scanner: scanner, ready: { _, _ in }, emit: { buffer.entries += $0 })
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                refreshTask = nil
                let fresh = FolderSnapshot(version: .init(rootID: rootID, folder: scannedFolder, generation: token),
                    entries: buffer.entries, isComplete: true)
                if scannedFolder != folder {
                    sourceFolder = scannedFolder
                    retireWatch(successor: true)
                    let watchToken = requestWatch()
                    await subscribeWatch(scannedFolder, rootID: rootID, recursive: recursiveEnabled, token: watchToken)
                }
                trace?.complete(count: fresh.navigationEntries.count, generation: token)
                trace?.end(outcome: .complete, generation: token)
                if refreshFailed {
                    failure = nil; refreshFailed = false
                    host?.folderScanDidComplete(count: fresh.navigationEntries.count)
                }
                if fresh.entries == sourceSnapshot?.entries &&
                    fresh.version.folder.standardizedFileURL.pathComponents == sourceSnapshot?.version.folder.standardizedFileURL.pathComponents {
                    projectSource()
                    enqueueMetadata()
                } else {
                    applyRefresh(fresh)
                }
            } catch {
                let shown = currentURL
                var gone = false
                if let shown { gone = await Self.isGone(shown, rootID: rootID, access: access) }
                guard generation == token, !Task.isCancelled, !(error is CancellationError) else {
                    trace?.end(outcome: .cancelled, generation: token); return
                }
                if let rootLossCheck {
                    let lost = await rootLossCheck(rootID, error)
                    guard generation == token, !Task.isCancelled else {
                        trace?.end(outcome: .cancelled, generation: token); return
                    }
                    if lost {
                        // Page 26 takes the window; the source stays for its restore position.
                        refreshTask = nil
                        trace?.failure(error, generation: token); trace?.end(outcome: .failed, generation: token)
                        host?.folderScanDidEnd()
                        throw error
                    }
                }
                refreshTask = nil
                trace?.failure(error, generation: token); trace?.end(outcome: .failed, generation: token)
                failure = error; refreshFailed = true
                if gone, currentURL == shown {
                    currentItemID = nil; currentURL = nil; inputURL = nil
                    presentationRevision &+= 1
                    if automaticPresentationAllowed?() != false { host?.clearFolderImageForNoMatches() }
                }
                host?.folderScanDidEnd()
                enqueueMetadata()
                if refreshPending { refresh() }
                throw error
            }
            if refreshPending { refresh() }
        }
        refreshTask = task
        return task
    }
    /// Foreground fallback for a failed watch: subscribes again, then rescans silently; a live watch is the hub's to reconcile.
    @discardableResult public func reconcileUnwatched() -> Task<Void, any Error>? {
        guard isWatchUnavailable, !watchRequested, activeGeneration == nil, let folder = sourceFolder,
              let source = sourceSnapshot, source.isComplete else { return nil }
        let token = requestWatch(), rootID = source.version.rootID, recursive = recursiveEnabled
        return Task { [self] in
            await subscribeWatch(folder, rootID: rootID, recursive: recursive, token: token)
            guard watchToken == token else { return }
            try await refresh()?.value
        }
    }
    /// Keeps the Current Item, else moves to its successor (then predecessor) in the previous navigation order.
    private func applyRefresh(_ fresh: FolderSnapshot) {
        let previous = snapshot?.navigationEntries
        let previousCurrent = sourceSnapshot?.entries.first(where: {
            $0.itemID == currentItemID && $0.url.standardizedFileURL == currentURL?.standardizedFileURL
        })
        // Conditions may have started reads against the old source while the refresh was scanning.
        if sourceSnapshot?.version != fresh.version { cancelMetadataWork() }
        retainMetadata(matching: fresh)
        sourceSnapshot = fresh
        let snapshot = fresh.applying(conditions, metadata: metadata)
        self.snapshot = snapshot
        enqueueMetadata()
        guard let id = currentItemID else { projectSource(); return }
        let target: FolderEntry?
        if let index = snapshot.navigationIndex(for: id) {
            if let previousCurrent, snapshot.entries.contains(where: {
                $0 == previousCurrent && $0.itemID == id && $0.url.standardizedFileURL == currentURL?.standardizedFileURL
            }) { return }
            target = snapshot.navigationEntries[index]
        } else {
            if let previous, let old = previous.firstIndex(where: { $0.itemID == id }) {
                target = (Array(previous[(old + 1)...]) + previous[..<old].reversed()).lazy
                    .compactMap { snapshot.navigationIndex(for: $0.itemID) }.first.map { snapshot.navigationEntries[$0] }
            } else {
                target = snapshot.navigationEntries.first
            }
        }
        let allowed = automaticPresentationAllowed?() != false
        if target != nil { noMatchesPresented = false }
        if target == nil && hasNoMatches && allowed { presentNoMatchesIfNeeded(); return }
        presentationRevision &+= 1
        currentItemID = target?.itemID; currentURL = target?.url
        guard let target else { inputURL = nil; if allowed { host?.clearFolderImageForNoMatches() }; return }
        if allowed { host?.openFolderImage(target.url, rootID: snapshot.version.rootID) }
    }
    /// A replaced subscription is cancelled only once its successor exists, so a shared stream never restarts.
    private func requestWatch() -> UInt64 { watchToken &+= 1; watchRequested = watcher != nil; return watchToken }
    private func subscribeWatch(_ folder: URL, rootID: AccessRootID, recursive: Bool, token: UInt64) async {
        guard let watcher, watchToken == token else { return }
        let subscription = try? await watcher.subscribe(rootID: rootID, folder: folder,
            recursive: recursive) { [weak self] in
            Task { @MainActor [weak self] in self?.watchDidChange(token) }
        }
        if watchToken == token { watch = subscription; watchRequested = false; isWatchUnavailable = subscription == nil }
        else if let subscription { retiredWatches.append(subscription) }
        releaseRetiredWatches()
    }
    /// Cancels at once, unless a `successor` subscription is about to be requested (it releases the old one).
    private func retireWatch(successor: Bool) {
        guard watcher != nil else { return }
        if let watch { retiredWatches.append(watch) }
        watch = nil; watchToken &+= 1; watchRequested = successor; isWatchUnavailable = false
        releaseRetiredWatches()
    }
    private func releaseRetiredWatches() {
        guard !watchRequested, !retiredWatches.isEmpty else { return }
        let retired = retiredWatches; retiredWatches = []
        Task { for subscription in retired { await subscription.cancel() } }
    }
    private func watchDidChange(_ token: UInt64) {
        guard token == watchToken else { return }
        if activeGeneration != nil || refreshTask != nil { refreshPending = true } else { refresh() }
    }
    @discardableResult public func begin(folder: URL, rootID: AccessRootID, input: URL? = nil,
        pending: NavigationDirection? = nil, canPresent: @escaping @MainActor () -> Bool = { true }) -> Task<Void, any Error> {
        start(folder: folder, rootID: rootID, input: input, pending: pending, canPresent: canPresent,
            preserveConditions: false)
    }
    @discardableResult private func start(folder: URL, rootID: AccessRootID, input: URL? = nil,
        pending: NavigationDirection? = nil, canPresent: @escaping @MainActor () -> Bool,
        preserveConditions: Bool) -> Task<Void, any Error> {
        let previousConditions = conditions
        // A resolved path treats a directory and a symlink to it as the same folder.
        let previousFolder = activeFolder?.url ?? sourceSnapshot?.version.folder ?? conditionsFolder
        let sameFolder = previousFolder?.resolvingSymlinksInPath().standardizedFileURL ==
            folder.resolvingSymlinksInPath().standardizedFileURL
        stop(.replaced, successor: true)
        if !preserveConditions { excludedPresentationNeedsReconciliation = false }
        conditions = FolderViewConditions(sort: previousConditions.sort, direction: previousConditions.direction,
            selectedExtensions: preserveConditions || sameFolder ? previousConditions.selectedExtensions : nil)
        conditionsFolder = folder
        generation &+= 1
        let token = generation
        activeGeneration = token
        activeFolder = (folder.standardizedFileURL, rootID)
        inputURL = input
        currentURL = input
        pendingDirection = pending
        automaticPresentationAllowed = canPresent
        isReadingFolder = input == nil
        firstBatchTraced = false
        sourceFolder = folder
        let watchToken = requestWatch()
        trace?.begin(generation: token, folderURL: folder)
        let task = Task { [self] in
            await subscribeWatch(folder, rootID: rootID, recursive: recursiveEnabled, token: watchToken)
            do {
                try await Self.scanLeased(folder: folder, rootID: rootID, generation: token, input: input,
                    options: FolderScanOptions(recursive: recursiveEnabled),
                    access: access, scanner: scanner, ready: { [self] version, itemID in
                        guard activeGeneration == token, !Task.isCancelled else { return }
                        sourceSnapshot = FolderSnapshot(version: version, entries: [], isComplete: false)
                        snapshot = sourceSnapshot?.applying(conditions)
                        currentItemID = itemID
                    }, emit: { [self] batch in
                        guard activeGeneration == token, !Task.isCancelled, retainReadingAuthority(), let sourceSnapshot else { return }
                        replaceSourceSnapshot(sourceSnapshot.appending(batch, isComplete: false), added: batch)
                        if !batch.isEmpty, !firstBatchTraced {
                            firstBatchTraced = true
                            trace?.firstBatch(count: batch.count, generation: token)
                        }
                        advancePending()
                    })
                try Task.checkCancellation()
                guard activeGeneration == token, retainReadingAuthority(), let completed = sourceSnapshot else { return }
                sourceSnapshot = completed.appending([], isComplete: true)
                projectSource()
                let first = input == nil ? snapshot?.entries.first : nil
                pendingDirection = nil
                isReadingFolder = false
                scanTask = nil
                presentNoMatchesIfNeeded()
                if excludedPresentationNeedsReconciliation, !hasNoMatches,
                   snapshot?.navigationEntries.isEmpty == true {
                    currentItemID = nil; currentURL = nil; inputURL = nil
                    presentationRevision &+= 1
                    excludedPresentationNeedsReconciliation = false
                    host?.clearFolderImageForNoMatches()
                }
                if let first, automaticPresentationAllowed?() != false {
                    currentItemID = first.itemID; currentURL = first.url
                    let initialPresentationRevision = presentationRevision
                    try await host?.rememberFolder(folder, rootID: rootID)
                    guard activeGeneration == token else { return }
                    guard automaticPresentationAllowed?() != false else {
                        stop(.replaced)
                        return
                    }
                    try Task.checkCancellation()
                    // Only a newer host presentation or clear supersedes this pending first image.
                    if presentationRevision == initialPresentationRevision,
                       currentItemID == first.itemID,
                       currentURL?.standardizedFileURL == first.url.standardizedFileURL,
                       snapshot?.entries.contains(where: {
                           $0.itemID == first.itemID && $0.url.standardizedFileURL == first.url.standardizedFileURL
                       }) == true {
                        excludedPresentationNeedsReconciliation = false
                        host?.openFolderImage(first.url, rootID: rootID)
                    }
                }
                guard activeGeneration == token, !Task.isCancelled else { return }
                activeGeneration = nil
                activeFolder = nil
                failedRead = nil
                trace?.complete(count: completed.navigationEntries.count, generation: token)
                trace?.end(outcome: .complete, generation: token)
                host?.folderScanDidComplete(count: completed.navigationEntries.count)
                if refreshPending { refresh() }
            } catch {
                guard activeGeneration == token else { return }
                if !Task.isCancelled, !retainReadingAuthority() { return }
                // The Reading State stays up while the root is checked, so 24F-A never flashes before page 26.
                if !(error is CancellationError), !Task.isCancelled, let rootLossCheck {
                    let lost = await rootLossCheck(rootID, error)
                    guard activeGeneration == token, !Task.isCancelled else { return }
                    if lost {
                        endForLostRoot(error, generation: token)
                        throw error
                    }
                }
                activeGeneration = nil
                isReadingFolder = false
                scanTask = nil
                if error is CancellationError || Task.isCancelled {
                    activeFolder = nil
                    invalidateMetadata()
                    sourceSnapshot = nil
                    snapshot = nil; inputURL = nil; currentItemID = nil; currentURL = nil; pendingDirection = nil
                    trace?.end(outcome: .cancelled, generation: token)
                    return
                }
                if input == nil {
                    // #238: a failed folder entry keeps nothing partial, so no list or count can pass for complete.
                    invalidateMetadata()
                    sourceSnapshot = nil; snapshot = nil
                } else {
                    // An image-first read keeps the images already found navigable (FOLDER-05).
                    snapshot = sourceSnapshot?.applying(conditions, metadata: metadata)
                }
                pendingDirection = nil
                failure = error
                failedRead = nil
                retireWatch(successor: false)
                trace?.failure(error, generation: token)
                trace?.end(outcome: .failed, generation: token)
                host?.folderScanDidEnd()
                throw error
            }
        }
        scanTask = task
        host?.folderScanDidStart()
        return task
    }
    /// Coalesce arrows while the current input has not reached the admitted batches yet.
    public func queueNavigation(_ direction: NavigationDirection, folder: URL, input: URL, rootID: AccessRootID? = nil) -> Bool {
        guard activeGeneration != nil, scanTask?.isCancelled != true, let activeFolder,
              activeFolder.url.path == folder.standardizedFileURL.path,
              rootID == nil || rootID == activeFolder.rootID,
              input.standardizedFileURL == inputURL?.standardizedFileURL,
              currentURL?.standardizedFileURL == input.standardizedFileURL else { return false }
        pendingDirection = direction
        advancePending()
        return true
    }
    /// A complete folder source Cancel Reading can put back; nil while scanning or after a cancel.
    var restorePoint: FolderScanRestorePoint? {
        guard let sourceSnapshot, sourceSnapshot.isComplete else { return nil }
        return FolderScanRestorePoint(source: sourceSnapshot, conditions: conditions, loopEnabled: loopEnabled,
            recursiveEnabled: recursiveEnabled, inputURL: inputURL, currentItemID: currentItemID, currentURL: currentURL,
            canPresent: automaticPresentationAllowed, folder: sourceFolder)
    }
    /// Restores without scanning and without an active generation, so a cancelled scan's late events stay ignored.
    func restore(_ point: FolderScanRestorePoint, sort: FolderSortKey, direction: FolderSortDirection) {
        stop(.cancelled, successor: point.folder != nil)
        conditions = FolderViewConditions(sort: sort, direction: direction,
            selectedExtensions: point.conditions.selectedExtensions)
        conditionsFolder = point.source.version.folder
        loopEnabled = point.loopEnabled
        recursiveEnabled = point.recursiveEnabled
        inputURL = point.inputURL
        currentItemID = point.currentItemID
        currentURL = point.currentURL
        sourceSnapshot = point.source
        // A still-current authority keeps the restored source rescannable (an Include Subfolders toggle from the grid).
        automaticPresentationAllowed = point.canPresent.flatMap { $0() ? $0 : nil }
        snapshot = point.source.applying(conditions, metadata: metadata)
        enqueueMetadata()
        sourceFolder = point.folder
        guard let folder = point.folder else { return }
        let token = requestWatch(), rootID = point.source.version.rootID, recursive = point.recursiveEnabled
        Task { await subscribeWatch(folder, rootID: rootID, recursive: recursive, token: token) }
    }
    /// Cancel Reading; during a folder-entry Retry it returns to the failed read instead of ending the session.
    public func cancel() {
        guard activeGeneration != nil, let point = failedRead else { end(); return }
        stop(.cancelled)
        conditions = point.conditions
        conditionsFolder = point.folder
        loopEnabled = point.loopEnabled
        recursiveEnabled = point.recursiveEnabled
        activeFolder = (point.folder, point.rootID)
        sourceFolder = point.folder
        automaticPresentationAllowed = point.canPresent
        failure = point.error
    }
    public func end() { stop(.cancelled) }
    private func projectSource() {
        guard let sourceSnapshot else { return }
        snapshot = sourceSnapshot.applying(conditions, metadata: metadata)
        guard let snapshot, !isReadingFolder, automaticPresentationAllowed?() != false else { return }
        if snapshot.entries.isEmpty {
            presentNoMatchesIfNeeded()
            return
        }
        noMatchesPresented = false
        if let currentItemID, let index = snapshot.navigationIndex(for: currentItemID) {
            let visibleURL = currentURL?.standardizedFileURL
            if snapshot.entries.contains(where: {
                $0.itemID == currentItemID && $0.url.standardizedFileURL == visibleURL
            }) { return }
            // Aliases can share identity while exposing different extensions. Use an eligible URL.
            let replacement = snapshot.navigationEntries[index]
            currentURL = replacement.url
            presentationRevision &+= 1
            excludedPresentationNeedsReconciliation = false
            host?.openFolderImage(replacement.url, rootID: snapshot.version.rootID)
            return
        }
        // An eligible explicit input may still be in a later batch. An excluded input cannot remain visible.
        let inputMayBeEligible = conditions.includesExtension(currentURL?.pathExtension ?? "")
        if let currentItemID, sourceSnapshot.navigationIndex(for: currentItemID) == nil,
           inputMayBeEligible { return }
        guard let first = snapshot.navigationEntries.first else { return }
        currentItemID = first.itemID; currentURL = first.url
        presentationRevision &+= 1
        excludedPresentationNeedsReconciliation = false
        host?.openFolderImage(first.url, rootID: snapshot.version.rootID)
    }
    private func presentNoMatchesIfNeeded() {
        guard hasNoMatches, !noMatchesPresented else { return }
        noMatchesPresented = true
        currentItemID = nil; currentURL = nil; pendingDirection = nil
        presentationRevision &+= 1
        excludedPresentationNeedsReconciliation = false
        host?.clearFolderImageForNoMatches()
    }
    private func retainReadingAuthority() -> Bool {
        guard isReadingFolder, automaticPresentationAllowed?() == false else { return true }
        stop(.replaced)
        return false
    }
    private func stop(_ outcome: FolderScanOutcome, successor: Bool = false) {
        invalidateMetadata()
        let ending = activeGeneration
        activeGeneration = nil
        activeFolder = nil
        scanTask?.cancel()
        scanTask = nil
        snapshot = nil
        sourceSnapshot = nil
        inputURL = nil
        currentItemID = nil
        currentURL = nil
        pendingDirection = nil
        automaticPresentationAllowed = nil
        isReadingFolder = false
        failure = nil
        failedRead = nil
        noMatchesPresented = false
        refreshTask?.cancel(); refreshTask = nil; refreshPending = false; refreshFailed = false
        retireWatch(successor: successor)
        if outcome == .cancelled { excludedPresentationNeedsReconciliation = false }
        if let ending { trace?.end(outcome: outcome, generation: ending) }
        host?.folderScanDidEnd()
    }
    /// A lost Access Root is page 26's (#238): no failure is published and nothing of the read is kept.
    private func endForLostRoot(_ error: any Error, generation token: UInt64) {
        activeGeneration = nil; activeFolder = nil; scanTask = nil; failedRead = nil
        isReadingFolder = false
        invalidateMetadata()
        sourceSnapshot = nil; snapshot = nil
        inputURL = nil; currentItemID = nil; currentURL = nil; pendingDirection = nil
        retireWatch(successor: false)
        trace?.failure(error, generation: token)
        trace?.end(outcome: .failed, generation: token)
        host?.folderScanDidEnd()
    }
    private func cancelMetadataWork() {
        metadataRevision &+= 1
        if metadataTask != nil { metadataDrain = metadataTask }
        metadataTask?.cancel(); metadataTask = nil
        metadataQueue.removeAll(); metadataQueueIndex = 0; metadataSinceProjection = 0
        pendingMetadataIDs.removeAll()
    }
    private func invalidateMetadata() {
        cancelMetadataWork()
        metadata.removeAll(); metadataEntries.removeAll(); metadataUnknownItemIDs.removeAll()
    }
    private func retainMetadata(matching fresh: FolderSnapshot) {
        var entries: [ItemID: [FolderEntry]] = [:]
        for entry in fresh.entries {
            entries[entry.itemID, default: []].append(entry)
        }
        let stale = metadataEntries.compactMap { id, oldEntry in
            entries[id]?.contains(oldEntry) == true ? nil : id
        }
        for id in stale {
            metadata.removeValue(forKey: id)
            metadataEntries.removeValue(forKey: id)
            metadataUnknownItemIDs.remove(id)
        }
    }
    private func enqueueMetadata(candidates: [FolderEntry]? = nil) {
        guard metadataReader != nil,
              conditions.sort == .captureDate || conditions.sort == .pixelDimensions,
              let sourceSnapshot else { return }
        for entry in candidates ?? sourceSnapshot.navigationEntries
            where metadata[entry.itemID] == nil && !pendingMetadataIDs.contains(entry.itemID) {
            pendingMetadataIDs.insert(entry.itemID)
            metadataQueue.append(entry)
        }
        guard metadataTask == nil, metadataQueueIndex < metadataQueue.count else { return }
        let token = metadataRevision, version = sourceSnapshot.version
        let predecessor = metadataDrain
        metadataTask = Task { [weak self] in
            guard let self else { return }
            await predecessor?.value
            while !Task.isCancelled, token == metadataRevision, metadataQueueIndex < metadataQueue.count {
                let entry = metadataQueue[metadataQueueIndex]
                metadataQueueIndex += 1
                guard self.sourceSnapshot?.navigationIndex(for: entry.itemID) != nil else {
                    pendingMetadataIDs.remove(entry.itemID)
                    continue
                }
                guard let reader = metadataReader else { break }
                let access = access
                let read = Task.detached {
                    try await access.withLease(.root(version.rootID, file: entry.url)) { lease in
                        guard AccessBoundary.contains(entry.url, in: lease.url) else { throw FileAccessError.outsideRoot }
                        try Task.checkCancellation()
                        // ImageIO and file metadata reads are synchronous. A held read must not
                        // occupy a Swift cooperative worker needed by other scans and tests.
                        let url = entry.url
                        return try await withCheckedThrowingContinuation { continuation in
                            DispatchQueue.global(qos: .utility).async {
                                do { continuation.resume(returning: try reader.read(url)) }
                                catch { continuation.resume(throwing: error) }
                            }
                        }
                    }
                }
                let result = await withTaskCancellationHandler {
                    try? await read.value
                } onCancel: { read.cancel() }
                guard !Task.isCancelled, token == metadataRevision,
                      let currentSource = self.sourceSnapshot, currentSource.version == version else { break }
                guard currentSource.navigationIndex(for: entry.itemID) != nil else {
                    pendingMetadataIDs.remove(entry.itemID)
                    continue
                }
                if result == nil {
                    onReadFailure?(version.rootID, entry.url)
                    // The host may synchronously revoke access, end this scan,
                    // or change its conditions while handling the failure.
                    guard !Task.isCancelled, token == metadataRevision,
                          self.sourceSnapshot?.version == version else { break }
                }
                metadata[entry.itemID] = result ?? .init()
                metadataEntries[entry.itemID] = entry
                let missingChosenValue = conditions.sort == .captureDate ? result?.captureDate == nil
                    : result?.pixelWidth == nil || result?.pixelHeight == nil
                if missingChosenValue {
                    metadataUnknownItemIDs.insert(entry.itemID)
                }
                pendingMetadataIDs.remove(entry.itemID)
                metadataSinceProjection += 1
                let interval = max(64, (currentSource.navigationEntries.count + 15) / 16)
                if pendingMetadataIDs.isEmpty || metadataSinceProjection >= interval {
                    metadataSinceProjection = 0
                    metadataProjectionCount += 1
                    projectSource()
                }
            }
            if token == metadataRevision {
                metadataQueue.removeAll(keepingCapacity: true)
                metadataQueueIndex = 0
                metadataTask = nil
            }
        }
    }
    /// Judged under a root lease; a lease that cannot be taken counts as gone, since the file cannot be shown either.
    private nonisolated static func isGone(_ url: URL, rootID: AccessRootID, access: any AccessLeasing) async -> Bool {
        let exists = try? await access.withLease(.root(rootID, file: url)) { _ in FileManager.default.fileExists(atPath: url.path) }
        return exists != true
    }
    /// Explicitly nonisolated: path canonicalization and scanning begin only inside the acquired lease.
    private nonisolated static func scanLeased(folder: URL, rootID: AccessRootID, generation: UInt64, input: URL?,
        options: FolderScanOptions,
        access: any AccessLeasing, scanner: any FolderScanning,
        ready: @MainActor @Sendable (SnapshotVersion, ItemID?) -> Void,
        emit: @MainActor @Sendable ([FolderEntry]) async throws -> Void) async throws {
        try await access.withLease(.root(rootID, file: folder)) { lease in
            let version = SnapshotVersion(rootID: rootID, folder: folder, generation: generation)
            let root = ItemIdentityRoot(id: rootID, url: lease.url)
            let itemID = input.flatMap { AccessBoundary.contains($0, in: lease.url) ? FolderEntry(url: $0, root: root).itemID : nil }
            await ready(version, itemID)
            try Task.checkCancellation()
            try await scanner.scan(in: folder, root: root, options: options) { batch in
                try await emit(batch)
            }
        }
    }
}
