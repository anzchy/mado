import Foundation
import PicseeCore

@MainActor public protocol FolderScanHost: AnyObject {
    func openFolderImage(_ url: URL, rootID: AccessRootID)
    func rememberFolder(_ folder: URL, rootID: AccessRootID) async throws
    func clearFolderImageForNoMatches()
    func folderScanDidComplete(count: Int)
    func folderScanDidStart()
    func folderScanDidEnd()
}

extension FolderScanHost {
    public func clearFolderImageForNoMatches() { }
    public func folderScanDidComplete(count: Int) { }
    public func folderScanDidStart() { }
    public func folderScanDidEnd() { }
}

extension FolderScanCoordinator {
    /// Nil lets a nonmember use the existing native grant/navigation path.
    public func canMove(_ direction: NavigationDirection, currentURL: URL? = nil, mayWrap: Bool = false) -> Bool? {
        if hasNoMatches { return false }
        if snapshot?.isComplete == true, snapshot?.navigationEntries.isEmpty == true { return false }
        guard let navigation = navigation(matching: currentURL), let snapshot else {
            return failure == nil ? nil : false
        }
        return (failure == nil && !snapshot.isComplete) || neighbor(in: navigation, direction: direction, mayWrap: mayWrap) != nil
    }
    /// A member endpoint is handled, including a provisional endpoint's enabled no-op.
    @discardableResult public func move(_ direction: NavigationDirection, currentURL: URL? = nil, mayWrap: Bool = false) -> Bool {
        if hasNoMatches { return true }
        if snapshot?.isComplete == true, snapshot?.navigationEntries.isEmpty == true { return true }
        guard let navigation = navigation(matching: currentURL), let snapshot else {
            guard let currentURL else { return false }
            return queueNavigation(direction, folder: currentURL.deletingLastPathComponent(), input: currentURL)
        }
        pendingDirection = nil
        if let entry = neighbor(in: navigation, direction: direction, mayWrap: mayWrap) {
            presentationRevision &+= 1
            currentItemID = entry.itemID
            self.currentURL = entry.url
            host?.openFolderImage(entry.url, rootID: snapshot.version.rootID)
        }
        return true
    }
    func advancePending() {
        guard !Task.isCancelled, let direction = pendingDirection, automaticPresentationAllowed?() != false,
              let navigation = navigation(matching: nil), neighbor(in: navigation, direction: direction, mayWrap: false) != nil else { return }
        move(direction)
    }
    private func navigation(matching actual: URL?) -> (entries: [FolderEntry], index: Int)? {
        guard let snapshot, let currentItemID else { return nil }
        if let actual, actual.standardizedFileURL != currentURL?.standardizedFileURL { return nil }
        let entries = snapshot.navigationEntries
        guard let index = snapshot.navigationIndex(for: currentItemID) else { return nil }
        return (entries, index)
    }
    private func neighbor(in navigation: (entries: [FolderEntry], index: Int), direction: NavigationDirection, mayWrap: Bool) -> FolderEntry? {
        let index = navigation.index + (direction == .next ? 1 : -1)
        if navigation.entries.indices.contains(index) { return navigation.entries[index] }
        guard mayWrap, snapshot?.isComplete == true, navigation.entries.count > 1 else { return nil }
        return direction == .next ? navigation.entries.first : navigation.entries.last
    }
}

extension ViewerSession {
    public func endFolderScan() { folderScan?.end() }
    public func cancelFolderReading() { folderScan?.cancel() }
    public func retryFolderScan() { _ = folderScan?.retry() }
    public var folderConditions: FolderViewConditions { folderScan?.conditions ?? .init() }
    public var folderLoopEnabled: Bool { displayPreferences.loopThroughImages }
    public var folderRecursiveEnabled: Bool { folderScan?.recursiveEnabled ?? false }
    public var folderAvailableExtensions: [String] { folderScan?.availableExtensions ?? [] }
    public var hasFolderSource: Bool { folderScan?.sourceSnapshot != nil }
    public var isEmptyFolder: Bool { folderScan?.isEmptyFolder ?? false }
    public func setFolderConditions(_ conditions: FolderViewConditions) {
        guard filePreviewSet == nil, previewSet == nil else { return }
        folderScan?.setConditions(conditions)
        saveFolderSort(conditions)
    }
    @discardableResult public func setFolderRecursiveEnabled(_ enabled: Bool) -> Task<Void, any Error>? {
        guard filePreviewSet == nil, previewSet == nil, let folderScan else { return nil }
        guard mode == .browsing, folderScan.recursiveEnabled != enabled else { return folderScan.setRecursiveEnabled(enabled) }
        // From the grid the rescan reads like a folder open, and Cancel Reading returns to this grid (ADR-0010).
        let recorded = folderEntryRestore == nil
        beginFolderEntry(shownImage: nil, hasCompleteGrid: folderScan.restorePoint != nil)
        let task = folderScan.setRecursiveEnabled(enabled, rereadingFolder: true)
        if task == nil, recorded { folderEntryRestore = nil }
        return task
    }
}
