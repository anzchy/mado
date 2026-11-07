import Foundation
import Testing
import MadoCore
@testable import MadoApplication

private actor T229SidebarLeases: AccessLeasing {
    let root: URL
    private var acquired = 0, released = 0
    init(root: URL) { self.root = root }
    func acquire(_ request: AccessRequest) -> AccessLease {
        acquired += 1
        return AccessLease(url: root, rootID: AccessRootID())
    }
    func release(_ lease: AccessLease) { released += 1 }
    var balanced: Bool { acquired == released }
}
private enum T229SidebarError: Error { case denied }
private actor T229SidebarFailures: SidebarFolderEnumerating {
    enum Mode: Sendable { case listing, count, held }
    let mode: Mode
    private var pending: CheckedContinuation<[URL], any Error>?
    private(set) var started = false
    init(_ mode: Mode) { self.mode = mode }
    func children(in folder: URL, root: URL) async throws -> [URL] {
        switch mode {
        case .listing: throw T229SidebarError.denied
        case .count: return []
        case .held:
            guard folder.lastPathComponent == "Old" else { return [] }
            started = true
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
    }
    func imageCount(in folder: URL, root: URL) throws -> Int {
        if case .count = mode { throw T229SidebarError.denied }
        return 0
    }
    func releaseFailure() { pending?.resume(throwing: T229SidebarError.denied); pending = nil }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229SidebarReaderFailuresReportCurrentWorkAndIgnoreCancelledOldWork() async throws {
    let root = URL(fileURLWithPath: "/tmp/T229-sidebar")
    for mode in [T229SidebarFailures.Mode.listing, .count] {
        let access = T229SidebarLeases(root: root)
        let session = SidebarFolderLoadSession(browser: SidebarFolderBrowser(access: access,
            enumerator: T229SidebarFailures(mode)))
        var failures: [URL] = []
        session.start(folder: root, rootID: AccessRootID(), onRows: { _, _ in }, onCount: { _, _ in },
            onFailure: { failures.append($0) })
        while failures.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(failures == [root])
        #expect(await access.balanced)
        session.cancel()
    }

    let access = T229SidebarLeases(root: root), enumerator = T229SidebarFailures(.held)
    let session = SidebarFolderLoadSession(browser: SidebarFolderBrowser(access: access, enumerator: enumerator))
    var failures: [URL] = [], newCounts: [URL] = []
    let old = root.appendingPathComponent("Old"), new = root.appendingPathComponent("New")
    session.start(folder: old, rootID: AccessRootID(), onRows: { _, _ in }, onCount: { _, _ in },
        onFailure: { failures.append($0) })
    while !(await enumerator.started) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await enumerator.started)
    session.start(folder: new, rootID: AccessRootID(), onRows: { _, _ in },
        onCount: { url, _ in newCounts.append(url) }, onFailure: { failures.append($0) })
    while newCounts.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(newCounts.contains(new))
    await enumerator.releaseFailure()
    while !(await access.balanced) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await access.balanced)
    // Both the new count and old lease release completed; observe only a late failure.
    try await Task.sleep(for: .milliseconds(20))
    #expect(failures.isEmpty)
    session.cancel()
}

private actor T229ParentFailureLeases: AccessLeasing {
    let root: URL
    private var acquisitions = 0, releases = 0
    init(root: URL) { self.root = root }
    func acquire(_ request: AccessRequest) throws -> AccessLease {
        acquisitions += 1
        if acquisitions == 2 { throw T229SidebarError.denied }
        return AccessLease(url: root, rootID: AccessRootID())
    }
    func release(_ lease: AccessLease) { releases += 1 }
    var balanced: Bool { acquisitions - 1 == releases }
}

@MainActor @Test(.timeLimit(.minutes(3))) func t229SidebarParentFailureReportsFailureAndKeepsKnownRows() async throws {
    let root = URL(fileURLWithPath: "/tmp/T229-parent")
    let access = T229ParentFailureLeases(root: root)
    let session = SidebarFolderLoadSession(browser: SidebarFolderBrowser(access: access,
        enumerator: T229SidebarFailures(.count)))
    var rows: [[URL]] = [], parents: [URL?] = [], failures: [URL] = [], counts: [Int] = []
    session.start(folder: root, rootID: AccessRootID(), onRows: { children, parent in
        rows.append(children); parents.append(parent)
    }, onCount: { _, count in counts.append(count) }, onFailure: { failures.append($0) })
    // Await completion even when the native suite delays MainActor work. The
    // enclosing test limit bounds missing callbacks, not a product latency.
    while failures.count < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(rows == [[]])
    #expect(parents.count == 1 && parents[0] == nil)
    #expect(failures == [root, root])
    #expect(counts.isEmpty)
    #expect(await access.balanced)
    session.cancel()
}
